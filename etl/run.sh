#!/usr/bin/env bash
# roda o pipeline inteiro na ordem certa. o crawl do tmdb (ops/crawl_tmdb.py) fica de fora porque só roda
# uma vez e precisa de credencial; ele depende do silver, então num clone limpo é: run.sh -> crawl -> run.sh
# uso: etl/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
py=ops/venv-gestao/bin/python

sql() { $py ops/run_sql.py "etl/$1.sql"; }

mkdir -p datalake/bronze datalake/silver datalake/gold   # o copy ... to do duckdb não cria diretório

SECONDS=0; sql bronze > etl/bronze.log; echo "bronze ok em ${SECONDS}s"
SECONDS=0; sql silver > etl/silver.log; echo "silver ok em ${SECONDS}s"

if [ ! -d datalake/landing/tmdb ]; then
  echo "sem datalake/landing/tmdb: agora rode 'ops/venv-gestao/bin/python ops/crawl_tmdb.py' (precisa do .env) e depois etl/run.sh de novo"
  exit 0
fi

SECONDS=0; $py etl/processa_tmdb.py > etl/processa_tmdb.log; echo "processa_tmdb ok em ${SECONDS}s"
for s in silver_tmdb silver_notas gold gold_tmdb gold_notas; do
  SECONDS=0; sql $s > etl/$s.log; echo "$s ok em ${SECONDS}s"
done
SECONDS=0; $py etl/checks.py > etl/checks.log; echo "checks ok em ${SECONDS}s"
