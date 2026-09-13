# fato_notas e o pacote de entrega - relatório

Sessão 4, 13/09/2026. Fecha a engenharia. Continuação de `recon/relatorio.md` (s1), `docs/ponte-wikidata.md` (s2) e `docs/confundimento-tmdb.md` (s3). O pacote pra análise está descrito em `docs/README-tabelao.md`.

## tl;dr

- **`fato_notas` com 70.029 linhas em quatro plataformas; 16.759 títulos (94,1%) têm as quatro.** Sem filtro de volume.
- **O gradiente de idade do ml-1m era composição da cesta.** A média bruta sobe 3,56 -> 3,78 com a idade; o desvio dentro do filme fica entre -0,02 e +0,07 e não é monotônico. Cada faixa avaliou um catálogo diferente, não o mesmo filme de forma diferente.
- **Letterboxd é a plataforma que mais descola.** Correlação de z-score: IMDb-ml32 0,93, IMDb-TMDB 0,90, IMDb-Letterboxd 0,85, Letterboxd-TMDB 0,76.
- **Demografia cobre 2.717 títulos (15,3% do frame)**, não os ~3.400 estimados: aquele número era do frame de 1k votos.
- **22 países com 30+ filmes de país único**, 12 com 100+. Coprodução é categoria própria.
- **Deriva do ml-32m tem volume de 1996 a 2023**, com 1.300-2.800 filmes por ano com 100+ notas.
- Pipeline inteiro roda com `etl/run.sh` em ~20s (o crawl já está em landing).

## As duas decisões

**País.** `silver/titulo_pais` em formato longo (`tconst | pais`, 25.609 linhas, 17.742 títulos). `dim_titulo` ganhou `n_paises`, `pais_unico` (só quando `n_paises = 1`) e `tem_us`. Sem país primário: a ordem do TMDB não significa nada e idioma não é nacionalidade. 12.647 filmes com país único, 5.095 coproduções, 68 sem país.

**`tipo_medida`.** `fato_notas` e `fato_notas_demografia` levam `data_coleta` e `tipo_medida`. IMDb e TMDB são `acumulado` de 2026-09-13, Letterboxd `acumulado` de 2023-10-10 (data do dump), ml-32m `acumulado` de 2023-10-13 (geração do dataset, última nota em 2023-10-12). ml-1m é `janela` com `data_coleta` 2003-02-28, fim do intervalo que começa em 2000-04-25 e tem 90% das notas em 2000.

## 1. `fato_notas`

| plataforma | títulos | % do frame | nota média | dp | votos (mediana) | abaixo de 30 votos |
|---|---|---|---|---|---|---|
| imdb | 17.810 | 100,0 | 6,51 | 1,04 | 16.013 | 0 |
| tmdb | 17.795 | 99,9 | 6,48 | 0,85 | 352 | 396 |
| letterboxd | 17.547 | 98,5 | 3,02 | 0,68 | 319 | 1.170 |
| ml32 | 16.877 | 94,8 | 3,21 | 0,51 | 207 | 2.615 |

| plataformas por título | títulos |
|---|---|
| 4 | 16.759 |
| 3 | 900 |
| 2 | 142 |
| 1 | 9 |

Os 15 sem TMDB: 5 sem registro validado (sessão 3) e 10 com `vote_count = 0` - nota 0,0 sem voto é ausência de medida, ficou fora. Os 933 sem ml32 são em grande parte lançamentos depois de outubro de 2023 (a cobertura do MovieLens era 88,8% no frame de 5k *antes* do recorte temporal; tirando 2024-2026, sobe pra 94,8%).

A tabela é longa de propósito: plataforma nova é `insert`, e a normalização é uma window function particionada por plataforma.

## 2. `fato_notas_demografia`

33.361 linhas em (título, faixa etária, gênero), **2.717 títulos, 15,3% do frame**, 969.644 notas - 97% das notas do ml-1m, então o que falta é filme que o MovieLens de 2000 não tinha, não filme que o frame perdeu. Escala 1-5 inteira. Limitação a declarar no texto.

## 3. Gradiente de idade: composição da cesta

`gold/gradiente_idade`. A média bruta por faixa contra o desvio de cada nota em relação à média do mesmo filme entre todos os avaliadores:

| faixa | notas | média bruta | desvio no filme | mulheres | homens |
|---|---|---|---|---|---|
| <18 | 26.434 | 3,558 | +0,068 | +0,155 | +0,026 |
| 18-24 | 178.901 | 3,515 | +0,006 | -0,066 | +0,030 |
| 25-34 | 384.227 | 3,551 | -0,019 | +0,013 | -0,028 |
| 35-44 | 192.573 | 3,624 | +0,002 | +0,021 | -0,004 |
| 45-49 | 80.450 | 3,647 | -0,002 | -0,006 | 0,000 |
| 50-55 | 69.719 | 3,720 | +0,036 | +0,075 | +0,024 |
| 56+ | 37.340 | 3,775 | +0,038 | +0,132 | +0,009 |

**Não sobrevive.** Bruto, a amplitude é 0,26 estrela e monotônica; dentro do filme cai pra 0,09 e vira um U raso. O que existe de residual está nas pontas e é puxado por mulheres (<18 +0,16, 56+ +0,13), com n pequeno nas duas. Faixa etária mais velha dava nota maior porque avaliava filme melhor avaliado, não porque era generosa. Isso entra no relatório da E1 como o exemplo de por que média bruta engana.

