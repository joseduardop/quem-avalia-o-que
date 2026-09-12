-- silver -> gold: agregados prontos pra análise
-- rodar com: ops/venv-gestao/bin/python ops/run_sql.py etl/gold.sql
-- por enquanto só a cobertura da ponte: a cadeia frame -> slug -> dump -> notas, elo a elo

create view dim_titulo as select * from 'datalake/silver/dim_titulo.parquet';
create view ponte_ids as select * from 'datalake/silver/ponte_ids.parquet';
create view slug_por_tconst as select * from 'datalake/silver/slug_por_tconst.parquet';
create view ratings as select * from 'datalake/bronze/imdb_ratings.parquet';

-- uma linha por tconst do frame com cada elo como booleano
create table elos as
select
  d.tconst,
  d.decada,
  case
    when r.numVotes >= 100000 then 'a. 100k+'
    when r.numVotes >= 25000 then 'b. 25k-100k'
    else 'c. 5k-25k'
  end as faixa_votos,
  p.letterboxd_slug is not null as tem_slug,
  coalesce(s.slug_no_dump, false) as slug_no_dump,
  coalesce(s.n_notas_lb, 0) >= 1 as tem_1_nota,
  coalesce(s.n_notas_lb, 0) >= 30 as tem_30_notas,
  coalesce(s.n_notas_lb, 0) >= 100 as tem_100_notas,
  coalesce(s.n_notas_lb, 0) as n_notas_lb
from dim_titulo d
join ratings r using (tconst)
left join ponte_ids p using (tconst)
left join slug_por_tconst s using (tconst);

-- macro à mão: a mesma agregação com e sem quebra
create table cobertura_ponte as
select
  'total' as recorte,
  count(*) as no_frame,
  count(*) filter (where tem_slug) as tem_slug,
  count(*) filter (where slug_no_dump) as slug_no_dump,
  count(*) filter (where tem_1_nota) as tem_1_nota,
  count(*) filter (where tem_30_notas) as tem_30_notas,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_slug) / count(*), 1) as pct_slug,
  round(100.0 * count(*) filter (where slug_no_dump) / count(*), 1) as pct_dump,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100
from elos;
select * from cobertura_ponte;
copy cobertura_ponte to 'datalake/gold/cobertura_ponte.parquet' (format parquet);

create table cobertura_ponte_decada as
select
  decada,
  count(*) as no_frame,
  count(*) filter (where tem_slug) as tem_slug,
  count(*) filter (where slug_no_dump) as slug_no_dump,
  count(*) filter (where tem_1_nota) as tem_1_nota,
  count(*) filter (where tem_30_notas) as tem_30_notas,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_slug) / count(*), 1) as pct_slug,
  round(100.0 * count(*) filter (where slug_no_dump) / count(*), 1) as pct_dump,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100
from elos
group by 1 order by 1;
select * from cobertura_ponte_decada;
copy cobertura_ponte_decada to 'datalake/gold/cobertura_ponte_decada.parquet' (format parquet);

create table cobertura_ponte_faixa as
select
  faixa_votos,
  count(*) as no_frame,
  count(*) filter (where tem_slug) as tem_slug,
  count(*) filter (where slug_no_dump) as slug_no_dump,
  count(*) filter (where tem_1_nota) as tem_1_nota,
  count(*) filter (where tem_30_notas) as tem_30_notas,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_slug) / count(*), 1) as pct_slug,
  round(100.0 * count(*) filter (where slug_no_dump) / count(*), 1) as pct_dump,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100
from elos
group by 1 order by 1;
select * from cobertura_ponte_faixa;
copy cobertura_ponte_faixa to 'datalake/gold/cobertura_ponte_faixa.parquet' (format parquet);

-- onde se perde: os que têm slug mas o slug não está no dump (são os candidatos ao segundo passe)
select d.tconst, d.titulo, d.ano, r.numVotes, p.letterboxd_slug
from elos e
join dim_titulo d using (tconst)
join ratings r using (tconst)
join ponte_ids p using (tconst)
where e.tem_slug and not e.slug_no_dump
order by r.numVotes desc
limit 15;

-- e os sem slug nenhum
select d.tconst, d.titulo, d.ano, r.numVotes
from elos e
join dim_titulo d using (tconst)
join ratings r using (tconst)
where not e.tem_slug
order by r.numVotes desc
limit 15;

-- comparação com a estimativa por título+ano do recon (piso de 56-92% por faixa)
select faixa_votos, count(*) as no_frame,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100_wikidata
from elos group by 1 order by 1;
