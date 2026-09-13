# Ponte do Wikidata e frame congelado - relatório

Sessão 2. Continuação de `recon/relatorio.md`. Rodado em 13/09/2026 com duckdb 1.5.5.

Pipeline: `etl/bronze.sql` -> `etl/silver.sql` -> `etl/gold.sql`, cada um com `ops/venv-gestao/bin/python ops/run_sql.py etl/<etapa>.sql`. Roda inteiro em uns 7 segundos. Logs de cada etapa em `etl/*.log`.

## tl;dr

- **`dim_titulo` congelado com 17.810 filmes.** Não 18,9k: a estimativa esqueceu que 2024-2026 já têm 1.197 filmes com 5k+ votos. O corte está certo.
- **Wikidata puro basta.** 99,6% do frame tem slug, 98,5% do frame tem slug que existe no dump do Letterboxd. Critério era 85%.
- **Cadeia inteira:** 17.810 -> 17.742 (slug) -> 17.547 (no dump) -> 16.377 (30+ notas) -> 13.477 (100+ notas). A perda grande é no volume de notas, que é limite da amostra do Letterboxd, não da ponte.
- **`tmdb_id` resolvido pra 99,8% do frame** juntando MovieLens e Wikidata. Sobram 29 filmes pro `/find`. 19 divergências entre as duas fontes (0,1%), documentadas, MovieLens prevalece e o crawl confere.
- **Duplicatas do Wikidata são produto cartesiano do SPARQL** sobre propriedade multivalorada. Regra: uma linha por par `(imdb_id, slug)`, flags de ambiguidade, e desempate por volume de notas pra fechar em uma linha por tconst. Dentro do frame a ambiguidade toca 6 filmes.

## Estrutura adotada

```
datalake/landing/   como veio da fonte, imutável (era bare/ + datalake/)
datalake/bronze/    um parquet por fonte, tipado, sem regra de negócio
datalake/silver/    regra de negócio: dim_titulo, ponte_ids e apoio
datalake/gold/      agregados pra análise: por enquanto a cobertura da ponte
etl/                os três scripts sql e os logs
```

`datalake/` inteiro está no `.gitignore`: dado fica local, os termos de uso das fontes não permitem redistribuir. O que se versiona é o código que reconstrói tudo (uns 7 segundos a partir do landing).

Bronze tem só as fontes que esta sessão usa: `imdb_basics`, `imdb_ratings`, `movielens_links`, `letterboxd_films`, `letterboxd_ratings`, `wikidata_ponte`. Akas, ml-1m, ratings do ml-32m e box office entram quando forem necessários.

## 1. Bronze do Wikidata

O TSV veio no formato completo do WDQS: cabeçalho `?imdb ?lb ?tmdb`, literais entre aspas duplas, vazio quando falta. Sem coluna de URI de entidade. O que precisou de limpeza:

| coluna | problema | linhas | tratamento |
|---|---|---|---|
| todas | blank node `<http://www.wikidata.org/.well-known/genid/...>` (= "valor desconhecido" em RDF) | 6 | vira nulo |
| `imdb` | `nm2118717`, id de pessoa | 1 | fica; não casa com nada |
| `lb` | `film:724393` | 1.313 | **fica: é forma legítima**, o próprio `films.csv` tem 1.652 ids assim |
| `lb` | url `boxd.it/...`, barra no fim, uma maiúscula | 5 | fica; não casa (o join usa `lower()`) |
| `tmdb` | `1485702-hur-kod-sikora` (formato de url) | 2 | extrai o número |
| `tmdb` | url completa `themoviedb.org/movie/NNN` | 1 | extrai o número |
| `tmdb` | `Q135871826` (qid) | 1 | vira nulo |

Resultado: `datalake/bronze/wikidata_ponte.parquet`, 269.188 linhas, colunas `imdb_id varchar`, `letterboxd_slug varchar`, `tmdb_id integer`. Sem deduplicação.

## 2. Cardinalidade e a regra adotada

