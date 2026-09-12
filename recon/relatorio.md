# Reconhecimento das fontes - relatório

Rodado em 13/09/2026 com duckdb 1.5.5 sobre os arquivos em `datalake/`. Script: `recon/recon.sql`, saída completa em `recon/recon.log`, resultados intermediários em `recon/*.parquet`.

## tl;dr

- **Letterboxd não tem ID externo.** Só slug, nome, ano e poster. A ponte vai pelo Wikidata (P6127 -> P345/P4947).
- **Corte recomendado: 5.000 votos no IMDb -> 19.077 filmes.** O gargalo não é o IMDb nem o crawl do TMDB, é o Letterboxd: abaixo de 5k votos a cobertura do Letterboxd desaba (14% dos filmes com 100+ notas).
- **Recorte temporal: 1930-2023.** Anos 1920 ficam com 66 filmes no corte de 5k, fino demais pra estrato próprio. O teto é 2023 porque o dump do Letterboxd é de outubro de 2023.
- **Resolução de IDs sai quase de graça:** 89% do frame de 5k já tem `tmdbId` via MovieLens. Sobram ~2.100 filmes pro `/find`.
- **ml-1m tem volume em todas as faixas etárias** (mínimo 222 usuários em <18), e o `movieId` é o mesmo do ml-32m, então a ponte pro IMDb é direta.
- **`region` do akas não serve como país.** Média de 22 regiões por filme, 96% têm `US`. Fica pro `production_countries` do TMDB.

## 1. Letterboxd tem ID externo? - não

`films.csv` (355.141 linhas): `film_id`, `film_name`, `year`, `poster_url`.
`ratings.csv` (18.175.545 linhas): `user_name`, `film_id`, `rating`.

Nenhuma coluna de `imdb_id` ou `tmdb_id`. O `film_id` é o slug da URL (`letterboxd.com/film/<film_id>/`), que é exatamente o valor que o Wikidata guarda na propriedade P6127. Então a ponte é: P6127 (slug) -> item -> P345 (IMDb) e P4947 (TMDB). O número no `poster_url` (ex.: `51568-fight-club`) é o id interno do Letterboxd, não o TMDB (Fight Club no TMDB é 550) - não ajuda.

Detalhes que importam pro join depois:

- `film_id` é único (355.141 distintos), e todo `film_id` de `ratings.csv` existe em `films.csv` (zero órfão).
- O filme `null` literal existe (linha 176322, "(NULL)", 2013). No duckdb com `nullstr=''` ele sobrevive; no pandas precisa `keep_default_na=False`.
- 6.006 filmes sem ano. Ano vai de 1865 a 2031 (os anos futuros são placeholders com 1-5 notas).
- Notas de 0,5 a 5,0 em meia estrela, sem nulo, média 3,27. Moda em 4,0 (20%), depois 3,0 (19%) e 3,5 (18%).
- **É uma amostra de 11.061 usuários**, ~1.640 notas cada. Usuário pesado, não o público médio da plataforma. Isso é viés e vale citar na E1.

Volume por filme (define quantos filmes têm média confiável no Letterboxd):

| notas no filme | filmes | notas |
|---|---|---|
| 1000+ | 4.111 | 9,8M |
| 100-1000 | 18.056 | 5,5M |
| 30-100 | 25.172 | 1,3M |
| 10-30 | 46.739 | 0,8M |
| <10 | 261.063 | 0,7M |

Só 22.167 filmes têm 100+ notas e 47.339 têm 30+. Esse é o teto prático da camada título-entre-plataformas.

## 2. Calibração do corte de votos

`titleType = 'movie'` com nota: 348.228 filmes.

| faixa | filmes | acumulado (corte no piso) | nota média | dp |
|---|---|---|---|---|
| 100k+ | 2.750 | 2.750 | 6,99 | 0,82 |
| 25k-100k | 4.530 | 7.280 | 6,51 | 1,00 |
| 5k-25k | 11.797 | 19.077 | 6,37 | 1,07 |
| 1k-5k | 29.980 | 49.057 | 6,06 | 1,21 |
| 100-1k | 97.727 | 146.784 | 5,75 | 1,30 |
| <100 | 201.444 | 348.228 | 6,33 | 1,43 |

