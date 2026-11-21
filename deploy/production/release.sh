#!/usr/bin/env bash
set -euo pipefail
umask 077
bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$bundle/../.." && pwd)
image=${1:?Usage: release.sh ghcr.io/owner/package@sha256:digest}
[[ $image =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]] || { echo 'An immutable GHCR digest is required.' >&2; exit 1; }
exec 9>"$root/deploy.lock"
flock -w 300 9
export BACKEND_IMAGE=$image
# Registry authentication belongs to this deployment, not a neighbouring app.
[[ ! -f $root/docker-auth/config.json ]] || export DOCKER_CONFIG="$root/docker-auth"
project=${PARTYBOX_PROJECT_NAME:-partybox_prod}
compose() { docker compose --project-name "$project" --env-file "$root/.env" -f "$bundle/compose.yaml" "$@"; }
previous=''
[[ ! -f $root/current-image ]] || previous=$(cat "$root/current-image")
if [[ -n $previous && ! $previous =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo 'Invalid previous image record; refusing deployment.' >&2; exit 1
fi
compose config --quiet
compose pull postgres migrate partybox-api
compose up -d --wait --wait-timeout 120 postgres
# Migrations must remain backward compatible with the running previous image.
compose run --rm --no-deps migrate
rollback() {
  echo 'Deployment failed; restoring previous backend image.' >&2
  if [[ -n $previous ]]; then
    export BACKEND_IMAGE=$previous
    compose up -d --no-deps --wait --wait-timeout 120 partybox-api || { echo 'Rollback failed; inspect backend and database.' >&2; return 1; }
  else
    compose stop partybox-api || true
    echo 'First deployment failed; no previous image. Database preserved.' >&2
  fi
}
# Compose waits for the image HEALTHCHECK (/ready, including database query).
if ! compose up -d --no-deps --wait --wait-timeout 120 partybox-api; then
  rollback
  exit 1
fi
if [[ -n $previous ]]; then printf '%s\n' "$previous" > "$root/previous-image.tmp"; mv "$root/previous-image.tmp" "$root/previous-image"; fi
printf '%s\n' "$image" > "$root/current-image.tmp"
mv "$root/current-image.tmp" "$root/current-image"
echo 'Backend is ready; release recorded.'
