# Teste de confundimento e crawl do TMDB - relatório

Sessão 3. Continuação de `recon/relatorio.md` e `docs/ponte-wikidata.md`.

## Estado

- **Tarefa A concluída.** Cross-tab, `pct_votos_decada`, top 200 e, além do briefing, década x quartil - que é a tabela que decide o veredito.
- **Tarefa B concluída.** Crawl rodado em 13/09/2026 (17.858 requisições, 15,3 min, 559 MB), identidade validada em todo o frame, 19 divergências arbitradas, bronze/silver/gold do TMDB no lugar. Log em `ops/tmdb.log`.
- Uma primeira versão do código foi revisada e corrigida antes de rodar: sobrescrita silenciosa de lote no crawler, join errado que ficava invisível na ponte, arbitragem que sumia ao rerodar o silver, memória do crawler. Detalhes na seção B.

## tl;dr do TMDB

- **17.805 dos 17.810 filmes do frame (99,97%) têm registro validado do TMDB** - `external_ids.imdb_id` igual ao tconst. 2 sem candidata válida, 3 sem id nenhum.
- **Nas 19 divergências MovieLens x Wikidata, o Wikidata estava certo em 18 e o MovieLens em zero.** 15 dos ids do MovieLens eram entradas que o TMDB já apagou (404). A regra da sessão 2 ("MovieLens prevalece") estava errada em todos os casos; a validação corrigiu.
- **País de origem: 99,6% do frame**, 71% com país único. É o eixo de nacionalidade que faltava. A ordem da lista nas coproduções não é confiável.
- **Classificação indicativa BR: 39,6% do frame**, viés forte de recência (25% nos anos 1930, 54% nos 2020). A americana cobre 75%. Eixo utilizável, mas mais fraco que o de nacionalidade.

## A.1 - década x faixa de votos

Cada célula mostra `% com 30+ notas / % com 100+ notas (n)`. O marcador `*` indica menos de 30 filmes: a célula fica registrada, mas não deve ser interpretada.

| década | 100k+ | 25k-100k | 5k-25k |
|---|---:|---:|---:|
| 1930 | 100,0 / 100,0 (8)* | 96,0 / 96,0 (25)* | 100,0 / 99,4 (165) |
| 1940 | 100,0 / 100,0 (17)* | 100,0 / 100,0 (45) | 99,6 / 97,3 (258) |
| 1950 | 100,0 / 100,0 (34) | 98,6 / 98,6 (71) | 98,3 / 92,1 (355) |
| 1960 | 100,0 / 100,0 (41) | 99,1 / 99,1 (109) | 98,1 / 85,8 (486) |
| 1970 | 100,0 / 100,0 (63) | 98,3 / 97,8 (179) | 93,9 / 85,8 (618) |
| 1980 | 100,0 / 100,0 (163) | 99,7 / 99,7 (345) | 94,7 / 83,9 (901) |
| 1990 | 99,7 / 99,7 (356) | 99,5 / 98,3 (597) | 92,8 / 70,1 (1.222) |
| 2000 | 100,0 / 100,0 (783) | 98,8 / 95,9 (1.015) | 85,1 / 45,4 (2.033) |
| 2010 | 99,7 / 99,7 (931) | 98,3 / 93,3 (1.307) | 86,7 / 55,4 (3.452) |
| 2020 | 93,2 / 90,3 (236) | 90,0 / 78,4 (522) | 75,3 / 53,0 (1.473) |

Dentro da faixa 5k-25k o gradiente sobrevive: 99,4% nos anos 1930, 53,0% nos 2020. Pelo critério do briefing, existe efeito de década - o gradiente marginal não é composição de faixa de votos. Mas a faixa é larga e a pergunta certa é a da A.2: o que sobra quando se casa a posição do filme dentro da própria década?

`datalake/gold/cobertura_decada_faixa.parquet`, com `amostra_pequena` explícito.

## A.2 - percentil dentro da década, top 200 e quartis

`datalake/silver/dim_titulo.parquet` ganhou `pct_votos_decada` (`percent_rank()` dentro da década: 0 é o menos votado do frame naquela década, 1 o mais votado). Convive com o corte absoluto, não o substitui.

Curva do corte absoluto contra os 200 mais votados de cada década:

