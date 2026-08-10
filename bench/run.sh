#!/usr/bin/env bash
# Run every client benchmark and print one table.
#
#   docker compose -f test/docker-compose.yml up -d
#   bench/run.sh [iterations]
#
# The Erlang clients always run. The JavaScript ones run when bench/js has been
# installed, the Python ones when their drivers are importable; each says so
# rather than being silently missing.
set -euo pipefail

cd "$(dirname "$0")/.."
ITERATIONS="${1:-${MINATO_BENCH_ITERATIONS:-2000}}"
export MINATO_BENCH_ITERATIONS="$ITERATIONS"

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

echo "building the Erlang clients"
rebar3 as bench compile >/dev/null

echo "running erlang: minato, pgo, epgsql"
erl -noshell \
    -pa _build/bench/lib/*/ebin _build/bench/lib/minato/bench \
    -eval 'io:format("~s~n", [minato_bench:json(minato_bench:run(minato_bench:iterations([])))]), init:stop().' \
    | tail -1 > "$RESULTS"

if [ -d bench/js/node_modules ]; then
    echo "running javascript: node-postgres, postgres.js"
    node bench/js/bench.mjs | tail -1 >> "$RESULTS"
else
    echo "skipping javascript: run 'cd bench/js && npm install' first"
fi

PYTHON=python3
[ -x bench/py/.venv/bin/python ] && PYTHON=bench/py/.venv/bin/python

if "$PYTHON" -c 'import asyncpg, psycopg' 2>/dev/null; then
    echo "running python: asyncpg, psycopg3"
    "$PYTHON" bench/py/bench.py | tail -1 >> "$RESULTS"
else
    echo "skipping python: run 'bench/py/install.sh' first"
fi

node bench/report.mjs "$RESULTS" "$ITERATIONS"
