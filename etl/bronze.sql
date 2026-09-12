-- landing -> bronze: um parquet por fonte, tipado e limpo, fiel à origem, sem regra de negócio
-- rodar com: ops/venv-gestao/bin/python ops/run_sql.py etl/bronze.sql
-- só as fontes que a ponte e o frame usam; akas, ml-1m, ml-32m ratings e box office entram quando precisar

-- imdb: quote='' porque os títulos têm aspas não escapadas, nullstr='\N' é o nulo do imdb
-- nomes de coluna ficam como na fonte, renomear é papel do silver
copy (
  select *
  from read_csv('datalake/landing/title.basics.tsv', delim='\t', header=true, quote='', nullstr='\N',
    types={'isAdult': 'boolean', 'startYear': 'integer', 'endYear': 'integer', 'runtimeMinutes': 'integer'})
) to 'datalake/bronze/imdb_basics.parquet' (format parquet);

copy (
  select *
  from read_csv('datalake/landing/title.ratings.tsv', delim='\t', header=true, quote='', nullstr='\N',
    types={'averageRating': 'decimal(3,1)', 'numVotes': 'integer'})
) to 'datalake/bronze/imdb_ratings.parquet' (format parquet);

-- movielens: o imdbId vem como string zero-padded de 7 dígitos (ou 8 sem padding); fica como veio
copy (
  select *
  from read_csv('datalake/landing/ml-32m/links.csv', header=true,
    types={'movieId': 'integer', 'imdbId': 'varchar', 'tmdbId': 'integer'})
) to 'datalake/bronze/movielens_links.parquet' (format parquet);

-- letterboxd: nullstr='' pra string vazia ser o único nulo; o film_id 'null' literal é um filme de verdade
copy (
  select *
  from read_csv('datalake/landing/letterboxd-film-ratings/films.csv', header=true, nullstr='',
    types={'film_id': 'varchar', 'film_name': 'varchar', 'year': 'integer', 'poster_url': 'varchar'})
) to 'datalake/bronze/letterboxd_films.parquet' (format parquet);

copy (
  select *
  from read_csv('datalake/landing/letterboxd-film-ratings/ratings.csv', header=true, nullstr='',
    types={'user_name': 'varchar', 'film_id': 'varchar', 'rating': 'decimal(2,1)'})
) to 'datalake/bronze/letterboxd_ratings.parquet' (format parquet);

-- wikidata: tsv "completo" do wdqs, literais entre aspas (o quote='"' já tira)
-- blank node (<http://www.wikidata.org/.well-known/genid/...>) é "valor desconhecido" em rdf: vira nulo
-- tmdb vem quase todo numérico, mas tem 'NNN-slug', url completa e um qid; extraio o número onde dá
-- o slug fica como veio (inclusive 'film:NNN', que é forma legítima do letterboxd); lower() é no join
copy (
  select
    case when imdb like '<http://www.wikidata.org/.well-known/genid/%' then null else imdb end as imdb_id,
    case when lb like '<http://www.wikidata.org/.well-known/genid/%' then null else lb end as letterboxd_slug,
    case
      when regexp_matches(tmdb, '^[0-9]+$') then tmdb::integer
      when regexp_matches(tmdb, '^[0-9]+-') then regexp_extract(tmdb, '^([0-9]+)', 1)::integer
      when tmdb like '%themoviedb.org/movie/%' then regexp_extract(tmdb, 'movie/([0-9]+)', 1)::integer
    end as tmdb_id
  from read_csv('datalake/landing/wikidata.tsv', delim='\t', header=true, quote='"', nullstr='', all_varchar=true,
    columns={'imdb': 'varchar', 'lb': 'varchar', 'tmdb': 'varchar'})
) to 'datalake/bronze/wikidata_ponte.parquet' (format parquet);

-- conferência: linhas de cada parquet
select 'imdb_basics' as fonte, count(*) as linhas from 'datalake/bronze/imdb_basics.parquet'
union all select 'imdb_ratings', count(*) from 'datalake/bronze/imdb_ratings.parquet'
union all select 'movielens_links', count(*) from 'datalake/bronze/movielens_links.parquet'
union all select 'letterboxd_films', count(*) from 'datalake/bronze/letterboxd_films.parquet'
union all select 'letterboxd_ratings', count(*) from 'datalake/bronze/letterboxd_ratings.parquet'
union all select 'wikidata_ponte', count(*) from 'datalake/bronze/wikidata_ponte.parquet';

describe select * from 'datalake/bronze/wikidata_ponte.parquet';
