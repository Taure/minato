// The same workloads as bench/minato_bench.erl, for the JavaScript clients.
//
// node-postgres and postgres.js are what a Node application uses, and both
// prepare statements when asked to, so the `cached` row means the same thing it
// does in the Erlang report.
//
//   cd bench/js && npm install && node bench.mjs

import pg from 'pg';
import postgres from 'postgres';

const ITERATIONS = Number(process.env.MINATO_BENCH_ITERATIONS ?? 2000);
const WARMUP = 200;
const WORKERS = 8;

const config = {
  host: process.env.MINATO_PG_HOST ?? '127.0.0.1',
  port: Number(process.env.MINATO_PG_PORT ?? 55432),
  database: process.env.MINATO_PG_DATABASE ?? 'minato_test',
  user: process.env.MINATO_PG_USER ?? 'minato',
  password: process.env.MINATO_PG_PASSWORD ?? 'minato',
};

const rowsSql = (n) => `SELECT i, repeat('x', 32) FROM generate_series(1, ${n}) i`;
const wideSql = () =>
  'SELECT ' +
  Array.from({ length: 64 }, (_, i) => `i * ${i + 1}`).join(', ') +
  ' FROM generate_series(1, 1) i';
const insertSql = () => 'INSERT INTO minato_bench (n, name) VALUES ($1, $2)';

const counts = (workload) => {
  if (workload === 'rows_5000' || workload === 'concurrent') return Math.max(1, ITERATIONS / 20);
  if (workload === 'rows_1000') return Math.max(1, ITERATIONS / 5);
  return ITERATIONS;
};

async function measure(client, workload, run) {
  for (let i = 0; i < WARMUP; i++) await run();
  const samples = [];
  const n = counts(workload);
  for (let i = 0; i < n; i++) {
    const start = process.hrtime.bigint();
    await run();
    samples.push(Number(process.hrtime.bigint() - start) / 1000);
  }
  samples.sort((a, b) => a - b);
  const total = samples.reduce((a, b) => a + b, 0);
  return {
    client,
    workload,
    mean: total / samples.length,
    median: samples[Math.floor(samples.length * 0.5)],
    p99: samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.99))],
    ops: (samples.length * 1e6) / total,
  };
}

async function nodePostgres() {
  const client = new pg.Client(config);
  await client.connect();
  await client.query('DROP TABLE IF EXISTS minato_bench');
  await client.query('CREATE UNLOGGED TABLE minato_bench (n int4, name text)');
  const named = (name, text, values = []) => ({ name, text, values });
  const pool = new pg.Pool({ ...config, max: WORKERS });

  const results = [
    await measure('node-postgres', 'simple', () => client.query('SELECT 1')),
    await measure('node-postgres', 'unnamed', () => client.query('SELECT $1::int4', [42])),
    await measure('node-postgres', 'cached', () => client.query(named('c', 'SELECT $1::int4', [42]))),
    await measure('node-postgres', 'rows_1000', () => client.query(named('r1', rowsSql(1000)))),
    await measure('node-postgres', 'rows_5000', () => client.query(named('r5', rowsSql(5000)))),
    await measure('node-postgres', 'wide_row', () => client.query(named('w', wideSql()))),
    await measure('node-postgres', 'insert', () => client.query(named('i', insertSql(), [1, 'a']))),
    await measure('node-postgres', 'concurrent', () =>
      Promise.all(Array.from({ length: WORKERS }, () => pool.query('SELECT $1::int4', [42])))),
  ];
  await client.end();
  await pool.end();
  return results;
}

async function postgresJs() {
  const sql = postgres({ ...config, max: 1, prepare: true });
  const pool = postgres({ ...config, max: WORKERS, prepare: true });
  const results = [
    await measure('postgres.js', 'simple', () => sql.unsafe('SELECT 1')),
    await measure('postgres.js', 'unnamed', () => sql.unsafe('SELECT $1::int4', [42], { prepare: false })),
    await measure('postgres.js', 'cached', () => sql`SELECT ${42}::int4`),
    await measure('postgres.js', 'rows_1000', () => sql.unsafe(rowsSql(1000), [], { prepare: true })),
    await measure('postgres.js', 'rows_5000', () => sql.unsafe(rowsSql(5000), [], { prepare: true })),
    await measure('postgres.js', 'wide_row', () => sql.unsafe(wideSql(), [], { prepare: true })),
    await measure('postgres.js', 'insert', () => sql`INSERT INTO minato_bench (n, name) VALUES (${1}, ${'a'})`),
    await measure('postgres.js', 'concurrent', () =>
      Promise.all(Array.from({ length: WORKERS }, () => pool`SELECT ${42}::int4`))),
  ];
  await sql.end();
  await pool.end();
  return results;
}

const results = [...(await nodePostgres()), ...(await postgresJs())];
console.log(JSON.stringify(results));
