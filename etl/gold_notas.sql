-- silver -> gold: o que o notebook da e1 consome, sem reprocessar as linhas cruas
-- rodar depois do etl/silver_notas.sql: ops/venv-gestao/bin/python ops/run_sql.py etl/gold_notas.sql
-- z-score e percentil são derivados e mudam com o recorte: por isso moram aqui e não no silver

create view fato as select * from 'datalake/silver/fato_notas.parquet';
create view dim as select * from 'datalake/silver/dim_titulo.parquet';
create view demo as select * from 'datalake/silver/fato_notas_demografia.parquet';
create view ml32_por_ano as select * from 'datalake/bronze/ml32_por_ano.parquet';
create view links as select * from 'datalake/bronze/movielens_links.parquet';
create view ml1_ratings as select * from 'datalake/bronze/ml1_ratings.parquet';
create view ml1_users as select * from 'datalake/bronze/ml1_users.parquet';

-- 1. notas_normalizadas: posição de cada título dentro da distribuição da própria plataforma
-- população: linhas com n_votos >= 30 (média com menos que isso é ruído); o z usa média e desvio dessa população
create table notas_normalizadas as
select
  *,
  (nota - avg(nota) over w) / stddev_samp(nota) over w as nota_z,
  percent_rank() over (partition by plataforma order by nota) as nota_pct
from fato
where n_votos >= 30
window w as (partition by plataforma);

select plataforma, count(*) as titulos, round(avg(nota), 3) as media, round(stddev_samp(nota), 3) as dp,
  round(min(nota_z), 2) as z_min, round(max(nota_z), 2) as z_max
from notas_normalizadas
group by 1 order by 1;
copy notas_normalizadas to 'datalake/gold/notas_normalizadas.parquet' (format parquet);

-- 2. divergencia_par: gap normalizado entre cada par de plataformas, por título
-- o z aqui é recalculado sobre os títulos que as duas plataformas do par têm em comum (n_votos >= 30 nas duas),
-- senão a diferença de cobertura entra no gap. gap_z = z_b - z_a: positivo é b avaliando relativamente melhor
create table divergencia_par as
with pares as (
  select
    a.tconst, a.plataforma as plataforma_a, b.plataforma as plataforma_b,
    a.nota as nota_a, b.nota as nota_b, a.n_votos as n_votos_a, b.n_votos as n_votos_b
  from (select * from fato where n_votos >= 30) a
  join (select * from fato where n_votos >= 30) b on b.tconst = a.tconst and a.plataforma < b.plataforma
),
z as (
  select
    *,
    (nota_a - avg(nota_a) over w) / stddev_samp(nota_a) over w as z_a,
    (nota_b - avg(nota_b) over w) / stddev_samp(nota_b) over w as z_b,
    percent_rank() over (partition by plataforma_a, plataforma_b order by nota_a) as pct_a,
    percent_rank() over (partition by plataforma_a, plataforma_b order by nota_b) as pct_b
  from pares
  window w as (partition by plataforma_a, plataforma_b)
)
select *, z_b - z_a as gap_z, pct_b - pct_a as gap_pct
from z;

select plataforma_a, plataforma_b, count(*) as titulos, round(corr(z_a, z_b), 3) as correlacao,
  round(stddev_samp(gap_z), 3) as gap_z_dp, round(avg(abs(gap_z)), 3) as gap_z_abs_medio
from divergencia_par
group by 1, 2 order by 1, 2;
copy divergencia_par to 'datalake/gold/divergencia_par.parquet' (format parquet);

-- 3. deriva_ml32: nota média por filme por ano de avaliação. mesma plataforma, mesma escala, só o tempo varia
create table ml_tconst as
select printf('tt%07d', imdbId::bigint) as tconst, movieId
from links
qualify row_number() over (partition by tconst order by movieId) = 1;

create table deriva_ml32 as
select
  m.tconst,
  p.ano_avaliacao,
  p.n_notas,
  p.nota_media,
  sum(p.n_notas * p.nota_media) over (partition by m.tconst) / sum(p.n_notas) over (partition by m.tconst) as nota_media_filme,
  p.nota_media - sum(p.n_notas * p.nota_media) over (partition by m.tconst) / sum(p.n_notas) over (partition by m.tconst) as desvio_do_ano
from ml32_por_ano p
join ml_tconst m using (movieId)
join dim d using (tconst);

-- amplitude temporal real: a partir de que ano há volume por filme
select ano_avaliacao, count(*) as filmes_avaliados, sum(n_notas) as notas,
  count(*) filter (where n_notas >= 30) as filmes_com_30_notas,
  count(*) filter (where n_notas >= 100) as filmes_com_100_notas
from deriva_ml32
group by 1 order by 1;
copy deriva_ml32 to 'datalake/gold/deriva_ml32.parquet' (format parquet);

-- 4. notas_por_faixa_etaria: o ml-1m com o desvio dentro do filme
-- a média bruta sobe com a idade (3,55 -> 3,77), mas cada faixa avaliou um catálogo diferente.
-- o teste certo é (nota - média do filme entre todos os avaliadores), por faixa
create table notas_centradas as
select
  m.tconst,
  u.age as faixa_etaria_cod,
  case u.age
    when 1 then '<18' when 18 then '18-24' when 25 then '25-34' when 35 then '35-44'
    when 45 then '45-49' when 50 then '50-55' when 56 then '56+'
  end as faixa_etaria,
  u.gender as genero_usuario,
  r.rating,
  avg(r.rating) over (partition by m.tconst) as media_filme
from ml1_ratings r
join ml1_users u using (user_id)
join ml_tconst m on m.movieId = r.movie_id
join dim d on d.tconst = m.tconst;

create table notas_por_faixa_etaria as
select
  tconst, faixa_etaria_cod, faixa_etaria,
  count(*) as n_notas,
  avg(rating) as nota_media,
  any_value(media_filme) as nota_media_filme,
  avg(rating - media_filme) as desvio_no_filme
from notas_centradas
group by 1, 2, 3;
copy notas_por_faixa_etaria to 'datalake/gold/notas_por_faixa_etaria.parquet' (format parquet);

-- o teste: gradiente bruto contra gradiente dentro do filme
create table gradiente_idade as
select
  faixa_etaria_cod, faixa_etaria,
  count(*) as notas,
  count(distinct tconst) as filmes,
  round(avg(rating), 3) as nota_media_bruta,
  round(avg(rating - media_filme), 3) as desvio_no_filme,
  round(avg(rating - media_filme) filter (where genero_usuario = 'F'), 3) as desvio_mulheres,
  round(avg(rating - media_filme) filter (where genero_usuario = 'M'), 3) as desvio_homens
from notas_centradas
group by 1, 2
order by 1;
select * from gradiente_idade;
copy gradiente_idade to 'datalake/gold/gradiente_idade.parquet' (format parquet);
