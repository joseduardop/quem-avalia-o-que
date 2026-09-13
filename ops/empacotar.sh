#!/usr/bin/env bash
# monta o pacote pra análise: silver que o notebook usa + gold inteiro + readme do tabelão + versão
# uso: ops/empacotar.sh  ->  datalake/pacote/pacote-e1-AAAA-MM-DD.zip (sobe pro drive na mão)
set -euo pipefail
cd "$(dirname "$0")/.."

ops/venv-gestao/bin/python etl/checks.py > /dev/null || { echo "checks falharam, não empacoto"; exit 1; }

data=$(date +%F)
nome="pacote-e1-$data"
dir="datalake/pacote/$nome"
rm -rf "$dir"
mkdir -p "$dir/silver" "$dir/gold"

for t in dim_titulo fato_notas fato_notas_demografia titulo_pais tmdb_titulo ponte_ids; do
  cp "datalake/silver/$t.parquet" "$dir/silver/"
done
cp datalake/gold/*.parquet "$dir/gold/"
cp docs/README-tabelao.md "$dir/README.md"

cat > "$dir/VERSAO.txt" <<FIM
pacote: $nome
gerado em: $(date '+%F %H:%M %Z')
commit: $(git rev-parse --short HEAD) ($(git log -1 --format=%s))
checks: $(ops/venv-gestao/bin/python etl/checks.py | tail -1)
fontes: imdb e tmdb coletados em 2026-09-13; letterboxd (kaggle/freeth) dump de 2023-10-10; ml-32m gerado em 2023-10-13; ml-1m janela 2000-2003
FIM

rm -f "datalake/pacote/$nome.zip"
(cd datalake/pacote && "$OLDPWD/ops/venv-gestao/bin/python" -m zipfile -c "$nome.zip" "$nome")
du -sh "datalake/pacote/$nome.zip"
cat "$dir/VERSAO.txt"
