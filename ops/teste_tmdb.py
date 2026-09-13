"""roda o fluxo inteiro do tmdb com a api mockada, num diretório temporário, sem tocar em datalake/

crawler (retomada inclusa) -> jsonl -> etl/processa_tmdb.py -> bronze -> etl/silver_tmdb.sql (duas vezes,
pra provar idempotência) -> etl/gold_tmdb.sql. cinco filmes cobrindo cada caminho da ponte:
ok, divergente, sem id (/find), id errado sem saída, 404 corrigido pelo /find

uso: ops/venv-gestao/bin/python ops/teste_tmdb.py
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "ops"))
sys.path.insert(0, str(RAIZ / "etl"))
os.environ.setdefault("TMDB_API_KEY", "falsa")

import crawl_tmdb as crawl
import processa_tmdb as processa


def resposta(tmdb_id, imdb, br=None, tipo_br=3):
    lancamentos = [{"iso_3166_1": "US", "release_dates": [{"certification": "R", "type": 3, "release_date": "2001-01-01T00:00:00.000Z"}]}]
    if br:
        lancamentos.append({"iso_3166_1": "BR", "release_dates": [{"certification": br, "type": tipo_br, "release_date": "2001-02-01T00:00:00.000Z"}]})
    return {
        "id": tmdb_id, "title": f"t{tmdb_id}", "original_title": "o", "release_date": "2001-01-01",
        "vote_average": 7.0, "vote_count": 10, "popularity": 1.0, "runtime": 90, "budget": 0, "revenue": 0,
        "original_language": "en", "status": "Released", "genres": [{"name": "Drama"}],
        "keywords": {"keywords": [{"name": "k"}]},
        "production_countries": [{"iso_3166_1": "BR", "name": "Brazil"}, {"iso_3166_1": "FR", "name": "France"}][: 1 + tmdb_id % 2],
        "production_companies": [{"name": "x"}], "spoken_languages": [{"iso_639_1": "pt"}],
        "external_ids": {"imdb_id": imdb}, "release_dates": {"results": lancamentos},
        "credits": {"cast": [{"name": f"a{i}"} for i in range(7)], "crew": [{"job": "Director", "name": "d"}]},
    }


FILMES = {
    550: (200, resposta(550, "tt0137523")),  # pré-voo do crawler
    11: (200, resposta(11, "tt0000001", br="12")),
    22: (200, resposta(22, "tt0000099")),
    23: (200, resposta(23, "tt0000002", br="16", tipo_br=4)),
    33: (200, resposta(33, "tt0000003", br="L")),
    44: (200, resposta(44, "tt0000098")),
    55: (404, {"success": False}),
    56: (200, resposta(56, "tt0000005")),
}
FINDS = {"tt0000003": [33], "tt0000004": [], "tt0000005": [56]}
ESPERADO = {
    "tt0000001": (11, "ambos"),
    "tt0000002": (23, "arbitrado_tmdb"),
    "tt0000003": (33, "tmdb_find"),
    "tt0000004": (44, "nao_validado"),
    "tt0000005": (56, "corrigido_tmdb"),
}
chamadas = []


def requisitar_falso(self, tarefa):
    chamadas.append(tarefa.chave)
    if tarefa.tipo == "find":
        corpo = {"movie_results": [{"id": i} for i in FINDS.get(tarefa.tconst, [])]}
        return crawl.montar_registro(tarefa, 200, corpo, 1, 0.0, None)
    status, corpo = FILMES[tarefa.tmdb_id]
    return crawl.montar_registro(tarefa, status, corpo, 1, 0.0, None)


def fixtures(dl):
    for pasta in ("landing/tmdb", "bronze", "silver", "gold"):
        (dl / pasta).mkdir(parents=True)
    ponte_schema = pa.schema([
        ("tconst", pa.string()), ("tmdb_id", pa.int32()), ("letterboxd_slug", pa.string()),
        ("metodo_join", pa.string()), ("slug_ambiguo", pa.bool_()), ("slug_compartilhado", pa.bool_()),
    ])
    def linha(tconst, tmdb_id, metodo):
        return {"tconst": tconst, "tmdb_id": tmdb_id, "letterboxd_slug": tconst, "metodo_join": metodo, "slug_ambiguo": False, "slug_compartilhado": False}
    ponte = [linha("tt0000001", 11, "ambos"), linha("tt0000002", 22, "divergente"), linha("tt0000003", None, "nenhum"),
             linha("tt0000004", 44, "wikidata"), linha("tt0000005", 55, "movielens")]
    pq.write_table(pa.Table.from_pylist(ponte, schema=ponte_schema), dl / "silver/ponte_ids.parquet")
    pq.write_table(pa.Table.from_pylist(
        [{"tconst": p["tconst"], "titulo": "filme " + p["tconst"][-1], "ano": 2000 + i, "decada": 2000} for i, p in enumerate(ponte)]),
        dl / "silver/dim_titulo.parquet")
    pq.write_table(pa.Table.from_pylist(
        [{"tconst": "tt0000001", "tmdb_id_wikidata": 11}, {"tconst": "tt0000002", "tmdb_id_wikidata": 23},
         {"tconst": "tt0000004", "tmdb_id_wikidata": 44}, {"tconst": "tt0000005", "tmdb_id_wikidata": None}],
        schema=pa.schema([("tconst", pa.string()), ("tmdb_id_wikidata", pa.int32())])), dl / "silver/slug_por_tconst.parquet")
    pq.write_table(pa.Table.from_pylist(
        [{"movieId": 1, "imdbId": "0000001", "tmdbId": 11}, {"movieId": 2, "imdbId": "0000002", "tmdbId": 22}, {"movieId": 5, "imdbId": "0000005", "tmdbId": 55}],
        schema=pa.schema([("movieId", pa.int32()), ("imdbId", pa.string()), ("tmdbId", pa.int32())])), dl / "bronze/movielens_links.parquet")
    pq.write_table(pa.Table.from_pylist(
        [{"imdb_id": "tt0000002", "letterboxd_slug": "x", "tmdb_id": 23}, {"imdb_id": "tt0000001", "letterboxd_slug": "y", "tmdb_id": 11}],
        schema=pa.schema([("imdb_id", pa.string()), ("letterboxd_slug", pa.string()), ("tmdb_id", pa.int32())])), dl / "bronze/wikidata_ponte.parquet")


def rodar_sql(dl, tmp, nome):
    sql = (RAIZ / "etl" / nome).read_text().replace("'datalake/", f"'{dl}/")
    arquivo = tmp / nome
    arquivo.write_text(sql)
    resultado = subprocess.run([sys.executable, str(RAIZ / "ops/run_sql.py"), str(arquivo)], capture_output=True, text=True)
    if resultado.returncode != 0:
        print(resultado.stdout[-2000:], resultado.stderr[-2000:])
        raise SystemExit(f"{nome} falhou")


def main():
    tmp = Path(tempfile.mkdtemp())
    dl = tmp / "datalake"
    fixtures(dl)
    for modulo in (crawl, processa):
        modulo.TMDB_DIR = dl / "landing/tmdb"
    crawl.PONTE_PATH = dl / "silver/ponte_ids.parquet"
    crawl.WIKIDATA_PATH = dl / "bronze/wikidata_ponte.parquet"
    processa.BRONZE_PATH = dl / "bronze/tmdb_filmes.parquet"
    crawl.ClienteTmdb.requisitar = requisitar_falso
    sys.argv = ["crawl_tmdb.py"]

    crawl.main()
    assert len(chamadas) == 11, f"esperava 11 requisições (pré-voo + 10), fez {len(chamadas)}"
    chamadas.clear()
    crawl.main()
    assert chamadas == [("movie", "tt0137523", 550)], f"retomada refez requisições além do pré-voo: {chamadas}"

    processa.main()
    bronze = pq.read_table(dl / "bronze/tmdb_filmes.parquet").to_pylist()
    assert len(bronze) == 6, f"bronze com {len(bronze)} linhas, esperava 6 (todas as respostas 200; o pré-voo não é gravado)"
    por_id = {linha["tmdb_id"]: linha for linha in bronze}
    assert por_id[23]["certificacao_br"] == "16" and por_id[23]["certificacao_br_tipo"] == 4, "fallback da certificação br falhou"
    assert por_id[11]["elenco_principal"] == ["a0", "a1", "a2", "a3", "a4"]

    rodar_sql(dl, tmp, "silver_tmdb.sql")
    primeira = pq.read_table(dl / "silver/ponte_ids.parquet").to_pylist()
    rodar_sql(dl, tmp, "silver_tmdb.sql")
    segunda = pq.read_table(dl / "silver/ponte_ids.parquet").to_pylist()
    assert primeira == segunda, "silver_tmdb.sql não é idempotente"
    obtido = {linha["tconst"]: (linha["tmdb_id"], linha["metodo_join"]) for linha in segunda}
    assert obtido == ESPERADO, f"ponte diferente do esperado:\n{obtido}\n{ESPERADO}"
    titulo = pq.read_table(dl / "silver/tmdb_titulo.parquet").to_pylist()
    assert sorted(linha["tconst"] for linha in titulo) == ["tt0000001", "tt0000002", "tt0000003", "tt0000005"]

    rodar_sql(dl, tmp, "gold_tmdb.sql")
    cobertura = pq.read_table(dl / "gold/cobertura_tmdb.parquet").to_pylist()[0]
    assert cobertura["com_tmdb_validado"] == 4 and cobertura["com_cert_br"] == 3, cobertura

    shutil.rmtree(tmp)
    print("teste do tmdb ok: crawler, retomada, parser, silver_tmdb (idempotente) e gold_tmdb")


if __name__ == "__main__":
    main()