A nota média sobe com o volume de votos - filme muito votado é filme que sobreviveu. Isso é o argumento pra nunca comparar média contra média entre faixas (nem entre plataformas).

## 3. Cobertura por década

Corte provisório de 1.000 votos, de 1920 em diante (58 filmes antes de 1920, nenhum sem ano):

| década | filmes (1k) | nota média | mediana de votos |
|---|---|---|---|
| 1920 | 242 | 7,03 | 2.280 |
| 1930 | 814 | 6,79 | 2.169 |
| 1940 | 1.140 | 6,80 | 2.643 |
| 1950 | 1.623 | 6,65 | 2.488 |
| 1960 | 2.027 | 6,61 | 2.857 |
| 1970 | 2.619 | 6,47 | 2.760 |
| 1980 | 3.376 | 6,27 | 3.716 |
| 1990 | 4.343 | 6,33 | 5.015 |
| 2000 | 8.463 | 6,20 | 4.087 |
| 2010 | 14.510 | 6,07 | 3.331 |
| 2020 | 9.842 | 6,10 | 2.950 |

E a mesma coisa pra cada corte candidato:

| década | >=100 | >=1k | >=5k | >=25k | >=100k |
|---|---|---|---|---|---|
| 1920 | 945 | 242 | 66 | 13 | 5 |
| 1930 | 3.780 | 814 | 198 | 33 | 8 |
| 1940 | 4.000 | 1.140 | 320 | 62 | 17 |
| 1950 | 5.356 | 1.623 | 460 | 105 | 34 |
| 1960 | 6.914 | 2.027 | 636 | 150 | 41 |
| 1970 | 8.967 | 2.619 | 860 | 242 | 63 |
| 1980 | 10.286 | 3.376 | 1.409 | 508 | 163 |
| 1990 | 12.182 | 4.343 | 2.175 | 953 | 356 |
| 2000 | 22.896 | 8.463 | 3.831 | 1.798 | 783 |
| 2010 | 41.855 | 14.510 | 5.690 | 2.238 | 931 |
| 2020 | 29.277 | 9.842 | 3.428 | 1.177 | 349 |

Tem material em toda década a partir de 1930 em qualquer corte até 5k. Em 25k as décadas antigas viram dezenas de filmes, que não sustenta estrato. Repara que a mediana de votos tem pico nos anos 1990 e cai pros dois lados: corte absoluto penaliza filme velho (menos gente votou) e filme novo (ainda acumulando). Se isso incomodar na E2, a alternativa é corte por percentil dentro da década.

## 4. Cobertura do MovieLens

`links.csv` do ml-32m: 87.585 linhas, `imdbId` único, 124 sem `tmdbId`. Dos 87.585, só 71.264 são `movie` no IMDb (6.052 `tvMovie`, 5.251 `short`, 2.285 `video`, ...) e 227 não existem mais no `title.basics`.

Sobre o frame de 1k votos (49.057 filmes): **79,0% estão no MovieLens** (38.740), e desses 38.735 têm `tmdbId` - só 5 sem. Por faixa:

| faixa | filmes | com tmdbId | % | precisa `/find` |
|---|---|---|---|---|
| 100k+ | 2.750 | 2.611 | 94,9 | 139 |
| 25k-100k | 4.530 | 4.113 | 90,8 | 417 |
| 5k-25k | 11.797 | 10.224 | 86,7 | 1.573 |
| 1k-5k | 29.980 | 21.787 | 72,7 | 8.193 |
| 100-1k | 97.727 | 28.908 | 29,6 | 68.819 |

No corte de 5k: 88,8% resolvido de graça, 2.129 filmes pro `/find` do TMDB. No corte de 1k: 79,0% e 10.322 pro `/find`.

