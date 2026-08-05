"""The same workloads as bench/minato_bench.erl, for the Python clients.

asyncpg prepares every statement it runs, and psycopg is asked to prepare, so
the `cached` row means what it means in the Erlang report.

    cd bench/py && python3 -m venv .venv && .venv/bin/pip install -q asyncpg psycopg[binary]
    .venv/bin/python bench.py
"""

import asyncio
import json
import os
import time

ITERATIONS = int(os.environ.get("MINATO_BENCH_ITERATIONS", "2000"))
WARMUP = 200
WORKERS = 8

CONFIG = {
    "host": os.environ.get("MINATO_PG_HOST", "127.0.0.1"),
    "port": int(os.environ.get("MINATO_PG_PORT", "55432")),
    "database": os.environ.get("MINATO_PG_DATABASE", "minato_test"),
    "user": os.environ.get("MINATO_PG_USER", "minato"),
    "password": os.environ.get("MINATO_PG_PASSWORD", "minato"),
}

ROWS = lambda n: f"SELECT i, repeat('x', 32) FROM generate_series(1, {n}) i"
WIDE = "SELECT " + ", ".join(f"i * {n}" for n in range(1, 65)) + " FROM generate_series(1, 1) i"
INSERT = "INSERT INTO minato_bench (n, name) VALUES ($1, $2)"


def counts(workload):
    if workload in ("rows_5000", "concurrent"):
        return max(1, ITERATIONS // 20)
    if workload == "rows_1000":
        return max(1, ITERATIONS // 5)
    return ITERATIONS


async def measure(client, workload, run):
    for _ in range(WARMUP):
        await run()
    samples = []
    for _ in range(counts(workload)):
        start = time.perf_counter_ns()
        await run()
        samples.append((time.perf_counter_ns() - start) / 1000)
    samples.sort()
    total = sum(samples)
    return {
        "client": client,
        "workload": workload,
        "mean": total / len(samples),
        "median": samples[len(samples) // 2],
        "p99": samples[min(len(samples) - 1, int(len(samples) * 0.99))],
        "ops": len(samples) * 1e6 / total,
    }


async def run_asyncpg():
    import asyncpg

    conn = await asyncpg.connect(**CONFIG)
    await conn.execute("DROP TABLE IF EXISTS minato_bench")
    await conn.execute("CREATE UNLOGGED TABLE minato_bench (n int4, name text)")
    pool = await asyncpg.create_pool(**CONFIG, min_size=WORKERS, max_size=WORKERS)

    cached = await conn.prepare("SELECT $1::int4")
    rows_1000 = await conn.prepare(ROWS(1000))
    rows_5000 = await conn.prepare(ROWS(5000))
    wide = await conn.prepare(WIDE)
    insert = await conn.prepare(INSERT)

    async def concurrent():
        await asyncio.gather(*(pool.fetch("SELECT $1::int4", 42) for _ in range(WORKERS)))

    results = [
        await measure("asyncpg", "simple", lambda: conn.execute("SELECT 1")),
        await measure("asyncpg", "unnamed", lambda: conn.fetch("SELECT $1::int4", 42)),
        await measure("asyncpg", "cached", lambda: cached.fetch(42)),
        await measure("asyncpg", "rows_1000", lambda: rows_1000.fetch()),
        await measure("asyncpg", "rows_5000", lambda: rows_5000.fetch()),
        await measure("asyncpg", "wide_row", lambda: wide.fetch()),
        await measure("asyncpg", "insert", lambda: insert.fetch(1, "a")),
        await measure("asyncpg", "concurrent", concurrent),
    ]
    await pool.close()
    await conn.close()
    return results


async def run_psycopg():
    import psycopg

    conn = await psycopg.AsyncConnection.connect(autocommit=True, **CONFIG)
    cursor = conn.cursor()

    def numbered(sql):
        return sql.replace("$1", "%s").replace("$2", "%s")

    async def one(sql, params=None, prepare=True):
        await cursor.execute(numbered(sql), params, prepare=prepare)
        if cursor.description:
            await cursor.fetchall()

    async def concurrent():
        connections = getattr(run_psycopg, "pool")
        await asyncio.gather(*(
            c.execute("SELECT %s::int4", (42,), prepare=True) for c in connections
        ))

    run_psycopg.pool = [
        await psycopg.AsyncConnection.connect(autocommit=True, **CONFIG) for _ in range(WORKERS)
    ]

    results = [
        await measure("psycopg3", "simple", lambda: one("SELECT 1", None, False)),
        await measure("psycopg3", "unnamed", lambda: one("SELECT $1::int4", (42,), False)),
        await measure("psycopg3", "cached", lambda: one("SELECT $1::int4", (42,), True)),
        await measure("psycopg3", "rows_1000", lambda: one(ROWS(1000))),
        await measure("psycopg3", "rows_5000", lambda: one(ROWS(5000))),
        await measure("psycopg3", "wide_row", lambda: one(WIDE)),
        await measure("psycopg3", "insert", lambda: one(INSERT, (1, "a"))),
        await measure("psycopg3", "concurrent", concurrent),
    ]
    for each in run_psycopg.pool:
        await each.close()
    await conn.close()
    return results


async def main():
    results = await run_asyncpg() + await run_psycopg()
    print(json.dumps(results))


asyncio.run(main())
