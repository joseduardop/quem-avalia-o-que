-- silver, segunda passada: aplica a validação de identidade do tmdb à ponte
-- rodar depois de ops/crawl_tmdb.py e etl/processa_tmdb.py:
--   ops/venv-gestao/bin/python ops/run_sql.py etl/silver_tmdb.sql
-- lê e reescreve silver/ponte_ids.parquet. é idempotente: rodar duas vezes dá o mesmo resultado.
-- se etl/silver.sql rodar de novo a ponte volta ao estado pré-tmdb; basta rodar este script de novo
-- (nenhuma requisição: tudo sai do bronze/tmdb_filmes.parquet)

create table ponte as select * from 'datalake/silver/ponte_ids.parquet';
create table tmdb as select * from 'datalake/bronze/tmdb_filmes.parquet';
create view dim_titulo as select * from 'datalake/silver/dim_titulo.parquet';
create view slug_por_tconst as select * from 'datalake/silver/slug_por_tconst.parquet';
create view ml_links as select * from 'datalake/bronze/movielens_links.parquet';

-- 1. validação de identidade em todas as respostas: o imdb_id devolvido é o tconst que pedimos?
select
  count(*) as respostas_200,
  count(distinct tconst_esperado) as tconst_consultados,
  count(*) filter (where imdb_id = tconst_esperado) as bate,
  count(*) filter (where imdb_id != tconst_esperado) as nao_bate,
  count(*) filter (where imdb_id is null) as sem_imdb_id
from tmdb;

-- o que não bateu: candidata errada de divergência, id trocado na fonte, ou entrada duplicada do tmdb
select t.tconst_esperado, p.metodo_join as metodo_antes, t.tmdb_id, t.imdb_id as imdb_devolvido, t.title, t.release_date
from tmdb t
join ponte p on p.tconst = t.tconst_esperado
where t.imdb_id is distinct from t.tconst_esperado
order by 1
limit 40;

-- 2. candidatas válidas e a escolha: mantém o tmdb_id atual se ele validou, senão o menor válido
create table validas as
select tconst_esperado as tconst, tmdb_id
from tmdb
where imdb_id = tconst_esperado;

create table escolha as
select
  p.tconst,
  p.tmdb_id as tmdb_id_anterior,
  p.metodo_join as metodo_anterior,
  coalesce(max(v.tmdb_id) filter (where v.tmdb_id = p.tmdb_id), min(v.tmdb_id)) as tmdb_id_validado,
  count(v.tmdb_id) as n_validas
from ponte p
left join validas v using (tconst)
group by 1, 2, 3;

-- mais de uma candidata válida: o tmdb tem duas entradas com o mesmo imdb_id. fica registrado, escolha acima
select e.tconst, d.titulo, e.tmdb_id_anterior, e.tmdb_id_validado, list(v.tmdb_id order by v.tmdb_id) as candidatas
from escolha e
join validas v using (tconst)
join dim_titulo d using (tconst)
where e.n_validas > 1
group by all
order by 1;

-- 3. ponte nova
-- metodo_join: nenhum (sem id, /find não achou) | nao_validado (tem id mas nenhuma candidata devolveu o tconst)
--   | arbitrado_tmdb (era divergente) | tmdb_find (era nenhum) | corrigido_tmdb (id trocado pelo /find) | o anterior
create table ponte_nova as
select
  p.tconst,
  coalesce(e.tmdb_id_validado, p.tmdb_id) as tmdb_id,
  p.letterboxd_slug,
  case
    when e.tmdb_id_validado is null and p.tmdb_id is null then 'nenhum'
    when e.tmdb_id_validado is null then 'nao_validado'
    when p.metodo_join = 'divergente' then 'arbitrado_tmdb'
    when p.metodo_join = 'nenhum' then 'tmdb_find'
    when e.tmdb_id_validado != p.tmdb_id then 'corrigido_tmdb'
    else p.metodo_join
  end as metodo_join,
  p.slug_ambiguo,
  p.slug_compartilhado
from ponte p
join escolha e using (tconst);

select metodo_join, count(*) as filmes, round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from ponte_nova
group by 1
order by 2 desc;

-- os 29 sem id: quantos o /find resolveu
select
  count(*) as sem_id_antes,
  count(*) filter (where tmdb_id_validado is not null) as resolvidos_pelo_find
from escolha
where metodo_anterior in ('nenhum', 'tmdb_find');

-- sem identidade validada: continuam na ponte com o id antigo, mas marcados. não entram em tmdb_titulo
select n.tconst, d.titulo, d.ano, n.tmdb_id, e.metodo_anterior
from ponte_nova n
join dim_titulo d using (tconst)
join escolha e using (tconst)
where n.metodo_join = 'nao_validado'
order by d.ano;

-- 4. arbitragem das divergências: movielens e wikidata discordavam, quem estava certo?
-- a divergência é recomputada das fontes, então a tabela sai igual em qualquer rodada
create table ml_tmdb as
select printf('tt%07d', imdbId::bigint) as tconst, tmdbId as tmdb_movielens
from ml_links
qualify row_number() over (partition by tconst order by movieId) = 1;

create table arbitragem as
select
  n.tconst,
  d.titulo,
  d.ano,
  m.tmdb_movielens,
  s.tmdb_id_wikidata,
  n.tmdb_id as vencedor,
  case
    when n.metodo_join = 'nao_validado' then 'nenhuma das duas'
    when n.tmdb_id = m.tmdb_movielens then 'movielens'
    when n.tmdb_id = s.tmdb_id_wikidata then 'wikidata'
    else 'outra (via /find)'
  end as fonte_certa
from ponte_nova n
join dim_titulo d using (tconst)
join ml_tmdb m using (tconst)
join slug_por_tconst s using (tconst)
where m.tmdb_movielens != s.tmdb_id_wikidata
order by d.ano;
select * from arbitragem;
select fonte_certa, count(*) as casos from arbitragem group by 1 order by 2 desc;

-- 5. tmdb_titulo: o registro validado do tmdb, um por tconst do frame
create table tmdb_titulo as
select n.tconst, t.* exclude (tconst_esperado)
from ponte_nova n
join tmdb t on t.tconst_esperado = n.tconst and t.tmdb_id = n.tmdb_id
where n.metodo_join not in ('nenhum', 'nao_validado');

select count(*) as tmdb_titulo, count(distinct tconst) as tconst_distintos from tmdb_titulo;

copy ponte_nova to 'datalake/silver/ponte_ids.parquet' (format parquet);
copy tmdb_titulo to 'datalake/silver/tmdb_titulo.parquet' (format parquet);
copy arbitragem to 'datalake/gold/arbitragem_tmdb.parquet' (format parquet);