## 5. Demografia do ml-1m

6.040 usuários, 1.000.209 notas, 3.883 filmes. 90,5% das notas são de 2000 (6,8% de 2001, 2,4% de 2002, 0,3% de 2003) - a distância de 26 anos pro IMDb de hoje se sustenta.

| código | faixa | usuários | % | mulheres | notas | nota média |
|---|---|---|---|---|---|---|
| 1 | <18 | 222 | 3,7 | 78 | 27.211 | 3,55 |
| 18 | 18-24 | 1.103 | 18,3 | 298 | 183.536 | 3,51 |
| 25 | 25-34 | 2.096 | 34,7 | 558 | 395.556 | 3,55 |
| 35 | 35-44 | 1.193 | 19,8 | 338 | 199.003 | 3,62 |
| 45 | 45-49 | 550 | 9,1 | 189 | 83.633 | 3,64 |
| 50 | 50-55 | 496 | 8,2 | 146 | 72.490 | 3,72 |
| 56 | 56+ | 380 | 6,3 | 102 | 38.780 | 3,77 |

Toda faixa tem volume: a menor (<18) tem 222 usuários e 27k notas, o que dá pra análise agregada; só não dá pra cruzar <18 com gênero e mais alguma coisa. Nota média sobe monotonicamente com a idade (3,55 -> 3,77), o que já é um achado por si. Mulheres são 28% (1.709).

Ponte pro IMDb: o `movieId` do ml-1m é o mesmo do ml-32m (verificado por título: as 515 diferenças são grafia, título alternativo ou ano corrigido). Via `links.csv`, 3.850 dos 3.883 filmes ganham `tconst`, e 3.417 estão no frame de 1k.

## 6. Proxy de nacionalidade via `akas.region` - não serve

Sobre o frame de 1k votos:

- `region` nula aparece em 100% dos filmes (é a linha do título original), `US` em 96,0%, `GB` em 94,0%, `CA` em 89,6%, `AU` 86,2%, `IN` 82,7%, `ZA` 79,1%...
- Média de 22,2 regiões por filme, mediana 21. Só 186 filmes têm uma região única e 922 têm até três.
- A linha `isOriginalTitle = 1` vem com `region` e `language` nulos em 100% dos casos. Não tem atalho.