| década | n absoluto | n top | 30+ absoluto | 100+ absoluto | 30+ top 200 | 100+ top 200 |
|---|---:|---:|---:|---:|---:|---:|
| 1930 | 198 | 198 | 99,5 | 99,0 | 99,5 | 99,0 |
| 1940 | 320 | 200 | 99,7 | 97,8 | 100,0 | 100,0 |
| 1950 | 460 | 200 | 98,5 | 93,7 | 99,5 | 99,5 |
| 1960 | 636 | 200 | 98,4 | 89,0 | 99,5 | 99,5 |
| 1970 | 860 | 200 | 95,2 | 89,3 | 99,0 | 98,5 |
| 1980 | 1.409 | 200 | 96,5 | 89,6 | 100,0 | 100,0 |
| 1990 | 2.175 | 200 | 95,8 | 82,7 | 100,0 | 100,0 |
| 2000 | 3.831 | 200 | 91,8 | 69,9 | 100,0 | 100,0 |
| 2010 | 5.690 | 200 | 91,5 | 71,4 | 99,5 | 99,5 |
| 2020 | 2.231 | 200 | 80,6 | 62,8 | 92,5 | 89,0 |

As formas são diferentes, mas o top 200 **não casa selecionabilidade**: nos anos 1930 é o frame inteiro (piso de 5.025 votos), nos 2010 é quem tem 421.269+ votos, 3,5% da década. É comparar tudo dos anos 30 com os blockbusters dos anos 10. O que a tabela mostra é só que o topo de cada década está inteiro no Letterboxd.

O casamento de verdade é década x quartil de `pct_votos_decada` (% com 100+ notas):

| década | Q4 (top 25%) | Q3 | Q2 | Q1 (base 25%) |
|---|---:|---:|---:|---:|
| 1930 | 98,0 | 100,0 | 100,0 | 98,0 |
| 1940 | 100,0 | 100,0 | 97,5 | 93,8 |
| 1950 | 99,1 | 100,0 | 93,9 | 81,7 |
| 1960 | 99,4 | 94,3 | 83,0 | 79,2 |
| 1970 | 98,6 | 90,7 | 83,6 | 84,3 |
| 1980 | 100,0 | 97,7 | 88,9 | 71,9 |
| 1990 | 99,4 | 97,1 | 84,9 | 49,4 |
| 2000 | 99,9 | 93,5 | 59,6 | 26,6 |
| 2010 | 99,0 | 86,1 | 60,5 | 39,8 |
| 2020 | 85,8 | 70,6 | 51,9 | 43,0 |

Quartis dos anos 1930 têm ~50 filmes cada; nenhuma célula abaixo de 30.

**Veredito.** O gradiente por década é real e não é composição de votos: o Q1 dos anos 1930 e o Q1 dos anos 2000 têm votos parecidos (5-8k) e o mesmo percentil dentro da década, e ainda assim 98% contra 27%. O mecanismo é sobrevivência. Um filme de 1935 que ainda tem 6 mil votos no IMDb é cânone, e o cânone de toda década está inteiro no Letterboxd - o Q4 é plano em 98-100% de 1930 a 2010. O que cai é a cobertura do não-cânone, que só existe no frame nas décadas recentes, porque o corte absoluto seleciona populações diferentes em cada época: nos anos 1930 sobra a elite, nos 2010 sobra todo lançamento mediano.

Consequências pra E1:

- comparar décadas só dentro de faixa de `pct_votos_decada`, nunca com o frame inteiro, e dizer isso no texto;
- os anos 2020 têm um efeito extra: o dump do Letterboxd é de outubro de 2023, então até o Q4 cai (85,8%);
- curiosidade que vale nota: os anos 2000 são a pior década no Q1 (26,6%), pior que os 2010. Meio-de-tabela velho demais pra ser cânone e novo demais pra nostalgia - hipótese, não achado.

`datalake/gold/cobertura_top200_decada.parquet` e `datalake/gold/cobertura_canonicidade.parquet`.

## B - crawl do TMDB

### Fluxo

```
ops/crawl_tmdb.py          landing/tmdb/*.jsonl     resposta crua, lotes de 1.000, com retomada
etl/processa_tmdb.py       bronze/tmdb_filmes       toda resposta 200, uma linha por (tconst, tmdb_id), sem regra
etl/silver_tmdb.sql        silver/ponte_ids         escolha da candidata validada, arbitragem, nao_validado
                           silver/tmdb_titulo       o registro validado do tmdb, um por tconst do frame
etl/gold_tmdb.sql          gold/*                   cobertura, países, classificação br
```

