-- silver, terceira passada: país de origem, fato_notas e fato_notas_demografia
-- rodar depois do etl/silver_tmdb.sql: ops/venv-gestao/bin/python ops/run_sql.py etl/silver_notas.sql
-- reescreve silver/dim_titulo.parquet com n_paises, pais_unico e tem_us. idempotente: lê a lista fixa de colunas

create table dim_base as
select tconst, titulo, titulo_original, ano, decada, duracao, generos, pct_votos_decada
from 'datalake/silver/dim_titulo.parquet';
create view ponte as select * from 'datalake/silver/ponte_ids.parquet';
create view tmdb as select * from 'datalake/silver/tmdb_titulo.parquet';
create view imdb_ratings as select * from 'datalake/bronze/imdb_ratings.parquet';
create view lb_ratings as select * from 'datalake/bronze/letterboxd_ratings.parquet';
create view links as select * from 'datalake/bronze/movielens_links.parquet';
create view ml32 as select * from 'datalake/bronze/ml32_ratings.parquet';
create view ml1_ratings as select * from 'datalake/bronze/ml1_ratings.parquet';
create view ml1_users as select * from 'datalake/bronze/ml1_users.parquet';

-- 1. país de origem em formato longo: uma linha por país de cada filme
-- a ordem da lista do tmdb não significa nada (58% alfabética), então não existe "país principal"
create table titulo_pais as
select t.tconst, u.pais
from tmdb t, unnest(t.production_countries) as u(pais);

-- dim_titulo ganha n_paises, pais_unico (só quando n_paises = 1) e tem_us (gb sozinho != gb com os eua)
create table dim_titulo as
select
  d.*,
  coalesce(p.n_paises, 0) as n_paises,
  case when p.n_paises = 1 then p.pais_unico end as pais_unico,
  coalesce(p.tem_us, false) as tem_us
from dim_base d
left join (
  select tconst, count(*) as n_paises, min(pais) as pais_unico, bool_or(pais = 'US') as tem_us
  from titulo_pais
  group by 1
) p using (tconst);

select count(*) as dim_titulo, count(pais_unico) as com_pais_unico, count(*) filter (where n_paises >= 2) as coproducoes,
  count(*) filter (where n_paises = 0) as sem_pais, count(*) filter (where tem_us) as com_us
from dim_titulo;

-- massa por país como estrato limpo (pais_unico), e quantos do país aparecem só em coprodução
select
  p.pais,
  count(*) as filmes_com_o_pais,
  count(*) filter (where d.n_paises = 1) as pais_unico,
  count(*) filter (where d.n_paises >= 2 and d.tem_us and p.pais != 'US') as coproducao_com_us,
  count(*) filter (where d.n_paises >= 2 and (not d.tem_us or p.pais = 'US')) as coproducao_sem_us,
  round(100.0 * count(*) filter (where d.n_paises = 1) / count(*), 1) as pct_unico
from titulo_pais p
join dim_titulo d using (tconst)
group by 1
having count(*) filter (where d.n_paises = 1) >= 30
order by 3 desc;

-- 2. fato_notas: formato longo, uma linha por (título, plataforma). sem filtro de volume: n_votos fica pra quem analisa
-- tmdb com vote_count = 0 fica fora: nota 0,0 sem voto é ausência de medida, não medida
-- data_coleta: imdb e tmdb baixados em 2026-09-13; dump do letterboxd de 2023-10-10; ml-32m gerado em 2023-10-13
create table ml_tconst as
select printf('tt%07d', imdbId::bigint) as tconst, movieId
from links
qualify row_number() over (partition by tconst order by movieId) = 1;

create table fato_notas as
select d.tconst, 'imdb' as plataforma, r.averageRating::double as nota, 1.0 as escala_min, 10.0 as escala_max,
  r.numVotes::bigint as n_votos, date '2026-09-13' as data_coleta, 'acumulado' as tipo_medida
from dim_titulo d
join imdb_ratings r using (tconst)
union all
select t.tconst, 'tmdb', t.vote_average, 0.0, 10.0, t.vote_count, date '2026-09-13', 'acumulado'
from tmdb t
where t.vote_count > 0
union all
select p.tconst, 'letterboxd', avg(r.rating)::double, 0.5, 5.0, count(*), date '2023-10-10', 'acumulado'
from ponte p
join lb_ratings r on r.film_id = p.letterboxd_slug
group by p.tconst
union all
select m.tconst, 'ml32', avg(r.rating)::double, 0.5, 5.0, count(*), date '2023-10-13', 'acumulado'
from ml_tconst m
join dim_titulo d using (tconst)
join ml32 r using (movieId)
group by m.tconst;

select plataforma, count(*) as titulos, round(100.0 * count(*) / (select count(*) from dim_titulo), 1) as pct_do_frame,
  round(avg(nota), 3) as nota_media, round(stddev(nota), 3) as nota_dp, median(n_votos) as votos_mediana,
  count(*) filter (where n_votos < 30) as abaixo_de_30_votos
from fato_notas
group by 1
order by 1;

-- quantos títulos têm 1, 2, 3 ou 4 plataformas
select n_plataformas, count(*) as titulos
from (select tconst, count(*) as n_plataformas from fato_notas group by 1)
group by 1
order by 1;

-- 3. fato_notas_demografia: ml-1m por (título, faixa etária, gênero do usuário). janela 2000-04-25 a 2003-02-28, 90% em 2000
-- o movieId do ml-1m é o mesmo do ml-32m (conferido na sessão 1), então a ponte é o links.csv
create table fato_notas_demografia as
select
  m.tconst,
  case u.age
    when 1 then '<18' when 18 then '18-24' when 25 then '25-34' when 35 then '35-44'
    when 45 then '45-49' when 50 then '50-55' when 56 then '56+'
  end as faixa_etaria,
  u.age as faixa_etaria_cod,
  u.gender as genero_usuario,
  avg(r.rating)::double as nota_media,
  count(*) as n_notas,
  date '2003-02-28' as data_coleta,
  'janela' as tipo_medida
from ml1_ratings r
join ml1_users u using (user_id)
join ml_tconst m on m.movieId = r.movie_id
join dim_titulo d on d.tconst = m.tconst
group by all;

select count(*) as linhas, count(distinct tconst) as titulos,
  round(100.0 * count(distinct tconst) / (select count(*) from dim_titulo), 1) as pct_do_frame,
  sum(n_notas) as notas
from fato_notas_demografia;

copy dim_titulo to 'datalake/silver/dim_titulo.parquet' (format parquet);
copy titulo_pais to 'datalake/silver/titulo_pais.parquet' (format parquet);
copy fato_notas to 'datalake/silver/fato_notas.parquet' (format parquet);
copy fato_notas_demografia to 'datalake/silver/fato_notas_demografia.parquet' (format parquet);
