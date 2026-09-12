-- reconhecimento das fontes baixadas
-- rodar com: ops/venv-gestao/bin/python ops/run_sql.py recon/recon.sql
-- os arquivos extraídos ficam em datalake/, os parquets de saída em recon/

-- views sobre os arquivos
-- imdb precisa de quote='' porque os títulos têm aspas não escapadas
-- e nullstr='\N' porque é assim que o imdb marca nulo

create or replace view basics as
select * from read_csv('datalake/title.basics.tsv', delim='\t', header=true, quote='', nullstr='\N');

create or replace view ratings as
select * from read_csv('datalake/title.ratings.tsv', delim='\t', header=true, quote='', nullstr='\N');

create or replace view akas as
select * from read_csv('datalake/title.akas.tsv', delim='\t', header=true, quote='', nullstr='\N');

create or replace view links as
select * from read_csv('datalake/ml-32m/links.csv', header=true);

create or replace view ml32 as
select * from read_csv('datalake/ml-32m/ratings.csv', header=true);

create or replace view bo as
select * from read_csv('datalake/revenues_per_day.csv', header=true);

-- letterboxd: o film_id pode ser a string literal 'null' (filme chamado "(NULL)")
-- nullstr='' garante que só a string vazia vira nulo e o 'null' textual sobrevive
create or replace view lb_films as
select * from read_csv('datalake/letterboxd-film-ratings/films.csv', header=true, nullstr='');

create or replace view lb_ratings as
select * from read_csv('datalake/letterboxd-film-ratings/ratings.csv', header=true, nullstr='');

-- ml-1m: .dat com separador '::', latin-1, sem cabeçalho
create or replace view ml1_users as
select * from read_csv('datalake/ml-1m/users.dat', delim='::', header=false, encoding='latin-1',
  columns={'user_id': 'int', 'gender': 'varchar', 'age': 'int', 'occupation': 'int', 'zip': 'varchar'});

create or replace view ml1_ratings as
select * from read_csv('datalake/ml-1m/ratings.dat', delim='::', header=false,
  columns={'user_id': 'int', 'movie_id': 'int', 'rating': 'int', 'ts': 'bigint'});

create or replace view ml1_movies as
select * from read_csv('datalake/ml-1m/movies.dat', delim='::', header=false, encoding='latin-1', quote='',
  columns={'movie_id': 'int', 'title': 'varchar', 'genres': 'varchar'});

-- frame do imdb: só filme, com nota. materializado porque quase toda query abaixo usa
create temp table movies as
select b.*, r.averageRating, r.numVotes
from basics b
join ratings r using (tconst)
where b.titleType = 'movie';

-- 1. estrutura de cada fonte
select '--- basics ---' as x;
describe select * from basics;
select '--- ratings ---' as x;
describe select * from ratings;
select '--- akas ---' as x;
describe select * from akas;
select '--- links ---' as x;
describe select * from links;
select '--- box office ---' as x;
describe select * from bo;
select '--- letterboxd films ---' as x;
describe select * from lb_films;
select '--- letterboxd ratings ---' as x;
describe select * from lb_ratings;
select '--- ml-1m users ---' as x;
describe select * from ml1_users;

-- 2. volume
select 'basics' as fonte, count(*) as linhas from basics
union all select 'ratings', count(*) from ratings
union all select 'akas', count(*) from akas
union all select 'links', count(*) from links
union all select 'ml32_ratings', count(*) from ml32
union all select 'box_office', count(*) from bo
union all select 'lb_films', count(*) from lb_films
union all select 'lb_ratings', count(*) from lb_ratings
union all select 'ml1_users', count(*) from ml1_users
union all select 'ml1_ratings', count(*) from ml1_ratings
union all select 'ml1_movies', count(*) from ml1_movies;

-- 3. que tipos de título existem (quanto do imdb é filme de verdade)
select titleType, count(*) as n
from basics
group by 1
order by 2 desc;