## 4. Países com estrato limpo

`pais_unico` com 30+ filmes (a tabela completa está no `etl/silver_notas.log`):

| país | país único | em coprodução com US | em coprodução sem US | % único |
|---|---|---|---|---|
| US | 7.984 | - | 3.228 | 71,2 |
| IN | 1.236 | 77 | 54 | 90,4 |
| GB | 670 | 1.387 | 539 | 25,8 |
| JP | 412 | 136 | 75 | 66,1 |
| FR | 400 | 455 | 955 | 22,1 |
| TR | 247 | 13 | 43 | 81,5 |
| CA | 179 | 562 | 143 | 20,2 |
| KR | 174 | 28 | 30 | 75,0 |
| IT | 163 | 147 | 367 | 24,1 |
| DE | 150 | 503 | 455 | 13,5 |
| ES | 136 | 119 | 206 | 29,5 |
| AU | 114 | 147 | 65 | 35,0 |
| HK | 83 | 90 | 122 | 28,1 |
| RU | 58 | 28 | 25 | 52,3 |
| SE | 55 | 35 | 169 | 21,2 |
| PL | 49 | 17 | 39 | 46,7 |
| IR | 47 | 1 | 16 | 73,4 |
| SU | 39 | 2 | 6 | 83,0 |
| DK | 37 | 29 | 138 | 18,1 |
| MX | 34 | 71 | 30 | 25,2 |
| BR | 32 | 29 | 25 | 37,2 |
| NO | 30 | 14 | 74 | 25,4 |

Dois perfis: cinema nacional que circula sozinho (IN, TR, KR, JP, IR, SU - 66-90% único) e cinema europeu/anglófono que quase só existe em coprodução (DE 13,5%, DK 18%, CA 20%, FR e SE 21-22%, GB 26%). Pra GB, CA e DE, o estrato "coprodução com US" é maior que o estrato limpo, e `tem_us` é o filtro que separa os dois. O Brasil tem 32 filmes de país único - dá pra citar, não pra estratificar.

## 5. Amplitude temporal do `ml32_por_ano`

`bronze/ml32_por_ano` tem 487.846 linhas (filme x ano); `gold/deriva_ml32` restringe ao frame. 1995 tem 4 notas e não conta. De 1996 em diante:

| período | filmes com 100+ notas no ano |
|---|---|
| 1996-1999 | 700-1.700 |
| 2000-2005 | 2.100-2.700 |
| 2006-2014 | 1.300-2.100 (vale em 2012-2014) |
| 2015-2021 | 2.200-2.800 |
| 2022-2023 | 1.600-1.800 |

Volume por filme-ano é o limite: só ~1.500-2.800 filmes por ano têm 100+ notas, e a composição do catálogo avaliado muda com o tempo (o MovieLens de 1996 avaliava lançamento; o de 2020 avalia de tudo). `desvio_do_ano` é contra a média do próprio filme, o que tira a composição entre filmes, mas não a mudança de quem avalia. Serve pra deriva de filme individual e de coortes de lançamento; não serve pra "a nota média do MovieLens subiu".

## Normalização, como ficou

- `gold/notas_normalizadas`: `fato_notas` com `n_votos >= 30`, `nota_z` (z-score) e `nota_pct` (`percent_rank`) particionados por plataforma. O mínimo de 30 é a única regra: média de 11 notas é ruído. Fica com 17.810 / 17.399 / 16.377 / 14.262 títulos (imdb / tmdb / letterboxd / ml32).
- `gold/divergencia_par`: pra cada par, o z é recalculado sobre os títulos que **as duas** plataformas têm - senão a diferença de cobertura (Letterboxd não tem o não-cânone) vira gap. `gap_z = z_b - z_a` com plataformas em ordem alfabética.

| par | títulos | correlação z | dp do gap |
|---|---|---|---|
| imdb x ml32 | 14.262 | 0,925 | 0,39 |
| imdb x tmdb | 17.399 | 0,898 | 0,45 |
| imdb x letterboxd | 16.377 | 0,849 | 0,55 |
| ml32 x tmdb | 14.261 | 0,845 | 0,56 |
| letterboxd x ml32 | 14.002 | 0,805 | 0,63 |
| letterboxd x tmdb | 16.329 | 0,758 | 0,70 |

IMDb, TMDB e MovieLens concordam entre si; o Letterboxd é o que discorda de todos. É a tese do projeto aparecendo antes de qualquer análise.

## Pipeline

```
etl/run.sh                 roda tudo na ordem, menos o crawl: bronze -> processa_tmdb -> silver -> silver_tmdb
                           -> silver_notas -> gold -> gold_tmdb -> gold_notas, ~20s, logs em etl/*.log
etl/bronze.sql             + ml1_users, ml1_ratings, ml1_movies, ml32_ratings (32M), ml32_por_ano
etl/silver_notas.sql       titulo_pais, colunas de país no dim_titulo, fato_notas, fato_notas_demografia
etl/gold_notas.sql         notas_normalizadas, divergencia_par, deriva_ml32, notas_por_faixa_etaria, gradiente_idade
etl/gold.sql               cobertura_decada_quartil virou cobertura_canonicidade
docs/README-tabelao.md     o pacote: dicionário, o que não fazer, perguntas
```

`silver_notas.sql` reescreve `dim_titulo.parquet` com as três colunas de país lendo a lista fixa das colunas base, então é idempotente como o `silver_tmdb.sql`.