| medida | valor |
|---|---|
| linhas | 269.188 |
| `imdb_id` distintos | 268.372 |
| `letterboxd_slug` distintos | 268.130 (idem em `lower()`: caixa não é problema) |
| pares `(imdb_id, slug)` distintos | 268.645 |
| `tmdb_id` preenchido / distintos | 264.744 / 263.639 |

**`imdb_id` em mais de uma linha: 314 ids, 1.124 linhas.** Por mecanismo:

| tipo | imdb_ids | linhas |
|---|---|---|
| slug e tmdb diferentes | 122 | 735 |
| slug diferente, tmdb igual ou ausente | 107 | 214 |
| linha idêntica | 65 | 134 |
| mesmo slug, tmdb diferente (P4947 multivalorado) | 20 | 41 |

**`letterboxd_slug` em mais de uma linha: 586 slugs.** 463 com `imdb_id` diferente (1.371 linhas - IMDb duplicado, tipo `99-women` -> tt0063977 e tt0064445, ou item errado) e 123 com o mesmo imdb.

O exemplo canônico é `enoch-arden-1911`: 2 valores de P345 x 3 de P6127 x 3 de P4947 = 18 linhas pra um item. O SPARQL faz o produto cartesiano das propriedades multivaloradas; a "diferença de 473" do briefing é isso.

**Regra (em `etl/silver.sql`, tabela `wd_pares`):**

1. fora: `imdb_id` nulo (blank node), `imdb_id` que não é `tt...`, slug nulo
2. `distinct` tira as linhas idênticas
3. uma linha por par `(imdb_id, lower(slug))`; se o par tem mais de um `tmdb_id`, fica o menor (entrada mais antiga do TMDB) e `n_tmdb` registra que houve escolha
4. `slug_ambiguo`: o imdb tem mais de um slug. `slug_compartilhado`: o slug tem mais de um imdb

Resultado: 268.643 pares, 268.371 imdb distintos, 501 pares com slug ambíguo (229 imdb), 977 com slug compartilhado, 285 com tmdb ambíguo. Salvo em `datalake/silver/wikidata_pares.parquet` - é a ponte inteira, serve pra qualquer corte.

Pra fechar em **uma linha por tconst** (tabela `slug_por_tconst`), o desempate entre slugs do mesmo imdb é: o que existe no dump primeiro, depois o que tem mais notas, depois alfabético. Dentro do frame a ambiguidade toca **6 filmes** (slug ambíguo), 9 têm slug compartilhado com algum tconst fora do frame, e **nenhum slug é compartilhado por dois tconst do frame** - não há dupla contagem de nota do Letterboxd. Os 3 com tmdb ambíguo o crawl resolve: `/movie/{id}` devolve o `imdb_id`, então dá pra conferir todo `tmdb_id` contra o tconst.

## 3. `dim_titulo`: 17.810 filmes

Query do briefing, sem alteração. `datalake/silver/dim_titulo.parquet`, colunas `tconst, titulo, titulo_original, ano, decada, duracao, generos`.

Reconciliação com os 19.077 do recon (`movie`, 5k+ votos, sem recorte temporal):

| bloco | filmes |
|---|---|
| 1930-2023 | **17.810** |
| 2024-2026 | 1.197 (2024: 525, 2025: 476, 2026: 196) |
| antes de 1930 | 70 |

A estimativa de 18,9k supôs uns 100 filmes pós-2023; são 1.197. Nada a corrigir.

## 4. Os cinco elos

Total, sobre o `dim_titulo`:

| elo | filmes | % do frame |
|---|---|---|
| no frame | 17.810 | 100 |
| tem slug no Wikidata | 17.742 | 99,6 |
| slug existe no dump | 17.547 | 98,5 |
| tem 1+ nota | 17.547 | 98,5 |
| tem 30+ notas | 16.377 | 92,0 |
| tem 100+ notas | 13.477 | 75,7 |

"tem 1+ nota" é idêntico a "slug no dump": o `films.csv` é derivado do `ratings.csv`, todo filme lá tem nota. Elo redundante nesse dataset.

