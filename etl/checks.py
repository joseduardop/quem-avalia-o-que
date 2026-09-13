"""checks de integridade do pacote: cada query devolve o número de violações, e qualquer uma > 0 derruba o processo

uso: ops/venv-gestao/bin/python etl/checks.py
"""

import sys

import duckdb

DL = "datalake"

CHECKS = [
    ("dim_titulo tem 17.810 linhas",
     f"select abs(count(*) - 17810) from '{DL}/silver/dim_titulo.parquet'"),
    ("dim_titulo: tconst único",
     f"select count(*) - count(distinct tconst) from '{DL}/silver/dim_titulo.parquet'"),
    ("dim_titulo: ano entre 1930 e 2023 e decada = ano // 10 * 10",
     f"select count(*) from '{DL}/silver/dim_titulo.parquet' where ano not between 1930 and 2023 or decada != (ano // 10) * 10"),
    ("dim_titulo: pct_votos_decada entre 0 e 1, sem nulo",
     f"select count(*) from '{DL}/silver/dim_titulo.parquet' where pct_votos_decada is null or pct_votos_decada not between 0 and 1"),
    ("dim_titulo: pais_unico preenchido se e só se n_paises = 1",
     f"select count(*) from '{DL}/silver/dim_titulo.parquet' where (n_paises = 1) != (pais_unico is not null)"),
    ("dim_titulo: n_paises e tem_us batem com titulo_pais",
     f"""select count(*) from '{DL}/silver/dim_titulo.parquet' d
         left join (select tconst, count(*) as n, bool_or(pais = 'US') as us from '{DL}/silver/titulo_pais.parquet' group by 1) p using (tconst)
         where d.n_paises != coalesce(p.n, 0) or d.tem_us != coalesce(p.us, false)"""),
    ("titulo_pais: sem duplicata (tconst, pais)",
     f"select count(*) - count(distinct (tconst, pais)) from '{DL}/silver/titulo_pais.parquet'"),
    ("ponte_ids: uma linha por tconst do dim_titulo, nem mais nem menos",
     f"""select count(*) from (
           select tconst from (
             select tconst from '{DL}/silver/dim_titulo.parquet'
             union all select tconst from '{DL}/silver/ponte_ids.parquet'
           ) group by tconst having count(*) != 2
         )"""),
    ("ponte_ids: metodo_join só com valores conhecidos",
     f"""select count(*) from '{DL}/silver/ponte_ids.parquet'
         where metodo_join not in ('ambos', 'wikidata', 'movielens', 'tmdb_find', 'arbitrado_tmdb', 'corrigido_tmdb', 'nenhum', 'nao_validado')"""),
    ("tmdb_titulo: uma linha por tconst e imdb_id == tconst",
     f"select count(*) - count(distinct tconst) + count(*) filter (where imdb_id != tconst) from '{DL}/silver/tmdb_titulo.parquet'"),
    ("tmdb_titulo: classificacao_br só L/10/12/14/16/18",
     f"select count(*) from '{DL}/silver/tmdb_titulo.parquet' where classificacao_br is not null and classificacao_br not in ('L', '10', '12', '14', '16', '18')"),
    ("fato_notas: todo tconst existe no dim_titulo",
     f"select count(*) from '{DL}/silver/fato_notas.parquet' f where tconst not in (select tconst from '{DL}/silver/dim_titulo.parquet')"),
    ("fato_notas: sem duplicata (tconst, plataforma)",
     f"select count(*) - count(distinct (tconst, plataforma)) from '{DL}/silver/fato_notas.parquet'"),
    ("fato_notas: plataforma só imdb/tmdb/letterboxd/ml32",
     f"select count(*) from '{DL}/silver/fato_notas.parquet' where plataforma not in ('imdb', 'tmdb', 'letterboxd', 'ml32')"),
    ("fato_notas: nota dentro de escala_min e escala_max",
     f"select count(*) from '{DL}/silver/fato_notas.parquet' where nota is null or nota < escala_min or nota > escala_max"),
    ("fato_notas: n_votos > 0",
     f"select count(*) from '{DL}/silver/fato_notas.parquet' where n_votos is null or n_votos <= 0"),
    ("fato_notas: data_coleta e tipo_medida preenchidos",
     f"select count(*) from '{DL}/silver/fato_notas.parquet' where data_coleta is null or tipo_medida != 'acumulado'"),
    ("fato_notas: imdb cobre o frame inteiro",
     f"select 17810 - count(*) from '{DL}/silver/fato_notas.parquet' where plataforma = 'imdb'"),
    ("fato_notas_demografia: sem duplicata (tconst, faixa, gênero)",
     f"select count(*) - count(distinct (tconst, faixa_etaria_cod, genero_usuario)) from '{DL}/silver/fato_notas_demografia.parquet'"),
    ("fato_notas_demografia: nota_media entre 1 e 5, n_notas > 0, tipo janela",
     f"select count(*) from '{DL}/silver/fato_notas_demografia.parquet' where nota_media not between 1 and 5 or n_notas <= 0 or tipo_medida != 'janela'"),
    ("fato_notas_demografia: soma de n_notas bate com o ml-1m filtrado no frame",
     f"""select abs((select sum(n_notas) from '{DL}/silver/fato_notas_demografia.parquet') - (
           select count(*) from '{DL}/bronze/ml1_ratings.parquet' r
           join (select printf('tt%07d', imdbId::bigint) as tconst, movieId from '{DL}/bronze/movielens_links.parquet'
                 qualify row_number() over (partition by tconst order by movieId) = 1) m on m.movieId = r.movie_id
           join '{DL}/silver/dim_titulo.parquet' d using (tconst)))"""),
    ("notas_normalizadas: n_votos >= 30, z finito, pct entre 0 e 1",
     f"select count(*) from '{DL}/gold/notas_normalizadas.parquet' where n_votos < 30 or not isfinite(nota_z) or nota_pct not between 0 and 1"),
    ("divergencia_par: plataforma_a < plataforma_b e sem duplicata",
     f"select count(*) filter (where plataforma_a >= plataforma_b) + count(*) - count(distinct (tconst, plataforma_a, plataforma_b)) from '{DL}/gold/divergencia_par.parquet'"),
    ("divergencia_par: gap_z = z_b - z_a",
     f"select count(*) from '{DL}/gold/divergencia_par.parquet' where abs(gap_z - (z_b - z_a)) > 1e-9"),
    ("deriva_ml32: n_notas > 0 e ano entre 1995 e 2023",
     f"select count(*) from '{DL}/gold/deriva_ml32.parquet' where n_notas <= 0 or ano_avaliacao not between 1995 and 2023"),
    ("gradiente_idade: as 7 faixas",
     f"select abs(count(*) - 7) from '{DL}/gold/gradiente_idade.parquet'"),
]


def main():
    con = duckdb.connect()
    falhas = 0
    largura = max(len(nome) for nome, _ in CHECKS)
    for nome, sql in CHECKS:
        violacoes = con.execute(sql).fetchone()[0] or 0
        marca = "ok  " if violacoes == 0 else "FALHOU"
        print(f"{marca}  {nome.ljust(largura)}  {violacoes}")
        falhas += violacoes > 0
    print(f"\n{len(CHECKS) - falhas}/{len(CHECKS)} checks ok")
    sys.exit(1 if falhas else 0)


if __name__ == "__main__":
    main()
