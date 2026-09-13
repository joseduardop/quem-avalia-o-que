"""parseia o jsonl cru do tmdb (landing) para bronze/tmdb_filmes.parquet

fiel à origem: entra toda resposta 200, uma linha por (tconst_esperado, tmdb_id), inclusive
candidata cujo imdb_id devolvido não bate com o tconst. quem escolhe a candidata certa e
atualiza a ponte é o etl/silver_tmdb.sql

uso: ops/venv-gestao/bin/python etl/processa_tmdb.py
"""

from __future__ import annotations

import json
import os
from datetime import date
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TMDB_DIR = PROJECT_ROOT / "datalake" / "landing" / "tmdb"
BRONZE_PATH = PROJECT_ROOT / "datalake" / "bronze" / "tmdb_filmes.parquet"

# tipos de lançamento do tmdb: 1 premiere, 2 cinema limitado, 3 cinema, 4 digital, 5 físico, 6 tv
# a classificação indicativa vem do cinema quando existe; senão de qualquer lançamento que a tenha
PRIORIDADE_TIPO = {3: 0, 2: 1, 4: 2, 5: 3, 6: 4, 1: 5}

TMDB_SCHEMA = pa.schema(
    [
        ("tconst_esperado", pa.string()),
        ("tmdb_id", pa.int32()),
        ("imdb_id", pa.string()),
        ("title", pa.string()),
        ("original_title", pa.string()),
        ("release_date", pa.date32()),
        ("vote_average", pa.float64()),
        ("vote_count", pa.int64()),
        ("popularity", pa.float64()),
        ("runtime", pa.int32()),
        ("budget", pa.int64()),
        ("revenue", pa.int64()),
        ("original_language", pa.string()),
        ("status", pa.string()),
        ("genres", pa.list_(pa.string())),
        ("keywords", pa.list_(pa.string())),
        ("production_countries", pa.list_(pa.string())),
        ("production_country_names", pa.list_(pa.string())),
        ("production_companies", pa.list_(pa.string())),
        ("spoken_languages", pa.list_(pa.string())),
        ("diretor", pa.string()),
        ("diretores", pa.list_(pa.string())),
        ("elenco_principal", pa.list_(pa.string())),
        ("certificacao_br", pa.string()),
        ("certificacao_br_tipo", pa.int32()),
        ("certificacao_us", pa.string()),
        ("certificacao_us_tipo", pa.int32()),
        ("capturado_em", pa.string()),
    ]
)


def carregar_respostas() -> dict[tuple[str, int], dict[str, Any]]:
    """uma resposta 200 por (tconst_esperado, tmdb_id); em repetição (retomada) fica a última"""
    respostas: dict[tuple[str, int], dict[str, Any]] = {}
    caminhos = sorted(TMDB_DIR.glob("movie-*.jsonl")) + sorted(TMDB_DIR.glob("movie-*.jsonl.part"))
    for caminho in caminhos:
        with caminho.open(encoding="utf-8") as arquivo:
            for linha in arquivo:
                try:
                    item = json.loads(linha)
                except json.JSONDecodeError:
                    continue
                if item.get("status_http") != 200 or not item.get("resposta"):
                    continue
                respostas[(item["tconst_esperado"], item["tmdb_id_consultado"])] = item
    return respostas


def data_iso(valor: str | None) -> date | None:
    if not valor:
        return None
    try:
        return date.fromisoformat(valor)
    except ValueError:
        return None


def nomes(itens: list[dict[str, Any]] | None) -> list[str]:
    return [item["name"] for item in itens or [] if item.get("name")]


def certificacao(resposta: dict[str, Any], pais: str) -> tuple[str | None, int | None]:
    """classificação do país e o tipo de lançamento de onde ela veio"""
    resultados = (resposta.get("release_dates") or {}).get("results") or []
    candidatos: list[dict[str, Any]] = []
    for resultado in resultados:
        if resultado.get("iso_3166_1") != pais:
            continue
        for lancamento in resultado.get("release_dates") or []:
            if (lancamento.get("certification") or "").strip():
                candidatos.append(lancamento)
    if not candidatos:
        return None, None
    candidatos.sort(
        key=lambda item: (
            PRIORIDADE_TIPO.get(item.get("type"), 9),
            item.get("release_date") or "9999",
        )
    )
    return candidatos[0]["certification"].strip(), candidatos[0].get("type")


