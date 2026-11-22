#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
flutter_bin=${FLUTTER_BIN:-$repo_dir/.fvm/flutter_sdk/bin/flutter}
web_output="$repo_dir/output/web-release"
cd -- "$repo_dir/apps/mobile"
"$flutter_bin" build web --release --no-web-resources-cdn --pwa-strategy=none \
  --dart-define=ROOM_SERVER_URL=same-origin --dart-define=BROWSER_ROOMS=true \
  --output="$web_output"
cd -- "$repo_dir"
node scripts/stage-web.mjs "$web_output" "$repo_dir/deploy/web"