Ordem completa do pipeline daqui em diante: `bronze.sql -> silver.sql -> crawl -> processa_tmdb.py -> silver_tmdb.sql -> gold.sql -> gold_tmdb.sql`. Se `silver.sql` rodar de novo, a ponte volta ao estado pré-TMDB; basta rodar `silver_tmdb.sql` de novo - ele é idempotente e não faz requisição nenhuma.

### Como rodar

A credencial vem de https://www.themoviedb.org/settings/api (conta no TMDB, pedido de chave de desenvolvedor, aprovação automática). O crawler aceita qualquer uma das duas que a página mostra, por variável de ambiente ou num `.env` na raiz (já no `.gitignore`):

```
TMDB_READ_ACCESS_TOKEN=eyJ...      # api read access token, o comprido
TMDB_API_KEY=...                   # ou a api key v3, 32 hex
```

```bash
ops/venv-gestao/bin/python ops/crawl_tmdb.py --dry-run     # confere o plano: 17.810 no frame, 29 sem id, 19 divergências (sem rede)
ops/venv-gestao/bin/python ops/crawl_tmdb.py --checar      # uma requisição real: credencial e formato da resposta
ops/venv-gestao/bin/python ops/crawl_tmdb.py               # ~17,9k requisições, 15-20 min; pode interromper e retomar
ops/venv-gestao/bin/python etl/processa_tmdb.py
ops/venv-gestao/bin/python ops/run_sql.py etl/silver_tmdb.sql > etl/silver_tmdb.log
ops/venv-gestao/bin/python ops/run_sql.py etl/gold_tmdb.sql > etl/gold_tmdb.log
```

`ops/teste_tmdb.py` roda tudo isso com a API mockada num diretório temporário, sem tocar em `datalake/`. Rodar depois de qualquer mudança nesses arquivos.

### O que o crawler faz

- `/find/{tconst}?external_source=imdb_id` pros 29 sem id; `/movie/{id}?append_to_response=release_dates,external_ids,keywords,credits` pra todo o resto, uma chamada por filme
- limite global de 22 req/s entre 12 threads; 429 com backoff exponencial e `Retry-After`; 404 registrado e não aborta; outros erros, três tentativas e pro log
- pras 19 divergências baixa as duas candidatas (MovieLens e Wikidata)
- valida `external_ids.imdb_id` contra o tconst em todas as linhas; quem falha (id errado ou 404) ganha um `/find` de fallback e as candidatas novas também são baixadas
- resposta inteira gravada em JSONL antes de qualquer parse; retoma de onde parou lendo `.jsonl` e `.jsonl.part`; 200 e 404 já gravados não são pedidos de novo
- credencial nunca vai pro JSONL nem pro log
- pré-voo antes de qualquer lote: `/movie/550` tem que voltar 200 com `tt0137523` e as quatro seções do `append_to_response`; 401 aborta na hora

### Regras em `silver_tmdb.sql`

- candidata válida é a resposta cujo `external_ids.imdb_id` é o tconst pedido
- fica o `tmdb_id` que já estava na ponte se ele validou; senão o menor válido; se houver mais de um válido (o TMDB tem duas entradas com o mesmo `imdb_id`), fica registrado no log
- `metodo_join`: `arbitrado_tmdb` (era `divergente`), `tmdb_find` (era `nenhum`), `corrigido_tmdb` (o id da fonte estava errado e o `/find` achou o certo), **`nao_validado`** (tem id mas nenhuma candidata devolveu o tconst - o id fica, marcado, e o filme não entra em `tmdb_titulo`), `nenhum` (sem id e o `/find` não achou)
- a tabela de arbitragem recomputa a divergência das fontes (`gold/arbitragem_tmdb.parquet`), então sai igual em qualquer rodada e diz quem estava certo: MovieLens, Wikidata ou nenhuma das duas

### Bronze