Por década:

| década | frame | slug | no dump | 30+ | 100+ | % slug | % dump | % 30+ | % 100+ |
|---|---|---|---|---|---|---|---|---|---|
| 1930 | 198 | 198 | 197 | 197 | 196 | 100,0 | 99,5 | 99,5 | 99,0 |
| 1940 | 320 | 320 | 319 | 319 | 313 | 100,0 | 99,7 | 99,7 | 97,8 |
| 1950 | 460 | 460 | 455 | 453 | 431 | 100,0 | 98,9 | 98,5 | 93,7 |
| 1960 | 636 | 636 | 628 | 626 | 566 | 100,0 | 98,7 | 98,4 | 89,0 |
| 1970 | 860 | 860 | 855 | 819 | 768 | 100,0 | 99,4 | 95,2 | 89,3 |
| 1980 | 1.409 | 1.409 | 1.402 | 1.360 | 1.263 | 100,0 | 99,5 | 96,5 | 89,6 |
| 1990 | 2.175 | 2.175 | 2.165 | 2.083 | 1.799 | 100,0 | 99,5 | 95,8 | 82,7 |
| 2000 | 3.831 | 3.827 | 3.815 | 3.516 | 2.678 | 99,9 | 99,6 | 91,8 | 69,9 |
| 2010 | 5.690 | 5.659 | 5.628 | 5.205 | 4.061 | 99,5 | 98,9 | 91,5 | 71,4 |
| 2020 | 2.231 | 2.198 | 2.083 | 1.799 | 1.402 | 98,5 | 93,4 | 80,6 | 62,8 |

Por faixa de votos:

| faixa | frame | slug | no dump | 30+ | 100+ | % slug | % dump | % 30+ | % 100+ |
|---|---|---|---|---|---|---|---|---|---|
| 100k+ | 2.632 | 2.632 | 2.621 | 2.612 | 2.605 | 100,0 | 99,6 | 99,2 | 99,0 |
| 25k-100k | 4.215 | 4.212 | 4.183 | 4.119 | 3.954 | 99,9 | 99,2 | 97,7 | 93,8 |
| 5k-25k | 10.963 | 10.898 | 10.743 | 9.646 | 6.918 | 99,4 | 98,0 | 88,0 | 63,1 |

Leitura: a ponte em si (slug + dump) segura 98-100% em toda década e faixa. Onde se perde é no volume de notas, e a perda vai na direção esperada - filme dos anos 2000-2020 e da faixa 5k-25k é o que menos chega a 100 notas na amostra de 11k usuários. Os anos 1930-1950 têm cobertura melhor que os 2010, que é o perfil cinéfilo da amostra aparecendo. Isso vira ponto do texto da E1.

Contra a estimativa por título+ano do recon (piso de 92,1 / 84,7 / 56,2% com 100+ notas por faixa), o Wikidata dá 99,0 / 93,8 / 63,1: uns 7 pontos a mais em cada faixa. Título+ano é pior mesmo.

Os 263 que não chegam ao dump (68 sem slug + 195 com slug fora do dump) se dividem em:

- **108 lançados em 2023**, depois do dump de outubro (Godzilla Minus One, The Iron Claw, Leave the World Behind...). Nenhum join resolve.
- **155 restantes**: slug que mudou depois do dump (`payback` -> `payback-straight-up`, `psycho-goreman` -> `pg-psycho-goreman`, `i-spit-on-your-grave` -> `day-of-the-woman`) ou filme sem P6127 no Wikidata. Título+ano recuperaria 68 deles, **36 com 30+ notas - 0,2% do frame.**

## 5. `ponte_ids` e as divergências de `tmdb_id`

`datalake/silver/ponte_ids.parquet`, uma linha por tconst do frame: `tconst, tmdb_id, letterboxd_slug, metodo_join, slug_ambiguo, slug_compartilhado`.

`metodo_join` diz de onde veio o `tmdb_id`:

