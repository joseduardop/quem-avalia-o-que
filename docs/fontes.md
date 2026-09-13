# Fontes

Todas as fontes ficam em `datalake/landing/`, fora do git (os termos de uso não permitem redistribuir). `ops/download_fontes.sh` baixa e extrai tudo na forma que o `etl/bronze.sql` espera; o TMDB é o único que precisa de credencial e de crawl (`ops/crawl_tmdb.py`).

| fonte | o que se usa | coleta | licença / termos | como baixar |
|---|---|---|---|---|
| **IMDb non-commercial datasets** | `title.basics` (tipo, título, ano, duração, gêneros), `title.ratings` (nota média, votos). `title.akas` foi testado como proxy de país e descartado | 13/09/2026 | uso pessoal e não comercial; sem redistribuição ([termos](https://developer.imdb.com/non-commercial-datasets/)) | `https://datasets.imdbws.com/` |
| **TMDB API** | por filme: `external_ids` (valida o `imdb_id`), notas, países de produção, classificação indicativa, elenco, keywords | 13/09/2026, 17.858 requisições | [termos da API](https://www.themoviedb.org/api-terms-of-use); atribuição obrigatória: *This product uses the TMDB API but is not endorsed or certified by TMDB* | chave em https://www.themoviedb.org/settings/api, `.env`, `ops/crawl_tmdb.py` |
| **MovieLens ml-32m** | `links.csv` (movieId -> imdbId, tmdbId) e `ratings.csv` (32M notas com timestamp, 1995-2023) | gerado em 13/10/2023 | uso de pesquisa, sem redistribuição; citar Harper & Konstan (2015) | `https://files.grouplens.org/datasets/movielens/ml-32m.zip` |
| **MovieLens ml-1m** | `ratings.dat`, `users.dat` (faixa etária, gênero, ocupação), `movies.dat`; janela 04/2000-02/2003 | 2003 | idem | `https://files.grouplens.org/datasets/movielens/ml-1m.zip` |
| **Letterboxd film ratings** (freeth, Kaggle) | `films.csv` (slug, nome, ano), `ratings.csv` (18,2M notas de 11.061 usuários) | dump de 10/10/2023 | conforme o dataset no Kaggle; é amostra de usuários pesados, não a plataforma | `kaggle datasets download -d freeth/letterboxd-film-ratings` |
| **Wikidata** | P6127 (slug do Letterboxd) -> P345 (IMDb) e P4947 (TMDB), 269.188 linhas | 13/09/2026 | CC0 | `ops/wikidata.sparql` via WDQS (`curl`, no script) |
| **Box Office Mojo** (scraper de tjwaterman99) | receita diária por filme, 2000-2025 | 07/01/2025 | dado raspado de terceiros; ainda não entra no pipeline | release no GitHub (no script) |

## Ordem pra reconstruir do zero

```bash
ops/download_fontes.sh              # ~5 gb em datalake/landing
cp .env.example .env                # e preenche a chave do tmdb
ops/venv-gestao/bin/python ops/crawl_tmdb.py   # ~15 min, 559 mb em landing/tmdb
etl/run.sh                          # bronze -> silver -> gold + checks, ~20 s
ops/empacotar.sh                    # zip pra análise em datalake/pacote
```

Os números dos relatórios (`recon/`, `docs/`) correspondem às coletas acima. IMDb, TMDB e Wikidata mudam todo dia: baixar de novo muda o frame (filmes cruzam os 5.000 votos, ids são fundidos no TMDB). Pra reproduzir os números da E1, usa o pacote congelado, não o download.

## Citações

- Harper, F. M., & Konstan, J. A. (2015). The MovieLens Datasets: History and Context. *ACM Transactions on Interactive Intelligent Systems*, 5(4), Article 19. https://doi.org/10.1145/2827872
- IMDb. Non-Commercial Datasets. https://developer.imdb.com/non-commercial-datasets/
- The Movie Database (TMDB) API. https://www.themoviedb.org/. *This product uses the TMDB API but is not endorsed or certified by TMDB.*
- freeth. Letterboxd film ratings [dataset]. Kaggle. https://www.kaggle.com/datasets/freeth/letterboxd-film-ratings
- Wikidata contributors. Property P6127 (Letterboxd film ID). https://www.wikidata.org/ (CC0)
