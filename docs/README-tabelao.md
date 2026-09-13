# README do tabelão - o que tem em `datalake/` e como usar sem se machucar

Tudo é Parquet. Lê com `duckdb.sql("select * from 'datalake/gold/notas_normalizadas.parquet'")` ou `pd.read_parquet(...)`. Pra reconstruir do zero: `etl/run.sh` (~20s; o crawl do TMDB já está em `landing/tmdb`). A unidade de análise é o título (`tconst`, id do IMDb); o frame é `silver/dim_titulo`: filme, 5.000+ votos no IMDb, 1930-2023, 17.810 títulos.

## Dicionário

**`silver/dim_titulo`** (17.810) - `tconst` id IMDb; `titulo`, `titulo_original`; `ano`, `decada`; `duracao` min; `generos` IMDb separado por vírgula; `pct_votos_decada` posição do título entre os do frame da mesma década, 0 = menos votado, 1 = mais votado; `n_paises`; `pais_unico` ISO do país quando `n_paises = 1`, senão nulo; `tem_us` EUA está entre os países.

**`silver/fato_notas`** (70.029) - uma linha por (título, plataforma). `plataforma` imdb | tmdb | letterboxd | ml32; `nota` média na escala da plataforma; `escala_min`, `escala_max` (1-10, 0-10, 0,5-5, 0,5-5); `n_votos`; `data_coleta`; `tipo_medida` sempre `acumulado` aqui. Sem filtro de volume: filme com 18 mil votos no IMDb e 11 notas no Letterboxd está aqui, e essa assimetria é dado.

**`silver/fato_notas_demografia`** (33.361, 2.717 títulos) - ml-1m por (título, faixa etária, gênero). `faixa_etaria` <18 ... 56+, `faixa_etaria_cod` pra ordenar; `genero_usuario` F/M; `nota_media` escala 1-5 inteira; `n_notas`; `tipo_medida` = `janela` (2000-04 a 2003-02, 90% em 2000).

**`silver/titulo_pais`** - `tconst`, `pais`: uma linha por país de produção (TMDB). **`silver/tmdb_titulo`** (17.805) - metadado do TMDB validado por `imdb_id`: `vote_average`, `vote_count`, `popularity`, `runtime`, `budget`, `revenue`, `original_language`, `genres`, `keywords`, `production_countries`, `production_companies`, `spoken_languages`, `diretor`, `elenco_principal`, `classificacao_br` (L/10/12/14/16/18), `certificacao_us`. **`silver/ponte_ids`** - `tconst` -> `tmdb_id`, `letterboxd_slug`, `metodo_join`.

**`gold/notas_normalizadas`** - `fato_notas` com `n_votos >= 30`, mais `nota_z` (z-score dentro da plataforma) e `nota_pct` (percentil dentro da plataforma). **`gold/divergencia_par`** - por título e par de plataformas (`plataforma_a` < `plataforma_b`, ordem alfabética): `nota_a/b`, `n_votos_a/b`, `z_a/b` e `pct_a/b` recalculados só sobre os títulos que o par tem em comum, `gap_z = z_b - z_a`, `gap_pct`. Positivo = b avalia relativamente melhor. **`gold/cobertura_canonicidade`** - cobertura do Letterboxd por `decada` x `quartil` de `pct_votos_decada`: `filmes`, `pct_30`, `pct_100`, `amostra_pequena`. **`gold/deriva_ml32`** - por título e `ano_avaliacao` (1996-2023): `n_notas`, `nota_media`, `nota_media_filme`, `desvio_do_ano`. Mesma plataforma, mesma escala, só o tempo varia. **`gold/notas_por_faixa_etaria`** - ml-1m por título e faixa: `nota_media`, `nota_media_filme`, `desvio_no_filme` = média de (nota - média do filme entre todos). **`gold/gradiente_idade`** - o resumo por faixa: `nota_media_bruta` contra `desvio_no_filme`, e por gênero.

Também em `gold/`: `cobertura_ponte*` (os elos frame -> slug -> dump -> notas), `cobertura_decada_faixa`, `cobertura_top200_decada`, `cobertura_tmdb`, `paises_tmdb_top20`, `classificacao_br`, `classificacao_br_decada`, `arbitragem_tmdb`.

## O que não fazer

1. **Não compare média com média entre plataformas.** Escalas e distribuições são diferentes, e a média muda com o recorte: no IMDb ela vai de 5,75 (100-1k votos) a 6,99 (100k+) só mudando a faixa. Use `nota_z` ou `nota_pct` dentro da plataforma, ou `gap_z` de `divergencia_par`. Isso é pré-requisito, não refinamento.
2. **O Letterboxd é uma amostra de 11.061 usuários pesados** (~1.640 notas cada, dump do Kaggle), não o público da plataforma. As médias são desses usuários.
3. **As fontes são de datas diferentes.** IMDb e TMDB: 13/09/2026. Letterboxd: 10/10/2023. ml-32m: 13/10/2023. ml-1m: janela 2000-2003. Acumulado (todo mundo que já votou) não se compara com janela (uma coorte num intervalo): o acumulado contém a janela. Deriva temporal limpa só com `deriva_ml32`.
4. **Cobertura do Letterboxd é resultado, não defeito.** Filme sem nota lá (ou com poucas) não é dado faltante: é sinal de não-canonicidade. O cânone de toda década está inteiro (98-100% no quartil superior); o que falta é o não-cânone das décadas recentes.
5. **O corte de 5.000 votos seleciona coisas diferentes em cada década.** Nos anos 1930 sobra a elite (198 filmes), nos 2010 sobra todo lançamento mediano (5.690). Comparação entre décadas vai dentro de faixa de `pct_votos_decada`, nunca com o frame inteiro.
6. **País: use `pais_unico`.** A ordem de `production_countries` não significa nada, e idioma não é nacionalidade. Coprodução é categoria própria; `tem_us` separa "GB sozinho" de "GB com os EUA". Estratos limpos com 100+ filmes: US 7.984, IN 1.236, GB 670, JP 412, FR 400, TR 247, CA 179, KR 174, IT 163, DE 150, ES 136, AU 114.
7. **A demografia cobre 2.717 títulos** (15% do frame), os que estavam no MovieLens em 2000. É limitação a declarar.

## Perguntas sugeridas (a pergunta já com o controle dentro)

- O `gap_z` entre IMDb e Letterboxd cresce com a década, **dentro de quartil de `pct_votos_decada`**? E o sinal: o Letterboxd puxa pra cima o cânone antigo e pra baixo o blockbuster recente?
- Qual par de plataformas mais discorda (`gap_z_dp` de `divergencia_par`), e a discordância é concentrada em gênero, país ou década?
- Filmes de país único não-EUA (IN, JP, KR, TR, FR) têm `gap_z` diferente dos EUA na mesma década e quartil? Coprodução com os EUA se comporta como EUA ou como o outro país?
- A divergência de visibilidade (`n_votos` IMDb alto, `n_votos` Letterboxd baixo) tem perfil: país, década, classificação?
- Em `deriva_ml32`, o `desvio_do_ano` de um filme lançado em ano X sobe ou desce com a distância entre avaliação e lançamento? Isso é o mesmo pra cânone (quartil alto) e não-cânone?
- O gradiente de idade, que some no desvio dentro do filme (`gradiente_idade`), reaparece em algum gênero ou década? E o efeito de gênero do usuário nas pontas (<18 e 56+ mulheres) se sustenta com n?
- `classificacao_br` (40% do frame, enviesada pra recente) explica `gap_z` entre plataformas, **controlando década**?
