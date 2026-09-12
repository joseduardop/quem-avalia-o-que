-- bronze -> silver: regra de negócio. o corte do frame e a regra da ponte moram aqui
-- rodar com: ops/venv-gestao/bin/python ops/run_sql.py etl/silver.sql
-- bronze é o que a fonte disse; se alguém questionar o corte, muda aqui e o bronze fica intacto

create view basics as select * from 'datalake/bronze/imdb_basics.parquet';
create view ratings as select * from 'datalake/bronze/imdb_ratings.parquet';
create view links as select * from 'datalake/bronze/movielens_links.parquet';
create view lb_films as select * from 'datalake/bronze/letterboxd_films.parquet';
create view lb_ratings as select * from 'datalake/bronze/letterboxd_ratings.parquet';
create view wd as select * from 'datalake/bronze/wikidata_ponte.parquet';

-- 1. dim_titulo: o frame congelado. contrato do projeto, tudo que vier depois se junta a ele
-- corte: filme, 5000+ votos no imdb, 1930-2023 (justificativa em recon/relatorio.md)
create table dim_titulo as
select
  b.tconst,
  b.primaryTitle as titulo,
  b.originalTitle as titulo_original,
  b.startYear as ano,
  (b.startYear // 10) * 10 as decada,
  b.runtimeMinutes as duracao,
  b.genres as generos
from basics b
join ratings r using (tconst)
where b.titleType = 'movie'
  and r.numVotes >= 5000
  and b.startYear between 1930 and 2023;

select count(*) as dim_titulo, count(distinct tconst) as tconst_distintos from dim_titulo;
copy dim_titulo to 'datalake/silver/dim_titulo.parquet' (format parquet);

-- 2. checagem de cardinalidade do wikidata, antes de qualquer join
select
  count(*) as linhas,
  count(distinct imdb_id) as imdb_distintos,
  count(distinct letterboxd_slug) as slug_distintos,
  count(distinct lower(letterboxd_slug)) as slug_distintos_lower,
  count(distinct (imdb_id, letterboxd_slug)) as pares_distintos,
  count(*) filter (where imdb_id is null) as imdb_nulo,
  count(*) filter (where not regexp_matches(imdb_id, '^tt[0-9]+$')) as imdb_nao_tt,
  count(*) filter (where letterboxd_slug is null) as slug_nulo
from wd;

-- imdb_id em mais de uma linha
with rep as (
  select imdb_id, count(*) as n, count(distinct letterboxd_slug) as n_slugs, count(distinct tmdb_id) as n_tmdb
  from wd where imdb_id is not null group by 1 having count(*) > 1
)
select
  case
    when n_slugs > 1 and n_tmdb > 1 then 'slug e tmdb diferentes'
    when n_slugs > 1 then 'slug diferente'
    when n_tmdb > 1 then 'mesmo slug, tmdb diferente (p4947 multivalorado)'
    else 'linha idêntica'
  end as tipo_de_repeticao,
  count(*) as imdb_ids,
  sum(n) as linhas
from rep group by 1 order by 2 desc;

with rep as (select imdb_id from wd where imdb_id is not null group by 1 having count(distinct letterboxd_slug) > 1)
select w.* from wd w join rep using (imdb_id) order by imdb_id, letterboxd_slug, tmdb_id limit 20;

-- slug em mais de uma linha
with rep as (
  select letterboxd_slug, count(*) as n, count(distinct imdb_id) as n_imdb
  from wd where letterboxd_slug is not null group by 1 having count(*) > 1
)
select
  case when n_imdb > 1 then 'imdb diferente (imdb duplicado ou item errado)' else 'mesmo imdb' end as tipo_de_repeticao,
  count(*) as slugs,
  sum(n) as linhas
from rep group by 1 order by 2 desc;

-- 3. regra da ponte wikidata
-- a. fora: imdb nulo (blank node), imdb que não é título (nm...), slug nulo
-- b. distinct tira as linhas idênticas
-- c. uma linha por par (imdb_id, slug); com mais de um tmdb no par fica o menor (entrada mais antiga do tmdb)
--    e n_tmdb registra a ambiguidade; o crawl do tmdb devolve o imdb_id e confere isso depois
-- d. slug_ambiguo: o imdb tem mais de um slug. slug_compartilhado: o slug tem mais de um imdb
create table wd_pares as
with validas as (
  select distinct imdb_id, lower(letterboxd_slug) as letterboxd_slug, tmdb_id
  from wd
  where regexp_matches(imdb_id, '^tt[0-9]+$')
    and letterboxd_slug is not null
),
pares as (
  select imdb_id, letterboxd_slug, min(tmdb_id) as tmdb_id, count(distinct tmdb_id) as n_tmdb
  from validas
  group by 1, 2
)
select
  imdb_id,
  letterboxd_slug,
  tmdb_id,
  n_tmdb,
  count(*) over (partition by imdb_id) > 1 as slug_ambiguo,
  count(*) over (partition by letterboxd_slug) > 1 as slug_compartilhado
from pares;

select
  count(*) as pares,
  count(distinct imdb_id) as imdb_distintos,
  count(*) filter (where slug_ambiguo) as pares_com_slug_ambiguo,
  count(distinct imdb_id) filter (where slug_ambiguo) as imdb_com_slug_ambiguo,
  count(*) filter (where slug_compartilhado) as pares_com_slug_compartilhado,
  count(*) filter (where n_tmdb > 1) as pares_com_tmdb_ambiguo
from wd_pares;

-- 4. volume de notas por slug no dump do letterboxd (usado no desempate e na medição)
create table lb_volume as
select film_id, count(*) as n_notas
from lb_ratings
group by 1;

-- 5. um slug por tconst do frame
-- desempate quando o imdb tem mais de um slug: o que existe no dump e tem mais notas, depois ordem alfabética
create table slug_por_tconst as
select
  p.imdb_id as tconst,
  p.letterboxd_slug,
  p.tmdb_id as tmdb_id_wikidata,
  p.n_tmdb,
  p.slug_ambiguo,
  p.slug_compartilhado,
  f.film_id is not null as slug_no_dump,
  coalesce(v.n_notas, 0) as n_notas_lb
from wd_pares p
join dim_titulo d on d.tconst = p.imdb_id
left join lb_films f on f.film_id = p.letterboxd_slug
left join lb_volume v on v.film_id = p.letterboxd_slug
qualify row_number() over (
  partition by p.imdb_id
  order by f.film_id is not null desc, coalesce(v.n_notas, 0) desc, p.letterboxd_slug
) = 1;

-- quantos do frame ficaram com slug ambíguo ou compartilhado (o que a sensibilidade vai excluir)
select
  count(*) as tconst_com_slug,
  count(*) filter (where slug_ambiguo) as slug_ambiguo,
  count(*) filter (where slug_compartilhado) as slug_compartilhado,
  count(*) filter (where n_tmdb > 1) as tmdb_ambiguo
from slug_por_tconst;

-- slug compartilhado dentro do frame: dois tconst do frame apontando pro mesmo slug (as notas do lb seriam contadas duas vezes)
select s.letterboxd_slug, s.tconst, d.titulo, d.ano, s.n_notas_lb
from slug_por_tconst s
join dim_titulo d using (tconst)
where s.letterboxd_slug in (select letterboxd_slug from slug_por_tconst group by 1 having count(*) > 1)
order by 1, 2;

-- 6. tmdb_id do movielens: o links.csv guarda o imdbId zero-padded de 7 dígitos, o printf cobre 7 e 8
create table ml_tmdb as
select printf('tt%07d', imdbId::bigint) as tconst, tmdbId as tmdb_id_movielens
from links
qualify row_number() over (partition by tconst order by movieId) = 1;

-- 7. ponte_ids: uma linha por tconst do frame
-- metodo_join diz de onde veio o tmdb_id: ambos (concordam), movielens, wikidata, divergente (discordam:
-- fica o do movielens, que é curado filme a filme; o do wikidata segue no bronze), nenhum (vai pro /find)
create table ponte_ids as
select
  d.tconst,
  coalesce(m.tmdb_id_movielens, s.tmdb_id_wikidata) as tmdb_id,
  s.letterboxd_slug,
  case
    when m.tmdb_id_movielens = s.tmdb_id_wikidata then 'ambos'
    when m.tmdb_id_movielens is not null and s.tmdb_id_wikidata is not null then 'divergente'
    when m.tmdb_id_movielens is not null then 'movielens'
    when s.tmdb_id_wikidata is not null then 'wikidata'
    else 'nenhum'
  end as metodo_join,
  coalesce(s.slug_ambiguo, false) as slug_ambiguo,
  coalesce(s.slug_compartilhado, false) as slug_compartilhado
from dim_titulo d
left join ml_tmdb m using (tconst)
left join slug_por_tconst s using (tconst);

select count(*) as ponte_ids, count(distinct tconst) as tconst_distintos,
  count(tmdb_id) as com_tmdb, count(letterboxd_slug) as com_slug
from ponte_ids;

select metodo_join, count(*) as filmes, round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from ponte_ids group by 1 order by 2 desc;

copy ponte_ids to 'datalake/silver/ponte_ids.parquet' (format parquet);

-- 8. divergência de tmdb_id entre movielens e wikidata, com exemplos
select p.tconst, d.titulo, d.ano, m.tmdb_id_movielens, s.tmdb_id_wikidata, s.n_tmdb as n_tmdb_wikidata, s.letterboxd_slug
from ponte_ids p
join dim_titulo d using (tconst)
join ml_tmdb m using (tconst)
join slug_por_tconst s using (tconst)
where p.metodo_join = 'divergente'
order by d.ano
limit 30;

-- as tabelas intermediárias ficam em silver também, pro gold não recalcular
-- wikidata_pares é a ponte inteira (268k) com a regra aplicada: se o corte mudar, ela já serve
copy wd_pares to 'datalake/silver/wikidata_pares.parquet' (format parquet);
copy slug_por_tconst to 'datalake/silver/slug_por_tconst.parquet' (format parquet);
copy lb_volume to 'datalake/silver/lb_volume.parquet' (format parquet);
