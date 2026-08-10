#!/usr/bin/env bash
# Put asyncpg and psycopg3 in bench/py/.venv, which bench/run.sh picks up.
#
# Debian and Ubuntu ship a python3 whose `venv` cannot bootstrap pip without the
# python3-venv package, so uv is tried first and needs no root.
set -euo pipefail

cd "$(dirname "$0")"

if command -v uv >/dev/null 2>&1; then
    uv venv .venv
    uv pip install --python .venv/bin/python asyncpg 'psycopg[binary]'
else
    python3 -m venv .venv
    .venv/bin/pip install -q --upgrade pip
    .venv/bin/pip install -q asyncpg 'psycopg[binary]'
fi

.venv/bin/python -c 'import asyncpg, psycopg; print("asyncpg", asyncpg.__version__, "psycopg", psycopg.__version__)'
