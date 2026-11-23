#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export UV_CACHE_DIR=${UV_CACHE_DIR:-$repo_root/.tools/uv-cache}
export UV_TOOL_DIR=${UV_TOOL_DIR:-$repo_root/.tools/uv-tools}
export UV_TOOL_BIN_DIR=${UV_TOOL_BIN_DIR:-$repo_root/.tools/uv-bin}
export SERENA_HOME=${SERENA_HOME:-$repo_root/.tools/serena}
cd "$repo_root"
exec uv tool run --from serena-agent==2.1.0 serena "$@"
