"""baixa o tmdb em jsonl bruto, com retomada e limite global de requisições

credencial por variável de ambiente (TMDB_READ_ACCESS_TOKEN ou TMDB_API_KEY), que pode vir
de um .env na raiz do projeto. a chave vem de https://www.themoviedb.org/settings/api

em memória fica só um resumo de cada resposta (status, imdb_id devolvido, ids do /find);
a resposta inteira vai pro jsonl e é lida de volta pelo etl/processa_tmdb.py
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

import duckdb
import requests


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TMDB_DIR = PROJECT_ROOT / "datalake" / "landing" / "tmdb"
PONTE_PATH = PROJECT_ROOT / "datalake" / "silver" / "ponte_ids.parquet"
WIKIDATA_PATH = PROJECT_ROOT / "datalake" / "bronze" / "wikidata_ponte.parquet"
BASE_URL = "https://api.themoviedb.org/3"
APPEND_TO_RESPONSE = "release_dates,external_ids,keywords,credits"
DEFAULT_RATE = 22.0
DEFAULT_WORKERS = 12
DEFAULT_BATCH_SIZE = 1000
TIMEOUT_SECONDS = 30
MAX_ATTEMPTS = 3
MAX_429_ATTEMPTS = 8


@dataclass(frozen=True, order=True)
class Tarefa:
    tipo: str
    tconst: str
    tmdb_id: int | None = None

    @property
    def chave(self) -> tuple[str, str, int | None]:
        return self.tipo, self.tconst, self.tmdb_id


class Limitador:
    """distribui chamadas entre threads sem ultrapassar a taxa global"""

    def __init__(self, taxa: float) -> None:
        self.intervalo = 1.0 / taxa
        self.proximo = time.monotonic()
        self.lock = threading.Lock()

    def esperar(self) -> None:
        with self.lock:
            agora = time.monotonic()
            espera = max(0.0, self.proximo - agora)
            self.proximo = max(agora, self.proximo) + self.intervalo
        if espera:
            time.sleep(espera)


class ClienteTmdb:
    """cliente compartilhado com uma sessão http por thread"""

    def __init__(self, taxa: float) -> None:
        token = os.environ.get("TMDB_READ_ACCESS_TOKEN")
        chave = os.environ.get("TMDB_API_KEY")
        if not token and not chave:
            raise SystemExit(
                "credencial ausente: exporte TMDB_READ_ACCESS_TOKEN ou TMDB_API_KEY "
                "(ou coloque num .env na raiz); a chave vem de https://www.themoviedb.org/settings/api"
            )

        self.token = token
        self.chave = chave
        self.limitador = Limitador(taxa)
        self.local = threading.local()

    def sessao(self) -> requests.Session:
        if not hasattr(self.local, "sessao"):
            sessao = requests.Session()
            sessao.headers.update({"accept": "application/json"})
            if self.token:
                sessao.headers.update({"authorization": f"Bearer {self.token}"})
            self.local.sessao = sessao
        return self.local.sessao

    def limpar_segredos(self, mensagem: str) -> str:
        for segredo in (self.token, self.chave):
            if segredo:
                mensagem = mensagem.replace(segredo, "[removido]")
        return mensagem

    def requisitar(self, tarefa: Tarefa) -> dict[str, Any]:
        if tarefa.tipo == "find":
            caminho = f"/find/{tarefa.tconst}"
            parametros: dict[str, Any] = {"external_source": "imdb_id"}
        else:
            caminho = f"/movie/{tarefa.tmdb_id}"
            parametros = {"append_to_response": APPEND_TO_RESPONSE}

        if self.chave:
            parametros["api_key"] = self.chave

        inicio = time.monotonic()
        ultimo_status: int | None = None
        ultimo_json: Any = None
        ultimo_erro: str | None = None

        for tentativa in range(1, MAX_429_ATTEMPTS + 1):
            self.limitador.esperar()
            try:
                resposta = self.sessao().get(
                    BASE_URL + caminho,
                    params=parametros,
                    timeout=TIMEOUT_SECONDS,
                )
                ultimo_status = resposta.status_code
                try:
                    ultimo_json = resposta.json()
                except requests.exceptions.JSONDecodeError:
                    ultimo_json = None
                    ultimo_erro = "resposta não era json"

                # 200 sem json não é sucesso: cai no retry genérico em vez de virar registro concluído
                if resposta.status_code == 404 or (resposta.status_code == 200 and ultimo_json is not None):
                    return montar_registro(
                        tarefa,
                        resposta.status_code,
                        ultimo_json,
                        tentativa,
                        inicio,
                        ultimo_erro,
                    )

                if resposta.status_code == 429:
                    if tentativa == MAX_429_ATTEMPTS:
                        break
                    espera = max(
                        espera_retry_after(resposta.headers.get("retry-after")),
                        min(60.0, 2 ** (tentativa - 1)),
                    )
                    time.sleep(espera)
                    continue

                if resposta.status_code != 200:
                    ultimo_erro = f"status http {resposta.status_code}"
                if tentativa >= MAX_ATTEMPTS:
                    break
                time.sleep(min(10.0, 2 ** (tentativa - 1)))
            except requests.RequestException as erro:
                ultimo_erro = self.limpar_segredos(str(erro))
                if tentativa >= MAX_ATTEMPTS:
                    break
                time.sleep(min(10.0, 2 ** (tentativa - 1)))

        return montar_registro(
            tarefa,
            ultimo_status,
            ultimo_json,
            tentativa,
            inicio,
            ultimo_erro,
        )


def espera_retry_after(valor: str | None) -> float:
    if not valor:
        return 0.0
    try:
        return max(0.0, float(valor))
    except ValueError:
        try:
            instante = parsedate_to_datetime(valor)
            return max(0.0, (instante - datetime.now(timezone.utc)).total_seconds())
        except (TypeError, ValueError):
            return 0.0


def montar_registro(
    tarefa: Tarefa,
    status: int | None,
    resposta: Any,
    tentativas: int,
    inicio: float,
    erro: str | None,
) -> dict[str, Any]:
    return {
        "tipo": tarefa.tipo,
        "tconst_esperado": tarefa.tconst,
        "tmdb_id_consultado": tarefa.tmdb_id,
        "status_http": status,
        "tentativas": tentativas,
        "duracao_segundos": round(time.monotonic() - inicio, 3),
        "capturado_em": datetime.now(timezone.utc).isoformat(),
        "erro": erro,
        "resposta": resposta,
    }


def carregar_ponte() -> tuple[dict[str, dict[str, Any]], dict[str, set[int]]]:
    con = duckdb.connect()
    linhas = con.execute(
        f"""
        select tconst, tmdb_id, metodo_join
        from read_parquet('{PONTE_PATH.as_posix()}')
        order by tconst
        """
    ).fetchall()
    ponte = {
        tconst: {"tmdb_id": tmdb_id, "metodo_join": metodo}
        for tconst, tmdb_id, metodo in linhas
    }

    divergentes = con.execute(
        f"""
        select distinct p.tconst, w.tmdb_id
        from read_parquet('{PONTE_PATH.as_posix()}') p
        join read_parquet('{WIKIDATA_PATH.as_posix()}') w
          on w.imdb_id = p.tconst
        where p.metodo_join = 'divergente'
          and w.tmdb_id is not null
        order by 1, 2
        """
    ).fetchall()
    candidatos: dict[str, set[int]] = {}
    for tconst, tmdb_id in divergentes:
        candidatos.setdefault(tconst, set()).add(tmdb_id)
    for tconst, item in ponte.items():
        if item["metodo_join"] == "divergente" and item["tmdb_id"] is not None:
            candidatos.setdefault(tconst, set()).add(item["tmdb_id"])
    return ponte, candidatos


def arquivos_jsonl() -> list[Path]:
    return sorted(TMDB_DIR.glob("*.jsonl")) + sorted(TMDB_DIR.glob("*.jsonl.part"))


def resumir(registro: dict[str, Any]) -> dict[str, Any]:
    """o que o crawler precisa reter de cada resposta; o resto fica só no jsonl"""
    resposta = registro.get("resposta") or {}
    return {
        "status_http": registro.get("status_http"),
        "tem_resposta": bool(registro.get("resposta")),
        "imdb_id": (resposta.get("external_ids") or {}).get("imdb_id"),
        "find_ids": [
            filme.get("id")
            for filme in resposta.get("movie_results") or []
            if isinstance(filme.get("id"), int)
        ],
    }


def carregar_registros() -> dict[tuple[str, str, int | None], dict[str, Any]]:
    registros: dict[tuple[str, str, int | None], dict[str, Any]] = {}
    for caminho in arquivos_jsonl():
        with caminho.open(encoding="utf-8") as arquivo:
            for linha in arquivo:
                try:
                    item = json.loads(linha)
                except json.JSONDecodeError:
                    continue
                chave = (
                    item.get("tipo"),
                    item.get("tconst_esperado"),
                    item.get("tmdb_id_consultado"),
                )
                registros[chave] = resumir(item)
    return registros


def concluidas(registros: dict[tuple[str, str, int | None], dict[str, Any]]) -> set[tuple[str, str, int | None]]:
    return {
        chave
        for chave, item in registros.items()
        if item["status_http"] == 404 or (item["status_http"] == 200 and item["tem_resposta"])
    }


def candidatos_do_find(registros: dict[tuple[str, str, int | None], dict[str, Any]]) -> dict[str, set[int]]:
    candidatos: dict[str, set[int]] = {}
    for (tipo, tconst, _), item in registros.items():
        if tipo != "find" or item["status_http"] != 200:
            continue
        for tmdb_id in item["find_ids"]:
            candidatos.setdefault(tconst, set()).add(tmdb_id)
    return candidatos


def tarefas_filme(
    ponte: dict[str, dict[str, Any]],
    candidatos_divergentes: dict[str, set[int]],
    candidatos_find: dict[str, set[int]],
) -> list[Tarefa]:
    tarefas: set[Tarefa] = set()
    for tconst, item in ponte.items():
        if item["tmdb_id"] is not None:
            tarefas.add(Tarefa("movie", tconst, item["tmdb_id"]))
    for fonte in (candidatos_divergentes, candidatos_find):
        for tconst, ids in fonte.items():
            for tmdb_id in ids:
                tarefas.add(Tarefa("movie", tconst, tmdb_id))
    return sorted(tarefas)


def sem_identidade_correta(
    ponte: dict[str, dict[str, Any]],
    registros: dict[tuple[str, str, int | None], dict[str, Any]],
) -> set[str]:
    corretos: set[str] = set()
    for (tipo, tconst, _), item in registros.items():
        if tipo == "movie" and item["status_http"] == 200 and item["imdb_id"] == tconst:
            corretos.add(tconst)
    return set(ponte) - corretos


def nome_livre(tipo: str, execucao: str, indice: int) -> Path:
    """nome de lote que não existe ainda: duas chamadas do mesmo tipo nunca sobrescrevem uma à outra"""
    while True:
        parcial = TMDB_DIR / f"{tipo}-{execucao}-{indice:05d}.jsonl.part"
        if not parcial.exists() and not parcial.with_suffix("").exists():
            return parcial
        indice += 1


def executar_lotes(
    cliente: ClienteTmdb,
    tarefas: list[Tarefa],
    registros: dict[tuple[str, str, int | None], dict[str, Any]],
    workers: int,
    tamanho_lote: int,
) -> None:
    feitas = concluidas(registros)
    pendentes = [tarefa for tarefa in tarefas if tarefa.chave not in feitas]
    if not pendentes:
        return

    execucao = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    total = len(pendentes)
    for inicio in range(0, total, tamanho_lote):
        lote = pendentes[inicio : inicio + tamanho_lote]
        tipo = lote[0].tipo
        parcial = nome_livre(tipo, execucao, inicio // tamanho_lote)
        final = parcial.with_suffix("")
        concluidas_lote = 0

        with parcial.open("a", encoding="utf-8") as arquivo:
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futuros = {executor.submit(cliente.requisitar, tarefa): tarefa for tarefa in lote}
                for futuro in as_completed(futuros):
                    registro = futuro.result()
                    arquivo.write(json.dumps(registro, ensure_ascii=False) + "\n")
                    registros[futuros[futuro].chave] = resumir(registro)
                    concluidas_lote += 1
                    if concluidas_lote % 50 == 0:
                        arquivo.flush()
                        os.fsync(arquivo.fileno())
                    feitas_total = min(inicio + concluidas_lote, total)
                    if feitas_total % 100 == 0 or feitas_total == total:
                        print(f"{tipo}: {feitas_total}/{total}")
            arquivo.flush()
            os.fsync(arquivo.fileno())
        parcial.replace(final)


def resumo(
    ponte: dict[str, dict[str, Any]],
    registros: dict[tuple[str, str, int | None], dict[str, Any]],
    inicio: float,
) -> None:
    filmes = [(chave[1], item) for chave, item in registros.items() if chave[0] == "movie"]
    sucessos = [(tconst, item) for tconst, item in filmes if item["status_http"] == 200]
    erros_404 = [item for _, item in filmes if item["status_http"] == 404]
    falhas = [item for _, item in filmes if item["status_http"] not in (200, 404)]
    corretos = {tconst for tconst, item in sucessos if item["imdb_id"] == tconst}
    candidatos_errados = sum(1 for tconst, item in sucessos if item["imdb_id"] != tconst)
    tamanho = sum(caminho.stat().st_size for caminho in arquivos_jsonl())
    print(f"frame: {len(ponte)}")
    print(f"identidade validada: {len(corretos)}")
    print(f"sem identidade validada: {len(ponte) - len(corretos)}")
    print(f"candidatos com identidade diferente: {candidatos_errados}")
    print(f"respostas 404: {len(erros_404)}")
    print(f"falhas finais: {len(falhas)}")
    print(f"jsonl em disco: {tamanho / 1024 / 1024:.1f} mb")
    print(f"tempo desta execução: {(time.monotonic() - inicio) / 60:.1f} min")


def verificar_credencial(cliente: ClienteTmdb) -> None:
    """uma requisição antes do crawl: credencial inválida aborta aqui, não depois de 17 mil tentativas"""
    registro = cliente.requisitar(Tarefa("movie", "tt0137523", 550))
    status = registro["status_http"]
    resposta = registro["resposta"] or {}
    imdb = (resposta.get("external_ids") or {}).get("imdb_id")
    if status == 401:
        raise SystemExit("credencial recusada pelo tmdb (401): confira o .env")
    if status != 200 or imdb != "tt0137523":
        raise SystemExit(f"pré-voo falhou: status {status}, imdb_id {imdb!r}, erro {registro['erro']!r}")
    for chave in ("release_dates", "external_ids", "keywords", "credits"):
        if chave not in resposta:
            raise SystemExit(f"pré-voo: a resposta veio sem '{chave}'; o append_to_response não funcionou")
    print(f"pré-voo ok: /movie/550 -> {resposta.get('title')} ({imdb}), {registro['duracao_segundos']}s")


def carregar_dotenv() -> None:
    """lê um .env na raiz do projeto, se existir; variável já exportada tem prioridade"""
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    load_dotenv(PROJECT_ROOT / ".env")


def argumentos() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="baixa e valida o frame do tmdb")
    parser.add_argument("--rate", type=float, default=DEFAULT_RATE)
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--dry-run", action="store_true", help="só mostra o plano, sem rede")
    parser.add_argument("--checar", action="store_true", help="só valida a credencial com uma requisição")
    return parser.parse_args()


def main() -> None:
    args = argumentos()
    inicio = time.monotonic()
    ponte, candidatos_divergentes = carregar_ponte()
    sem_id = {tconst for tconst, item in ponte.items() if item["tmdb_id"] is None}
    print(f"frame: {len(ponte)}")
    print(f"sem tmdb_id: {len(sem_id)}")
    print(f"divergentes: {len(candidatos_divergentes)}")
    print(f"candidatos das divergências: {sum(map(len, candidatos_divergentes.values()))}")
    if args.dry_run:
        return

    carregar_dotenv()
    cliente = ClienteTmdb(args.rate)
    verificar_credencial(cliente)
    if args.checar:
        return

    TMDB_DIR.mkdir(parents=True, exist_ok=True)
    registros = carregar_registros()

    executar_lotes(
        cliente,
        [Tarefa("find", tconst) for tconst in sorted(sem_id)],
        registros,
        args.workers,
        args.batch_size,
    )
    candidatos_find = candidatos_do_find(registros)
    executar_lotes(
        cliente,
        tarefas_filme(ponte, candidatos_divergentes, candidatos_find),
        registros,
        args.workers,
        args.batch_size,
    )

    # tenta o /find também nos ids existentes que falharam na validação de identidade
    sem_identidade = sem_identidade_correta(ponte, registros)
    executar_lotes(
        cliente,
        [Tarefa("find", tconst) for tconst in sorted(sem_identidade)],
        registros,
        args.workers,
        args.batch_size,
    )
    candidatos_find = candidatos_do_find(registros)
    executar_lotes(
        cliente,
        tarefas_filme(ponte, candidatos_divergentes, candidatos_find),
        registros,
        args.workers,
        args.batch_size,
    )
    resumo(ponte, registros, inicio)


if __name__ == "__main__":
    main()
