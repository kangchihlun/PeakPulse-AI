#!/usr/bin/env bash
# Railway entrypoint: run the scanner daemon and the web server in one
# container. If either process exits, stop the other and exit non-zero so
# Railway's restart policy brings the whole service back.
set -euo pipefail

cd /app

DATA_DIR=/app/data_live
PERSISTED_ARTIFACTS="$DATA_DIR/artifacts"

if ! mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo "WARNING: $DATA_DIR is not a mounted volume; history is lost on redeploy." >&2
fi

if [ -z "${DAO_VANG_WEB__ACCESS_PASSWORD:-}" ]; then
  echo "ERROR: DAO_VANG_WEB__ACCESS_PASSWORD is required." >&2
  exit 1
fi

# Keep artifacts (frozen bundles, self-learning state, reports) on the volume.
# Seed bundles shipped with this image without overwriting existing copies.
mkdir -p "$PERSISTED_ARTIFACTS/frozen_models"
for bundle in /app/bundled_models/frozen_models/*/; do
  target="$PERSISTED_ARTIFACTS/frozen_models/$(basename "$bundle")"
  if [ ! -e "$target" ]; then
    cp -R "$bundle" "$target"
  fi
done
rm -rf /app/artifacts
ln -s "$PERSISTED_ARTIFACTS" /app/artifacts

dao-vang scanner start --config "$DAO_VANG_CONFIG_PATH" &
scanner_pid=$!

python -c "import os; from dao_vang.web.api_server import run_server; run_server(port=int(os.environ.get('PORT', '8000')))" &
web_pid=$!

shutdown() {
  kill -TERM "$scanner_pid" "$web_pid" 2>/dev/null || true
  wait "$scanner_pid" "$web_pid" 2>/dev/null || true
}
trap shutdown TERM INT

set +e
wait -n "$scanner_pid" "$web_pid"
status=$?
set -e

echo "A process exited with status $status; shutting down container." >&2
shutdown
exit "${status:-1}"
