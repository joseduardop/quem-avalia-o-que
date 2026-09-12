"""roda um script .sql no duckdb, statement por statement, imprimindo o que retornar linhas

uso: ops/venv-gestao/bin/python ops/run_sql.py recon/recon.sql
"""
import sys
import time

import duckdb

MAX_ROWS = 200
MAX_WIDTH = 220


def main(path):
    con = duckdb.connect()
    sql = open(path).read()
    for stmt in con.extract_statements(sql):
        t0 = time.time()
        rel = con.sql(stmt.query)
        dt = time.time() - t0
        if rel is None:
            continue
        rel.show(max_rows=MAX_ROWS, max_width=MAX_WIDTH)
        if dt > 1:
            print(f'  ({dt:.1f}s)')


if __name__ == '__main__':
    main(sys.argv[1])
