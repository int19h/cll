#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Install Node.js 22 or later."); process.exit(1); }'
tools_dir=$(readlink -m build/weasyprint-tools)
mkdir -p "$tools_dir"
export PIP_CACHE_DIR="$tools_dir/pip-cache"
python3 -m venv "$tools_dir/venv"
"$tools_dir/venv/bin/pip" install -r scripts/weasyprint/requirements.txt
cp scripts/weasyprint/package.json scripts/weasyprint/package-lock.json "$tools_dir/"
npm ci --prefix "$tools_dir" --cache "$tools_dir/npm-cache" --no-audit --no-fund