| metodo_join | filmes | % |
|---|---|---|
| ambos (concordam) | 16.819 | 94,4 |
| wikidata (só) | 904 | 5,1 |
| movielens (só) | 39 | 0,2 |
| nenhum -> `/find` | 29 | 0,2 |
| divergente | 19 | 0,1 |

O MovieLens sozinho cobria 88,8%; com o Wikidata vai a **99,8%** (17.781 de 17.810). O crawl do TMDB da próxima sessão são ~17,8k `/movie/{id}` + 29 `/find`.

**19 divergências** (lista completa em `etl/silver.log`). Padrão: o TMDB tem duas entradas pro mesmo filme (versão original vs. remontagem, dublagem ou duplicata) e cada fonte apontou pra uma. Exemplos:

| tconst | título | movielens | wikidata |
|---|---|---|---|
| tt0056142 | King Kong vs. Godzilla (1963) | 1680 | 686487 |
| tt0839995 | Superman II: The Richard Donner Cut | 429486 | 624479 |
| tt1937390 | Nymphomaniac: Vol. I | 110414 | 258216 |
| tt2250912 | Spider-Man: Homecoming | 202249 | 315635 |
| tt0448694 | Puss in Boots (2011) | 58423 | 417859 |

Decisão: o `tmdb_id` fica com o do MovieLens (curado filme a filme pelo GroupLens) e a linha leva `metodo_join = 'divergente'`; o valor do Wikidata segue em `datalake/silver/wikidata_pares.parquet`. Não é escolha final: o `/movie/{id}` do TMDB devolve `imdb_id`, então o crawl confere as duas candidatas e fica com a que bate no tconst. Spider-Man: Homecoming, por exemplo, provavelmente é o Wikidata que está certo.

## Recomendação

**Wikidata puro basta.** 98,5% no elo "slug existe no dump", contra 85% do critério, e uniforme por década e faixa.

Não fazer segundo passe por título+ano como mecanismo geral: renderia 36 filmes com 30+ notas (0,2%) e traria o risco de casar filme errado em 17,8k linhas. Se quiser os 36, o jeito é um passe **direcionado só nos 263 não resolvidos**, com a lista revisada a olho - cabe numa tela. Fica como opcional, não como etapa.

## Armadilhas novas

- **`film:NNN` é slug legítimo do Letterboxd**, não sujeira. Não "limpar".
- **Blank node do WDQS** (`<http://www.wikidata.org/.well-known/genid/...>`) é "valor desconhecido", aparece em qualquer coluna e não é um id. Vira nulo.
- **Propriedade multivalorada no SPARQL vira produto cartesiano.** 18 linhas pra um item com 2x3x3 valores. Sempre contar distintos antes de qualquer join.
- **`films.csv` está contido em `ratings.csv`**: não existe filme sem nota no dump. "Existe no dump" e "tem 1+ nota" são a mesma coisa.
- **Slug do Letterboxd muda com o tempo** (sufixo de ano corrigido, título alternativo). O Wikidata guarda o atual, o dump de 2023 tem o antigo. É a maior parte da perda recuperável.
- `/usr/bin/time` não existe no Arch; usei `SECONDS` do bash.

## Arquivos

```
etl/bronze.sql, etl/silver.sql, etl/gold.sql    pipeline, com os logs ao lado
datalake/bronze/wikidata_ponte.parquet          269.188 linhas, fiel ao tsv
datalake/silver/dim_titulo.parquet              17.810 filmes, o contrato
datalake/silver/ponte_ids.parquet               tconst | tmdb_id | letterboxd_slug | metodo_join | flags
datalake/silver/wikidata_pares.parquet          a ponte inteira com a regra aplicada (268.643 pares)
datalake/silver/slug_por_tconst.parquet         um slug por tconst do frame, com n_notas_lb
datalake/silver/lb_volume.parquet               notas por film_id no letterboxd
datalake/gold/cobertura_ponte*.parquet          os cinco elos: total, por década, por faixa
```
