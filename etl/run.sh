#!/usr/bin/env bash
# roda o pipeline inteiro na ordem certa, menos o crawl do tmdb (ops/crawl_tmdb.py, que só precisa rodar uma vez)
# uso: etl/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
py=ops/venv-gestao/bin/python


sql() { $py ops/run_sql.py "etl/$1.sql"; }

SECONDS=0; sql bronze > etl/bronze.log; echo "bronze ok em ${SECONDS}s"
SECONDS=0; $py etl/processa_tmdb.py > etl/processa_tmdb.log; echo "processa_tmdb ok em ${SECONDS}s"
for s in silver silver_tmdb silver_notas gold gold_tmdb gold_notas; do
  SECONDS=0; sql $s > etl/$s.log; echo "$s ok em ${SECONDS}s"
done
SECONDS=0; $py etl/checks.py > etl/checks.log; echo "checks ok em ${SECONDS}s"