-- 4. calibração do corte de votos: quantos filmes sobram em cada faixa
-- essa é a query que define o escopo do projeto
-- acumulado = quantos filmes ficam se o corte for o piso da faixa
create temp table q4_faixas_votos as
with por_faixa as (
  select
    case
      when numVotes >= 100000 then 'a. 100k+'
      when numVotes >= 25000 then 'b. 25k-100k'
      when numVotes >= 5000 then 'c. 5k-25k'
      when numVotes >= 1000 then 'd. 1k-5k'
      when numVotes >= 100 then 'e. 100-1k'
      else 'f. <100'
    end as faixa,
    count(*) as filmes,
    round(avg(averageRating), 2) as nota_media,
    round(stddev(averageRating), 2) as nota_dp
  from movies
  group by 1
)
select faixa, filmes, sum(filmes) over (order by faixa) as acumulado, nota_media, nota_dp
from por_faixa
order by faixa;
select * from q4_faixas_votos;
copy q4_faixas_votos to 'recon/q4_faixas_votos.parquet' (format parquet);

-- 5. tem material em toda década? (corte provisório de 1000 votos)
-- atenção: no duckdb '/' entre inteiros dá double, a divisão inteira é '//'
create temp table q5_decadas as
select
  (startYear // 10) * 10 as decada,
  count(*) as filmes,
  round(avg(averageRating), 2) as nota_media,
  round(avg(numVotes)) as votos_medio,
  median(numVotes) as votos_mediana
from movies
where numVotes >= 1000
  and startYear is not null
  and startYear >= 1920
group by 1
order by 1;
select * from q5_decadas;
copy q5_decadas to 'recon/q5_decadas.parquet' (format parquet);

-- 5b. a mesma coisa pra cada corte candidato, pra ver o trade-off numa tabela só
create temp table q5_decadas_por_corte as
select
  (startYear // 10) * 10 as decada,
  count(*) filter (where numVotes >= 100) as v100,
  count(*) filter (where numVotes >= 1000) as v1k,
  count(*) filter (where numVotes >= 5000) as v5k,
  count(*) filter (where numVotes >= 25000) as v25k,
  count(*) filter (where numVotes >= 100000) as v100k
from movies
where startYear is not null
  and startYear >= 1900
group by 1
order by 1;
select * from q5_decadas_por_corte;
copy q5_decadas_por_corte to 'recon/q5_decadas_por_corte.parquet' (format parquet);

-- 5c. quantos filmes do frame não têm ano (não entram em estratificação temporal)
select
  count(*) filter (where startYear is null) as sem_ano,
  count(*) filter (where startYear < 1920) as antes_1920,
  count(*) filter (where startYear > 2026) as futuro,
  count(*) as total
from movies
where numVotes >= 1000;

-- 7. cobertura do movielens sobre o frame do imdb
-- links.csv guarda o imdbId como string zero-padded de 7 dígitos (ou 8 sem padding)
-- o cast + printf('tt%07d') cobre os dois casos e também o pandas lendo como inteiro
create temp table links_tt as
select movieId, imdbId, tmdbId, printf('tt%07d', imdbId::bigint) as tconst
from links;

-- sanidade: imdbId repetido duplicaria linha do frame no left join
select
  count(*) as linhas,
  count(distinct tconst) as tconst_distintos,
  count(imdbId) as com_imdb,
  count(tmdbId) as com_tmdb
from links_tt;

-- dedup por tconst (max ignora nulo, então fica o tmdbId preenchido se algum houver)
create temp table links_dedup as
select tconst, max(tmdbId) as tmdbId, count(*) as n_movieid
from links_tt
group by tconst;

create temp table q7_cobertura_ml as
select
  count(*) as filmes_no_frame,
  count(l.tconst) as no_movielens,
  count(l.tmdbId) as com_tmdb_id,
  round(100.0 * count(l.tconst) / count(*), 1) as pct_no_movielens,
  round(100.0 * count(l.tmdbId) / count(*), 1) as pct_com_tmdb
from movies m
left join links_dedup l using (tconst)
where m.numVotes >= 1000;
select * from q7_cobertura_ml;
copy q7_cobertura_ml to 'recon/q7_cobertura_ml.parquet' (format parquet);

-- 7b. cobertura por faixa de votos: a resolução grátis cai conforme o corte desce
create temp table q7_cobertura_ml_por_faixa as
select
  case
    when numVotes >= 100000 then 'a. 100k+'
    when numVotes >= 25000 then 'b. 25k-100k'
    when numVotes >= 5000 then 'c. 5k-25k'
    when numVotes >= 1000 then 'd. 1k-5k'
    when numVotes >= 100 then 'e. 100-1k'
    else 'f. <100'
  end as faixa,
  count(*) as filmes,
  count(l.tconst) as no_movielens,
  count(l.tmdbId) as com_tmdb_id,
  round(100.0 * count(l.tmdbId) / count(*), 1) as pct_com_tmdb,
  count(*) - count(l.tmdbId) as precisa_find
from movies m
left join links_dedup l using (tconst)
group by 1
order by 1;
select * from q7_cobertura_ml_por_faixa;
copy q7_cobertura_ml_por_faixa to 'recon/q7_cobertura_ml_por_faixa.parquet' (format parquet);

-- 7c. e o inverso: o que do movielens não é 'movie' no imdb (tvMovie, video, etc)
select coalesce(b.titleType, '(não está no basics)') as titleType, count(*) as n
from links_tt l
left join basics b on b.tconst = l.tconst
group by 1
order by 2 desc;

-- 8. letterboxd: tem id externo? (não tem - só slug, nome, ano e poster)
-- o film_id é o slug da url letterboxd.com/film/<film_id>/, que é o que o wikidata guarda em P6127
select
  count(*) as filmes,
  count(distinct film_id) as film_id_distintos,
  count(*) filter (where film_id = 'null') as film_id_literal_null,
  count(*) filter (where film_id is null) as film_id_nulo_real,
  count(*) filter (where year is null) as sem_ano,
  min(year) as ano_min,
  max(year) as ano_max
from lb_films;

create temp table q8_lb_ratings as
select
  count(*) as notas,
  count(distinct user_name) as usuarios,
  count(distinct film_id) as filmes_avaliados,
  count(*) filter (where rating is null) as nota_nula,
  min(rating) as nota_min,
  max(rating) as nota_max,
  round(avg(rating), 3) as nota_media,
  count(*) filter (where film_id not in (select film_id from lb_films)) as film_id_orfao
from lb_ratings;
select * from q8_lb_ratings;
copy q8_lb_ratings to 'recon/q8_lb_ratings.parquet' (format parquet);

-- distribuição das notas (meia estrela de 0.5 a 5)
select rating, count(*) as n, round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from lb_ratings
group by 1
order by 1;

-- quantas notas por filme: quantos filmes do letterboxd têm volume pra sustentar uma média
create temp table q8_lb_filmes_por_volume as
with por_filme as (
  select film_id, count(*) as n from lb_ratings group by 1
)
select
  case
    when n >= 1000 then 'a. 1000+'
    when n >= 100 then 'b. 100-1000'
    when n >= 30 then 'c. 30-100'
    when n >= 10 then 'd. 10-30'
    else 'e. <10'
  end as faixa,
  count(*) as filmes,
  sum(n) as notas
from por_filme
group by 1
order by 1;
select * from q8_lb_filmes_por_volume;
copy q8_lb_filmes_por_volume to 'recon/q8_lb_filmes_por_volume.parquet' (format parquet);

-- 9. demografia do ml-1m
-- faixas: 1 = <18, 18 = 18-24, 25 = 25-34, 35 = 35-44, 45 = 45-49, 50 = 50-55, 56 = 56+
create temp table q9_ml1_demografia as
select
  u.age,
  case u.age
    when 1 then '<18' when 18 then '18-24' when 25 then '25-34' when 35 then '35-44'
    when 45 then '45-49' when 50 then '50-55' when 56 then '56+'
  end as faixa,
  count(distinct u.user_id) as usuarios,
  round(100.0 * count(distinct u.user_id) / sum(count(distinct u.user_id)) over (), 1) as pct_usuarios,
  count(distinct u.user_id) filter (where u.gender = 'F') as mulheres,
  count(r.rating) as notas,
  round(avg(r.rating), 3) as nota_media
from ml1_users u
left join ml1_ratings r using (user_id)
group by 1, 2
order by 1;
select * from q9_ml1_demografia;
copy q9_ml1_demografia to 'recon/q9_ml1_demografia.parquet' (format parquet);

-- 9b. quando foram dadas as notas do ml-1m (a tese depende da distância temporal pro imdb de hoje)
select
  year(to_timestamp(ts)) as ano,
  count(*) as notas,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from ml1_ratings
group by 1
order by 1;

-- 9c. quantos dos 3883 filmes do ml-1m chegam ao imdb via ml-32m (mesmo movieId nas duas versões)
select
  count(*) as filmes_ml1,
  count(l.tconst) as com_tconst,
  count(m.tconst) as no_frame_1k
from ml1_movies mv
left join (select movieId as movie_id, tconst from links_tt) l using (movie_id)
left join movies m on m.tconst = l.tconst and m.numVotes >= 1000;

-- 9d. o movieId do ml-1m é o mesmo do ml-32m? confere batendo título
create or replace view ml32_movies as
select * from read_csv('datalake/ml-32m/movies.csv', header=true);
select
  count(*) as filmes_ml1,
  count(m32.movieId) as achados_no_ml32,
  count(*) filter (where m1.title = m32.title) as titulo_igual,
  count(*) filter (where m1.title != m32.title) as titulo_diferente
from ml1_movies m1
left join ml32_movies m32 on m32.movieId = m1.movie_id;

-- exemplos de título diferente, pra ver se é só grafia ou se é outro filme
select m1.movie_id, m1.title as ml1, m32.title as ml32
from ml1_movies m1
join ml32_movies m32 on m32.movieId = m1.movie_id
where m1.title != m32.title
limit 12;

-- 6. de onde vêm os filmes (proxy de país via região do título)
-- serve pra ver se dá pra estratificar por nacionalidade
-- o akas tem 59M linhas, então filtro pro frame de 1k votos antes de qualquer coisa
create temp table akas_frame as
select a.*
from akas a
join movies m on m.tconst = a.titleId
where m.numVotes >= 1000;

create temp table q6_regioes as
select region, count(distinct titleId) as filmes,
  round(100.0 * count(distinct titleId) / (select count(*) from movies where numVotes >= 1000), 1) as pct_do_frame
from akas_frame
group by 1
order by 2 desc
limit 25;
select * from q6_regioes;
copy q6_regioes to 'recon/q6_regioes.parquet' (format parquet);

-- 6b. o viés: quantas regiões cada filme tem? quantos têm entrada US?
with por_filme as (
  select titleId,
    count(distinct region) as n_regioes,
    bool_or(region = 'US') as tem_us,
    bool_or(isOriginalTitle = 1) as tem_original
  from akas_frame
  group by 1
)
select
  count(*) as filmes,
  round(avg(n_regioes), 1) as regioes_media,
  median(n_regioes) as regioes_mediana,
  count(*) filter (where n_regioes = 1) as com_1_regiao,
  count(*) filter (where n_regioes <= 3) as ate_3_regioes,
  round(100.0 * count(*) filter (where tem_us) / count(*), 1) as pct_com_us,
  round(100.0 * count(*) filter (where tem_original) / count(*), 1) as pct_com_linha_original
from por_filme;

-- 6c. a linha isOriginalTitle=1 tem região? (se tivesse, era o proxy perfeito)
select
  count(*) as linhas_originais,
  count(region) as com_regiao,
  count(language) as com_idioma
from akas_frame
where isOriginalTitle = 1;

-- 6d. proxy alternativo: regiões cujo aka é igual ao originalTitle do basics
-- a ideia é que o título original só circula intacto nos países de origem (e nos de mesma língua)
create temp table q6_proxy_original as
with candidatas as (
  select a.titleId, a.region
  from akas_frame a
  join movies m on m.tconst = a.titleId
  where a.region is not null
    and lower(a.title) = lower(m.originalTitle)
  group by 1, 2
),
por_filme as (
  select titleId, count(*) as n_regioes, min(region) as regiao_unica
  from candidatas
  group by 1
)
select
  case when n_regioes = 1 then regiao_unica else '(ambíguo: ' || n_regioes || ' regiões)' end as pais_proxy,
  count(*) as filmes
from por_filme
group by 1
order by 2 desc
limit 30;
select * from q6_proxy_original;
copy q6_proxy_original to 'recon/q6_proxy_original.parquet' (format parquet);

-- 6e. spot check do proxy em filmes de país conhecido
with candidatas as (
  select a.titleId, a.region
  from akas_frame a
  join movies m on m.tconst = a.titleId
  where a.region is not null
    and lower(a.title) = lower(m.originalTitle)
  group by 1, 2
),
por_filme as (
  select titleId, string_agg(region, ',' order by region) as regioes, count(*) as n
  from candidatas
  group by 1
)
select m.tconst, m.primaryTitle, m.startYear, p.n, p.regioes
from movies m
left join por_filme p on p.titleId = m.tconst
where m.tconst in (
  'tt0211915',  -- amélie, fr
  'tt0468569',  -- dark knight, us
  'tt6751668',  -- parasita, kr
  'tt0317248',  -- cidade de deus, br
  'tt0118799',  -- la vita è bella, it
  'tt0405094',  -- das leben der anderen, de
  'tt0245712',  -- amores perros, mx
  'tt1187043',  -- 3 idiots, in
  'tt0347149',  -- howl's moving castle, jp
  'tt0091251',  -- come and see, su
  'tt0993846',  -- wolf of wall street, us
  'tt0057012',  -- dr. strangelove, gb/us
  'tt2278388',  -- grand budapest hotel, us/de
  'tt0140888'   -- central do brasil, br
)
order by m.startYear;

-- 10. estimativa do tamanho da interseção imdb x letterboxd
-- NÃO é o join (esse vai pelo wikidata P6127). é só título+ano exato pra dimensionar o corte.
-- é um piso: título diferente (grafia, artigo, tradução) e ano deslocado escapam.
create temp table lb_volume as
select f.film_id, f.film_name, f.year, count(r.rating) as n_lb, round(avg(r.rating), 3) as media_lb
from lb_films f
left join lb_ratings r using (film_id)
group by 1, 2, 3;

create temp table lb_match as
select m.tconst, m.numVotes, m.startYear, lb.film_id, lb.n_lb
from movies m
join lb_volume lb
  on lower(lb.film_name) = lower(m.primaryTitle)
  and lb.year = m.startYear
qualify row_number() over (partition by m.tconst order by lb.n_lb desc) = 1;

create temp table q10_intersecao_estimada as
select
  case
    when m.numVotes >= 100000 then 'a. 100k+'
    when m.numVotes >= 25000 then 'b. 25k-100k'
    when m.numVotes >= 5000 then 'c. 5k-25k'
    when m.numVotes >= 1000 then 'd. 1k-5k'
    when m.numVotes >= 100 then 'e. 100-1k'
    else 'f. <100'
  end as faixa,
  count(*) as filmes_imdb,
  count(x.film_id) as casou_titulo_ano,
  round(100.0 * count(x.film_id) / count(*), 1) as pct_casou,
  count(*) filter (where x.n_lb >= 30) as lb_30_notas,
  count(*) filter (where x.n_lb >= 100) as lb_100_notas,
  count(*) filter (where x.n_lb >= 1000) as lb_1000_notas,
  round(100.0 * count(*) filter (where x.n_lb >= 100) / count(*), 1) as pct_lb_100
from movies m
left join lb_match x using (tconst)
group by 1
order by 1;
select * from q10_intersecao_estimada;
copy q10_intersecao_estimada to 'recon/q10_intersecao_estimada.parquet' (format parquet);

-- 10b. e por década, com corte 1k no imdb e 100 notas no letterboxd
select
  (m.startYear // 10) * 10 as decada,
  count(*) as imdb_1k,
  count(*) filter (where x.n_lb >= 100) as lb_100_notas,
  round(100.0 * count(*) filter (where x.n_lb >= 100) / count(*), 1) as pct
from movies m
left join lb_match x using (tconst)
where m.numVotes >= 1000 and m.startYear >= 1920
group by 1
order by 1;

-- 11. miudezas pro relatório
-- adulto no frame (pra decidir se filtra isAdult = 0)
select numVotes >= 5000 as corte_5k, count(*) filter (where isAdult = 1) as adultos, count(*) as filmes
from movies where numVotes >= 1000 group by 1 order by 1 desc;

-- letterboxd: filmes por ano na ponta (o dataset é de out/2023, o que tem depois é placeholder)
select year, count(*) as filmes, sum(n_lb) as notas
from lb_volume where year >= 2021 group by 1 order by 1;

-- box office: o que é, período, quantos títulos
select min(date) as de, max(date) as ate, count(distinct id) as ids, count(distinct title) as titulos, sum(revenue) as receita_total
from bo;
select * from bo order by revenue desc limit 3;
