#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
fi

.venv/bin/python -m pip install -r requirements.txt

exec .venv/bin/python -m uvicorn app.main:app \
    --host "${HOST:-0.0.0.0}" \
    --port "${PORT:-8765}" \
    --reload