`bronze/tmdb_filmes.parquet`, uma linha por resposta 200: identidade (`tmdb_id`, `imdb_id`, `title`, `original_title`, `release_date`), notas (`vote_average`, `vote_count`, `popularity`), metadado (`runtime`, `budget`, `revenue`, `original_language`, `status`), arrays (`genres`, `keywords`, `production_countries` em ISO e por nome, `production_companies`, `spoken_languages`), `diretor`/`diretores`, `elenco_principal` (5 primeiros), `certificacao_br` e `certificacao_us` com o tipo de lançamento de onde vieram.

Classificação: cinema (type 3) primeiro, depois cinema limitado (2), depois qualquer lançamento com certificação (digital, físico, TV). No Brasil muita entrada do TMDB só tem a classificação no lançamento digital; `certificacao_br_tipo` diz de onde veio, então dá pra restringir a cinema depois se quiser.

### O que foi corrigido antes de rodar

1. **Lote sobrescrito.** O nome do lote era `{tipo}-{timestamp em segundos}-{índice}`; duas fases do mesmo tipo no mesmo segundo geravam o mesmo nome e o `rename` do `.part` apagava o anterior. No crawl real a segunda fase de `movie` começa logo depois de uns poucos `/find` de fallback, no mesmo segundo - o lote `00000` da fase 2 apagaria mil filmes da fase 1, sem aviso. Agora o nome tem microssegundos e é checado por existência (`ops/teste_tmdb.py` reproduzia o problema).
2. **Join errado invisível.** Filme cujo id não validava ficava na ponte com o id e o `metodo_join` antigos, como se estivesse certo. Agora é `nao_validado`.
3. **Arbitragem perdida ao rerodar.** O parser editava `ponte_ids.parquet` no lugar e `silver.sql` regenerava por cima. Agora a escolha é SQL em `silver_tmdb.sql`, reproduzível a partir do bronze.
4. **Memória.** O crawler guardava todas as respostas completas em RAM (30-70KB cada, x17,8k, em objeto Python dá alguns GB). Agora retém só status, `imdb_id` devolvido e ids do `/find`.
5. Resposta 200 sem JSON era marcada como concluída e nunca refeita; agora cai no retry. A mensagem de credencial ausente mostrava os nomes das variáveis em minúsculas.

## Resultados do crawl

### 3. Estatísticas

| fase | requisições | resultado |
|---|---|---|
| pré-voo | 1 | Fight Club, 0,62s |
| `/find` pros sem id | 29 | 26 resolvidos, 3 sem resultado |
| `/movie` | 17.826 | 17.781 da ponte + 19 candidatas do Wikidata + 26 do `/find`; 17.809 x 200, 17 x 404 |
| `/find` de fallback (identidade falhou) | 2 | nenhum resultado |
| total | 17.858 | 15,3 min, ~19 req/s, 0 falhas finais |

559 MB em 20 arquivos JSONL em `datalake/landing/tmdb/` (18 lotes de `movie`, 2 de `find`). Bronze `tmdb_filmes.parquet` com 17.809 linhas (2,8 MB), silver `tmdb_titulo.parquet` com 17.805 (4,9 MB).

### 4. Validação de identidade

17.809 respostas 200 sobre 17.806 tconst. **17.805 batem**, 4 não:

| tconst | título | fonte do id | id consultado | `imdb_id` devolvido |
|---|---|---|---|---|
| tt0056142 | King Kong vs. Godzilla | movielens | 1680 | tt13364334 |
| tt0478813 | The Trap | movielens | 71370 | tt0497457 |
| tt0859765 | Still Life | movielens | 155796 | tt1127347 |
| tt25405130 | Dada (2023) | wikidata | 965979 | tt37431562 |

Os três primeiros são divergências resolvidas pela candidata do Wikidata. O quarto é um `nao_validado`: o Wikidata aponta pra outro filme chamado Dada e o `/find` não acha nada. O outro `nao_validado` é My Best Friend's Birthday (tt0359715): as duas candidatas dão 404 e o `/find` não acha.

`metodo_join` final na ponte:

| metodo_join | filmes | % |
|---|---|---|
| ambos | 16.819 | 94,4 |
| wikidata | 903 | 5,1 |
| movielens | 39 | 0,2 |
| tmdb_find | 26 | 0,1 |
| arbitrado_tmdb | 18 | 0,1 |
| nenhum | 3 | 0,0 |
| nao_validado | 2 | 0,0 |

