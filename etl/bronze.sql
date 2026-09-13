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

-- movielens 1m: .dat com separador '::', sem cabeçalho, latin-1. age vem codificado (1, 18, 25, 35, 45, 50, 56)
copy (
  select * from read_csv('datalake/landing/ml-1m/users.dat', delim='::', header=false, encoding='latin-1',
    columns={'user_id': 'integer', 'gender': 'varchar', 'age': 'integer', 'occupation': 'integer', 'zip': 'varchar'})
) to 'datalake/bronze/ml1_users.parquet' (format parquet);

copy (
  select * from read_csv('datalake/landing/ml-1m/ratings.dat', delim='::', header=false,
    columns={'user_id': 'integer', 'movie_id': 'integer', 'rating': 'integer', 'ts': 'bigint'})
) to 'datalake/bronze/ml1_ratings.parquet' (format parquet);

copy (
  select * from read_csv('datalake/landing/ml-1m/movies.dat', delim='::', header=false, encoding='latin-1', quote='',
    columns={'movie_id': 'integer', 'title': 'varchar', 'genres': 'varchar'})
) to 'datalake/bronze/ml1_movies.parquet' (format parquet);

-- movielens 32m: 32 milhões de notas com timestamp (1995-2023), a única fonte do projeto com dimensão temporal
copy (
  select * from read_csv('datalake/landing/ml-32m/ratings.csv', header=true,
    types={'userId': 'integer', 'movieId': 'integer', 'rating': 'decimal(2,1)', 'timestamp': 'bigint'})
) to 'datalake/bronze/ml32_ratings.parquet' (format parquet);

-- agregado por filme e ano de avaliação: o que a análise de deriva consome, sem carregar os 32m
copy (
  select movieId, year(to_timestamp(timestamp)) as ano_avaliacao, count(*) as n_notas, round(avg(rating), 4) as nota_media
  from 'datalake/bronze/ml32_ratings.parquet'
  group by 1, 2
) to 'datalake/bronze/ml32_por_ano.parquet' (format parquet);

select 'ml1_users' as fonte, count(*) as linhas from 'datalake/bronze/ml1_users.parquet'
union all select 'ml1_ratings', count(*) from 'datalake/bronze/ml1_ratings.parquet'
union all select 'ml1_movies', count(*) from 'datalake/bronze/ml1_movies.parquet'
union all select 'ml32_ratings', count(*) from 'datalake/bronze/ml32_ratings.parquet'
union all select 'ml32_por_ano', count(*) from 'datalake/bronze/ml32_por_ano.parquet';
