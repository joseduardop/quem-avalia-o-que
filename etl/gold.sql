-- silver -> gold: agregados prontos pra análise
-- rodar com: ops/venv-gestao/bin/python ops/run_sql.py etl/gold.sql
-- cobertura da ponte e teste de confundimento entre década e volume de votos

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

-- década x faixa: separa o efeito de época do efeito de volume de votos
-- amostra_pequena marca células com menos de 30 filmes, que não devem ser interpretadas
create table cobertura_decada_faixa as
select
  decada,
  faixa_votos,
  count(*) as filmes,
  count(*) < 30 as amostra_pequena,
  count(*) filter (where tem_30_notas) as tem_30_notas,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100
from elos
group by 1, 2
order by 1, 2;
select * from cobertura_decada_faixa;
copy cobertura_decada_faixa to 'datalake/gold/cobertura_decada_faixa.parquet' (format parquet);

-- compara o frame inteiro (corte absoluto) com os 200 mais votados de cada década
-- 1930 tem só 198 filmes no frame; nessa década o top 200 é o frame inteiro
create table cobertura_top200_decada as
with ranqueados as (
  select
    e.*,
    row_number() over (partition by e.decada order by r.numVotes desc, e.tconst) as rank_votos_decada
  from elos e
  join ratings r using (tconst)
)
select
  decada,
  count(*) as filmes_corte_absoluto,
  count(*) filter (where rank_votos_decada <= 200) as filmes_top200,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30_corte_absoluto,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100_corte_absoluto,
  round(100.0 * count(*) filter (where rank_votos_decada <= 200 and tem_30_notas)
    / count(*) filter (where rank_votos_decada <= 200), 1) as pct_30_top200,
  round(100.0 * count(*) filter (where rank_votos_decada <= 200 and tem_100_notas)
    / count(*) filter (where rank_votos_decada <= 200), 1) as pct_100_top200
from ranqueados
group by 1
order by 1;
select * from cobertura_top200_decada;
copy cobertura_top200_decada to 'datalake/gold/cobertura_top200_decada.parquet' (format parquet);

-- década x quartil de posição dentro da década (pct_votos_decada do dim_titulo)
-- é o casamento de selecionabilidade de verdade: top 200 não casa, porque nos anos 1930 é o frame
-- inteiro (piso 5k votos) e nos 2010 é quem tem 421k+ votos, 3,5% da década
create table cobertura_decada_quartil as
select
  e.decada,
  case
    when d.pct_votos_decada >= 0.75 then 'q4 top 25%'
    when d.pct_votos_decada >= 0.50 then 'q3'
    when d.pct_votos_decada >= 0.25 then 'q2'
    else 'q1 base 25%'
  end as quartil,
  count(*) as filmes,
  count(*) < 30 as amostra_pequena,
  count(*) filter (where tem_30_notas) as tem_30_notas,
  count(*) filter (where tem_100_notas) as tem_100_notas,
  round(100.0 * count(*) filter (where tem_30_notas) / count(*), 1) as pct_30,
  round(100.0 * count(*) filter (where tem_100_notas) / count(*), 1) as pct_100
from elos e
join dim_titulo d using (tconst)
group by 1, 2
order by 1, 2;
select * from cobertura_decada_quartil;
copy cobertura_decada_quartil to 'datalake/gold/cobertura_decada_quartil.parquet' (format parquet);

-- a mesma coisa em uma linha por década, pra ler de relance (% com 100+ notas)
select
  decada,
  max(pct_100) filter (where quartil like 'q4%') as q4_top,
  max(pct_100) filter (where quartil = 'q3') as q3,
  max(pct_100) filter (where quartil = 'q2') as q2,
  max(pct_100) filter (where quartil like 'q1%') as q1_base
from cobertura_decada_quartil
group by 1
order by 1;
