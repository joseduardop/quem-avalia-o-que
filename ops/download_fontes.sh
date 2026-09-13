#!/usr/bin/env bash
# baixa e extrai as fontes em datalake/landing/, na forma que o etl/bronze.sql espera
# uso: ops/download_fontes.sh   (uns 5 gb; o dataset do kaggle é público, o cli baixa sem credencial)
# depois: ops/crawl_tmdb.py (precisa do .env com a chave do tmdb) e etl/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
raiz="$PWD"
py="$raiz/ops/venv-gestao/bin/python"
[ -x "$py" ] || py=python3   # extrair zip não precisa do venv; o kaggle precisa (mensagem abaixo)
landing="$raiz/datalake/landing"
mkdir -p "$landing"
cd "$landing"

baixar() { [ -f "$2" ] && echo "já existe: $2" || curl -fL --retry 3 -o "$2" "$1"; }

# imdb: https://developer.imdb.com/non-commercial-datasets/ (uso não comercial)
for f in title.basics title.ratings title.akas; do
  baixar "https://datasets.imdbws.com/$f.tsv.gz" "$f.tsv.gz"
  [ -f "$f.tsv" ] || gunzip -k "$f.tsv.gz"
done

# movielens: https://grouplens.org/datasets/movielens/ (ml-1m tem demografia, ml-32m tem links.csv e timestamp)
# o certificado tls de files.grouplens.org venceu em 28/08/2026 e não foi renovado: se o curl normal falhar,
# baixa sem verificar o certificado e confere o md5 contra o da cópia que gerou este projeto (bate com o
# md5 que o grouplens publica ao lado de cada zip)
md5_movielens() {
  case "$1" in
    ml-1m.zip) echo "c4d9eecfca2ab87c1945afe126590906" ;;
    ml-32m.zip) echo "d472be332d4daa821edc399621853b57" ;;
  esac
}
for d in ml-1m ml-32m; do
  url="https://files.grouplens.org/datasets/movielens/$d.zip"
  if [ ! -f "$d.zip" ]; then
    curl -fL --retry 3 -o "$d.zip" "$url" || { echo "tls do grouplens falhou, baixando sem verificar o certificado"; curl -fL --retry 3 -k -o "$d.zip" "$url"; }
  fi
  echo "$(md5_movielens "$d.zip")  $d.zip" | md5sum -c - || { echo "md5 de $d.zip não bate com o esperado, apague e baixe de novo"; exit 1; }
  [ -d "$d" ] || "$py" -m zipfile -e "$d.zip" .
done

# letterboxd: dataset de freeth no kaggle, amostra de 11 mil usuários, dump de 2023-10-10
if [ ! -d letterboxd-film-ratings ]; then
  [ -x "$raiz/ops/venv-gestao/bin/kaggle" ] || { echo "falta o cli do kaggle: crie o venv e instale o requirements.txt antes"; exit 1; }
  "$raiz/ops/venv-gestao/bin/kaggle" datasets download -d freeth/letterboxd-film-ratings -p .
  mkdir -p letterboxd-film-ratings
  "$py" -m zipfile -e letterboxd-film-ratings.zip letterboxd-film-ratings
fi

# box office mojo (scraper de tjwaterman99), receita diária por filme. ainda não usado no pipeline
baixar "https://github.com/tjwaterman99/boxofficemojo-scraper/releases/latest/download/revenues_per_day.csv.gz" revenues_per_day.csv.gz
[ -f revenues_per_day.csv ] || gunzip -k revenues_per_day.csv.gz

# wikidata: ponte letterboxd -> imdb -> tmdb via wdqs. formato tsv "completo" (literais entre aspas), o bronze limpa.
# são ~270 mil linhas; se estourar o timeout de 60s do wdqs, tenta de novo fora do horário de pico
if [ ! -f wikidata.tsv ]; then
  curl -fsG 'https://query.wikidata.org/sparql' \
    --data-urlencode "query@$raiz/ops/wikidata.sparql" \
    -H 'Accept: text/tab-separated-values' \
    -H 'User-Agent: eps7008-e1/0.1 (ufsc; projeto de disciplina)' \
    -o wikidata.tsv
fi

echo "landing pronto:"; du -sh "$landing"