def registro_bronze(tconst_esperado: str, tmdb_id: int, item: dict[str, Any]) -> dict[str, Any]:
    resposta = item["resposta"]
    creditos = resposta.get("credits") or {}
    diretores = [
        pessoa["name"]
        for pessoa in creditos.get("crew") or []
        if pessoa.get("job") == "Director" and pessoa.get("name")
    ]
    # em filme o append_to_response=keywords devolve {"keywords": [...]}; em série é "results"
    palavras = resposta.get("keywords") or {}
    paises = resposta.get("production_countries") or []
    cert_br, tipo_br = certificacao(resposta, "BR")
    cert_us, tipo_us = certificacao(resposta, "US")
    return {
        "tconst_esperado": tconst_esperado,
        "tmdb_id": tmdb_id,
        "imdb_id": (resposta.get("external_ids") or {}).get("imdb_id"),
        "title": resposta.get("title"),
        "original_title": resposta.get("original_title"),
        "release_date": data_iso(resposta.get("release_date")),
        "vote_average": resposta.get("vote_average"),
        "vote_count": resposta.get("vote_count"),
        "popularity": resposta.get("popularity"),
        "runtime": resposta.get("runtime"),
        "budget": resposta.get("budget"),
        "revenue": resposta.get("revenue"),
        "original_language": resposta.get("original_language"),
        "status": resposta.get("status"),
        "genres": nomes(resposta.get("genres")),
        "keywords": nomes(palavras.get("keywords") or palavras.get("results")),
        "production_countries": [pais["iso_3166_1"] for pais in paises if pais.get("iso_3166_1")],
        "production_country_names": nomes(paises),
        "production_companies": nomes(resposta.get("production_companies")),
        "spoken_languages": [
            lingua["iso_639_1"] for lingua in resposta.get("spoken_languages") or [] if lingua.get("iso_639_1")
        ],
        "diretor": diretores[0] if diretores else None,
        "diretores": diretores,
        "elenco_principal": nomes((creditos.get("cast") or [])[:5]),
        "certificacao_br": cert_br,
        "certificacao_br_tipo": tipo_br,
        "certificacao_us": cert_us,
        "certificacao_us_tipo": tipo_us,
        "capturado_em": item.get("capturado_em"),
    }


def escrever_atomico(tabela: pa.Table, destino: Path) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    temporario = destino.with_suffix(destino.suffix + ".tmp")
    pq.write_table(tabela, temporario, compression="zstd")
    os.replace(temporario, destino)


def main() -> None:
    respostas = carregar_respostas()
    if not respostas:
        raise SystemExit("nenhuma resposta de filme em datalake/landing/tmdb; rode ops/crawl_tmdb.py antes")
    linhas = [
        registro_bronze(tconst, tmdb_id, item)
        for (tconst, tmdb_id), item in sorted(respostas.items())
    ]
    tabela = pa.Table.from_pylist(linhas, schema=TMDB_SCHEMA)
    escrever_atomico(tabela, BRONZE_PATH)
    batem = sum(1 for linha in linhas if linha["imdb_id"] == linha["tconst_esperado"])
    print(f"respostas 200 parseadas: {len(linhas)}")
    print(f"imdb_id devolvido bate com o tconst: {batem}")
    print(f"não bate: {len(linhas) - batem}")
    print(f"com certificação br: {sum(1 for linha in linhas if linha['certificacao_br'])}")
    print(f"com país: {sum(1 for linha in linhas if linha['production_countries'])}")
    print(f"bronze: {BRONZE_PATH}")


if __name__ == "__main__":
    main()
