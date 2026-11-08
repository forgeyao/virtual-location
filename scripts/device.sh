#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -x "$PROJECT_DIR/.venv/bin/python" ]; then
    echo '请先运行 sh scripts/setup.sh' >&2
    exit 1
fi
export PYTHONPATH="$PROJECT_DIR/backend${PYTHONPATH:+:$PYTHONPATH}"
exec "$PROJECT_DIR/.venv/bin/python" -m virtual_location.cli "$@"