### 5. Arbitragem das 19 divergências

| fonte certa | casos |
|---|---|
| wikidata | 18 |
| movielens | 0 |
| nenhuma das duas | 1 |

Dos 19 ids do MovieLens, 15 devolveram 404 - entradas que o TMDB fundiu ou apagou depois que o `links.csv` foi gerado - e 3 apontavam pra outro filme. O `links.csv` do ml-32m é de 2023 e não acompanha as fusões do TMDB; o Wikidata acompanha. A suspeita da sessão 2 (Spider-Man: Homecoming, 315635) se confirmou, e o padrão vale pra todos. Tabela completa em `datalake/gold/arbitragem_tmdb.parquet`.

### 6. País de origem (`production_countries`)

17.742 filmes (99,6%) com o campo preenchido; 63 sem. Países por filme: 1 em 71,0% (12.647), 2 em 18,7%, 3 em 6,3%, 4+ em 3,6%.

| país | filmes | % do frame | como país único |
|---|---|---|---|
| US | 11.212 | 63,0 | 7.984 |
| GB | 2.596 | 14,6 | 670 |
| FR | 1.810 | 10,2 | 400 |
| IN | 1.367 | 7,7 | 1.236 |
| DE | 1.108 | 6,2 | 150 |
| CA | 884 | 5,0 | 179 |
| IT | 677 | 3,8 | 163 |
| JP | 623 | 3,5 | 412 |
| ES | 461 | 2,6 | 136 |
| BE | 336 | 1,9 | 11 |
| AU | 326 | 1,8 | 114 |
| TR | 303 | 1,7 | 247 |
| HK | 295 | 1,7 | 83 |
| CN | 260 | 1,5 | 28 |
| SE | 259 | 1,5 | 55 |
| KR | 232 | 1,3 | 174 |
| DK | 204 | 1,1 | 37 |
| IE | 198 | 1,1 | 16 |
| NL | 154 | 0,9 | 28 |
| CH | 137 | 0,8 | 4 |

Dá pra estratificar por nacionalidade, com duas ressalvas:

- **A ordem da lista não é confiável.** Nas 5.095 coproduções, 58% vêm em ordem alfabética e o resto em ordem arbitrária (Alemanha Ano Zero, de Rossellini, vem `[FR, DE, IT]`). "Primeiro da lista" não serve como país principal.
- Índia (90% como país único), Turquia (82%), Coreia (75%) e Japão (66%) são estratos limpos. GB, DE, CA, BE, IE e CH são majoritariamente coprodução, quase sempre com os EUA.

Sugestão pra sessão 4: `pais` = o único país quando há um só (71% do frame); coprodução vira estrato próprio ou usa `original_language` como desempate (`[FR, US]` com `fr` -> FR). É decisão de modelagem, não está feita.

### 7. Classificação indicativa brasileira

O TMDB devolve texto livre (`12`, `12 ANOS`, `E 12`, `E LIVRE`, `LIVRE`, e uns `PG` do sistema americano). `silver/tmdb_titulo.classificacao_br` normaliza pra L/10/12/14/16/18; 9 valores não normalizáveis viram nulo (`PG`, `A`, `15`, `PG-13`, `6`). O texto original fica em `certificacao_br`, e `certificacao_br_tipo` diz de que lançamento veio (5.150 de cinema, 1.898 de digital/físico/TV).

**7.048 filmes (39,6% do frame)** com classificação BR. Distribuição:

| classificação | filmes | % das classificadas |
|---|---|---|
| L | 966 | 13,7 |
| 10 | 410 | 5,8 |
| 12 | 1.597 | 22,7 |
| 14 | 1.948 | 27,6 |
| 16 | 1.650 | 23,4 |
| 18 | 477 | 6,8 |

Por década a cobertura vai de 25% (anos 1930) a 54% (anos 2020). A americana (`certificacao_us`) cobre 75,2% do frame e é o fallback: 6.917 filmes têm só ela. O eixo de faixa etária existe, mas é bem mais fraco que o de nacionalidade e enviesado pra filme recente - no texto da E1 isso tem que estar dito.

`datalake/gold/cobertura_tmdb.parquet`, `paises_tmdb_top20.parquet`, `classificacao_br.parquet`, `classificacao_br_decada.parquet`, `arbitragem_tmdb.parquet`.