Tentei um proxy alternativo: região onde o aka é igual ao `originalTitle`. Funciona pra filme de língua não inglesa (Parasita -> KR, Cidade de Deus -> BR, A Vida é Bela -> IT), mas fica ambíguo pra 84% do frame e falha pra filme de língua compartilhada (Amores Perros bate em 35 regiões) e pra título em escrita não latina (Howl's Moving Castle não bate em nenhuma). Não vale o esforço: `production_countries` do TMDB resolve limpo.

## Estimativa da interseção IMDb x Letterboxd

**Não é o join** (que vai pelo Wikidata). É título+ano exato, só pra dimensionar o corte. É piso: grafia, artigo, tradução e ano deslocado escapam.

| faixa imdb | filmes | casou título+ano | com 30+ notas lb | com 100+ notas lb | % com 100+ |
|---|---|---|---|---|---|
| 100k+ | 2.750 | 2.557 (93%) | 2.540 | 2.533 | 92,1 |
| 25k-100k | 4.530 | 4.065 (90%) | 3.994 | 3.835 | 84,7 |
| 5k-25k | 11.797 | 10.067 (85%) | 9.128 | 6.627 | 56,2 |
| 1k-5k | 29.980 | 22.679 (76%) | 12.019 | 4.233 | 14,1 |
| 100-1k | 97.727 | 57.712 (59%) | 5.423 | 622 | 0,6 |

Aqui está o argumento do corte. A faixa 1k-5k tem 30k filmes no IMDb mas só 4,2k com 100+ notas no Letterboxd - 61% do frame de 1k seria linha só do IMDb. Acima de 5k a cobertura vai de 56% a 92%.

Por década, com 1k no IMDb e 100+ no Letterboxd, a cobertura fica em 41-53% de 1920 a 1990, cai pra 33% nos anos 2000-2010 (muito filme médio) e 19% nos 2020 (dump de out/2023 + pouco tempo pra acumular nota).

## Recomendação

**Corte: `numVotes >= 5000` -> 19.077 filmes.**

1. Cobertura do Letterboxd >= 56% (100+ notas) ou >= 77% (30+ notas) em toda faixa acima de 5k. Abaixo, 14%/40%.
2. Crawl do TMDB: ~19k `/movie/{id}` + ~2,1k `/find`, uns 21k requisições no total, minutos. No corte de 1k seriam ~59k, também tranquilo - o crawl não é o motivo do corte, o Letterboxd é.
3. A ponte Wikidata é um dump só (todos os P6127 de uma vez), independe do corte. O que encolhe é a sobra pra resolver na mão: ~16k filmes com par no Letterboxd em vez de ~28k.
4. 19k filmes é confortável pra explorar em dois dias e pra E2.
5. A tabela longa aceita baixar o corte pra 1k depois sem refazer nada, se a E2 precisar de mais volume. O contrário (subir o corte) é só um `where`.

Filtrar `isAdult = 0` é inócuo (1 filme no corte de 5k). Não filtrar `genres` por enquanto.

**Recorte temporal: 1930-2023.**

- 1920: 66 filmes no corte de 5k, ~35 com Letterboxd. Não sustenta estrato. Ou cai fora, ou entra colado nos 1930 como "<=1939" - decisão de apresentação.
- Teto em 2023 porque o Letterboxd é de outubro de 2023 (2023 tem 331k notas contra 750k de 2022; 2024+ não tem nada). Filme de 2024-2026 no IMDb não tem par. Tratar 2023 como parcial na hora de estratificar.

## Armadilhas novas, descobertas nesta sessão

- **`links.imdbId` é string zero-padded no arquivo** (`0114709`), não inteiro. Quem tira os zeros é o pandas. No duckdb o sniffer mantém `VARCHAR`; `printf('tt%07d', imdbId::bigint)` funciona nos dois casos.
- **No duckdb, `/` entre inteiros dá `DOUBLE`.** A query de década com `(startYear / 10) * 10` devolvia 1994.0 em vez de 1990. Divisão inteira é `//`.
- **`sum(x) over (order by 1)` ordena pela constante 1**, não pela primeira coluna. Acumulado tem que ser em CTE com o nome da coluna.
- 16k dos 87k `links` do MovieLens não são `movie` no IMDb (tvMovie, short, video...). O join com `basics` filtrado por `titleType` cuida disso.
- Box office (`revenues_per_day.csv`): 356k linhas diárias, 7.176 títulos, 2000-01-01 a 2025-01-03, `id` é UUID sem relação com IMDb. Só entra por título+ano ou via TMDB. Fora de escopo agora.

## Arquivos

```
recon/recon.sql                       script completo (rodar com ops/venv-gestao/bin/python ops/run_sql.py recon/recon.sql)
recon/recon.log                       saída da última execução
recon/q4_faixas_votos.parquet         calibração do corte
recon/q5_decadas.parquet              décadas no corte de 1k
recon/q5_decadas_por_corte.parquet    décadas x corte
recon/q6_regioes.parquet              top 25 regiões do akas
recon/q6_proxy_original.parquet       proxy por originalTitle
recon/q7_cobertura_ml.parquet         cobertura movielens no corte de 1k
recon/q7_cobertura_ml_por_faixa.parquet
recon/q8_lb_ratings.parquet           resumo do letterboxd
recon/q8_lb_filmes_por_volume.parquet
recon/q9_ml1_demografia.parquet       faixas etárias do ml-1m
recon/q10_intersecao_estimada.parquet imdb x letterboxd por título+ano (estimativa)
ops/run_sql.py                        runner (não tem o cli do duckdb, só o módulo python)
```
