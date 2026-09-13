"""roda um script .sql no duckdb, statement por statement, imprimindo o que retornar linhas

uso: ops/venv-gestao/bin/python ops/run_sql.py recon/recon.sql
"""
import contextlib
import io
import sys
import time

import duckdb

MAX_ROWS = 200
MAX_WIDTH = 220

# o duckdb desenha as tabelas com caixa unicode (u+2500 a u+253c); aqui vira + - | pra ficar digitável e grepável
CANTOS = "\u250c\u2510\u2514\u2518\u251c\u2524\u252c\u2534\u253c"
ASCII = str.maketrans({c: "+" for c in CANTOS} | {"\u2500": "-", "\u2502": "|", "\u2026": "..."})


def main(path):
    con = duckdb.connect()
    sql = open(path).read()
    for stmt in con.extract_statements(sql):
        t0 = time.time()
        rel = con.sql(stmt.query)
        dt = time.time() - t0
        if rel is None:
            continue
        saida = io.StringIO()
        with contextlib.redirect_stdout(saida):
            rel.show(max_rows=MAX_ROWS, max_width=MAX_WIDTH)
        print(saida.getvalue().translate(ASCII), end="")
        if dt > 1:
            print(f'  ({dt:.1f}s)')


if __name__ == '__main__':
    main(sys.argv[1])
