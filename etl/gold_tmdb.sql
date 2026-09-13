-- silver -> gold: o que o tmdb abre que não tínhamos: país de origem e classificação indicativa
-- rodar depois do etl/silver_tmdb.sql: ops/venv-gestao/bin/python ops/run_sql.py etl/gold_tmdb.sql

create view dim_titulo as select * from 'datalake/silver/dim_titulo.parquet';
create view tmdb as select * from 'datalake/silver/tmdb_titulo.parquet';

-- 1. cobertura sobre o frame
create table cobertura_tmdb as
select
  count(*) as filmes_no_frame,
  count(t.tconst) as com_tmdb_validado,
  round(100.0 * count(t.tconst) / count(*), 1) as pct_tmdb,
  count(*) filter (where len(t.production_countries) > 0) as com_pais,
  round(100.0 * count(*) filter (where len(t.production_countries) > 0) / count(*), 1) as pct_pais,
  count(*) filter (where len(t.production_countries) = 1) as com_um_pais_so,
  count(t.certificacao_br) as com_cert_br,
  count(t.classificacao_br) as com_classificacao_br,
  round(100.0 * count(t.classificacao_br) / count(*), 1) as pct_classificacao_br,
  count(*) filter (where t.classificacao_br is not null and t.certificacao_br_tipo in (2, 3)) as classificacao_br_de_cinema,
  count(t.certificacao_us) as com_cert_us,
  round(100.0 * count(t.certificacao_us) / count(*), 1) as pct_cert_us,
  count(*) filter (where t.certificacao_br is null and t.certificacao_us is not null) as so_cert_us
from dim_titulo d
left join tmdb t using (tconst);
select * from cobertura_tmdb;
copy cobertura_tmdb to 'datalake/gold/cobertura_tmdb.parquet' (format parquet);

-- 2. países: coprodução conta em cada país (um filme com ['US', 'GB'] aparece nos dois)
create table paises_tmdb_top20 as
select
  pais,
  count(*) as filmes,
  round(100.0 * count(*) / (select count(*) from dim_titulo), 1) as pct_do_frame,
  count(*) filter (where len(t.production_countries) = 1) as como_unico_pais
from tmdb t, unnest(t.production_countries) as u(pais)
group by 1
order by 2 desc, 1
limit 20;
select * from paises_tmdb_top20;
copy paises_tmdb_top20 to 'datalake/gold/paises_tmdb_top20.parquet' (format parquet);

-- quantos países por filme: define se estratificar por nacionalidade é limpo ou se coprodução atrapalha
select len(production_countries) as n_paises, count(*) as filmes,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from tmdb group by 1 order by 1;

-- 3. classificação indicativa brasileira (normalizada no silver: L/10/12/14/16/18)
create table classificacao_br as
select
  classificacao_br as classificacao,
  count(*) as filmes,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_das_classificadas,
  count(*) filter (where certificacao_br_tipo in (2, 3)) as de_cinema
from tmdb
where classificacao_br is not null
group by 1
order by case classificacao_br when 'L' then 0 else classificacao_br::int end;
select * from classificacao_br;
copy classificacao_br to 'datalake/gold/classificacao_br.parquet' (format parquet);

-- cobertura da classificação br por década: filme velho tende a não ter
create table classificacao_br_decada as
select d.decada, count(*) as filmes, count(t.classificacao_br) as com_classificacao_br,
  round(100.0 * count(t.classificacao_br) / count(*), 1) as pct,
  count(t.certificacao_us) as com_cert_us,
  round(100.0 * count(t.certificacao_us) / count(*), 1) as pct_us
from dim_titulo d left join tmdb t using (tconst)
group by 1 order by 1;
select * from classificacao_br_decada;
copy classificacao_br_decada to 'datalake/gold/classificacao_br_decada.parquet' (format parquet);
