#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v uv >/dev/null 2>&1 || { echo '请先安装 uv' >&2; exit 1; }
exec uv sync --project "$PROJECT_DIR" --frozen
