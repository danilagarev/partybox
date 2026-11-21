#!/usr/bin/env bash
# Explicit live cutover. Run only after prepare-baza.py succeeds and Baza CD is idle.
set -Eeuo pipefail
umask 077
app=${1:-/home/deploy/app}
ingress=${2:-/home/deploy/caddy}
staged=$ingress/staged
helper=$ingress/prepare-baza.py
frontend=ai-tutor-frontend-prod
owner="partybox-ingress-$(date -u +%Y%m%dT%H%M%SZ)-$$"
timeout=${INGRESS_HEALTH_TIMEOUT:-180}
[[ $timeout =~ ^[0-9]+$ && $timeout -ge 1 && $timeout -le 300 ]] || exit 1
[[ $app = /* && $ingress = /* ]] || { echo 'Use absolute paths.' >&2; exit 1; }
[[ $(id -u) = $(stat -Lc %u "$app") ]] || {
  echo 'Run as the Baza repository owner (deploy), not through sudo.' >&2; exit 1;
}
exec 9>"$ingress/ingress.lock"
flock -n 9 || { echo 'Another ingress operation is running.' >&2; exit 1; }
[[ -f $helper && -f $staged/source-sha256.json ]] || { echo 'Run prepare-baza.py first.' >&2; exit 1; }
if docker container inspect caddy >/dev/null 2>&1; then
  echo 'A caddy container already exists; refusing to replace it.' >&2; exit 1
fi
docker volume inspect caddy_data caddy_config >/dev/null
caddy_image=$(docker image inspect caddy:2-alpine --format '{{.Id}}')
frontend_image=$(docker inspect "$frontend" --format '{{.Image}}')
project=$(docker inspect "$frontend" --format '{{ index .Config.Labels "com.docker.compose.project" }}')
[[ $project =~ ^[a-z0-9][a-z0-9_-]*$ ]] || exit 1
git -C "$app" diff --quiet --cached || { echo 'Baza has staged changes; preserve them first.' >&2; exit 1; }
git -C "$app" diff --quiet HEAD -- docker-compose.prod.yml frontend/nginx.prod.conf || {
  echo 'Baza configs have uncommitted changes; preserve them before cutover.' >&2; exit 1;
}
[[ $(git -C "$app" rev-parse HEAD) = $(cat "$staged/base-commit.txt") ]] || {
  echo 'Baza HEAD changed after preparation; prepare again.' >&2; exit 1;
}
[[ -w $(git -C "$app" rev-parse --absolute-git-dir) ]] || { echo 'Git directory is not writable.' >&2; exit 1; }

# Recheck after preflight too: no long validation window may hide a source edit.
verify_sources() {
  [[ $(git -C "$app" rev-parse HEAD) = $(cat "$staged/base-commit.txt") ]] || return 1
python3 - "$app" "$ingress" <<'PY'
import hashlib, importlib.util, json, subprocess, sys
from pathlib import Path
app, ingress = map(Path, sys.argv[1:]); staged = ingress / 'staged'
spec = importlib.util.spec_from_file_location('prepare_baza', ingress / 'prepare-baza.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
hashes = json.loads((staged / 'source-sha256.json').read_text())
expected = {'frontend/nginx.prod.conf', 'docker-compose.prod.yml', 'docker-compose.deploy.yml'}
m.require(set(hashes) == expected, 'Unexpected source manifest')
for name, digest in hashes.items():
    m.require(hashlib.sha256((app / name).read_bytes()).hexdigest() == digest, 'Source changed: ' + name)
networks = json.loads(m.run(['docker', 'network', 'inspect', 'baza_proxy', 'partybox_proxy']))
baza = next(value for value in networks if value['Name'] == 'baza_proxy')
m.require(all(value['Name'] == 'ai-tutor-frontend-prod' for value in baza.get('Containers', {}).values()),
          'baza_proxy has unexpected members')
subnet = next(value['Subnet'] for value in baza['IPAM']['Config'] if ':' not in value['Subnet'])
for name, content in {
    'frontend/nginx.prod.conf': m.nginx_http((app / 'frontend/nginx.prod.conf').read_text(), subnet),
    'docker-compose.prod.yml': m.compose_proxy((app / 'docker-compose.prod.yml').read_text()),
    'Caddyfile': m.CADDYFILE,
}.items():
    m.require((staged / name).read_text() == content, 'Staged file changed: ' + name)
print('Source hashes, staged files and proxy networks: OK', flush=True)
PY

}
verify_sources

# Validate exact images/configs before the interruption begins.
network=$(docker inspect "$frontend" --format '{{range $name, $value := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}')
[[ -n $network && $network != *$'\n'* ]] || { echo 'Unexpected frontend networks.' >&2; exit 1; }
docker run --rm --network "$network" \
  --mount "type=bind,src=$staged/frontend/nginx.prod.conf,dst=/etc/nginx/conf.d/default.conf,readonly" \
  "$frontend_image" nginx -t >"$ingress/nginx-preflight.log" 2>&1
docker run --rm --network none \
  --mount "type=bind,src=$staged/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  "$caddy_image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
  >"$ingress/caddy-preflight.log" 2>&1

docker compose --project-name "$project" --project-directory "$app" --env-file "$app/.env.prod" \
  -f "$staged/docker-compose.prod.yml" -f "$app/docker-compose.deploy.yml" config --quiet
verify_sources
git -C "$app" diff --quiet --cached
mkdir -p "$ingress/backups" "$ingress/conf"
backup=$(mktemp -d "$ingress/backups/cutover.XXXXXXXX")
cp -p "$app/docker-compose.prod.yml" "$backup/docker-compose.prod.yml"
cp -p "$app/docker-compose.deploy.yml" "$backup/docker-compose.deploy.yml"
cp -p "$app/frontend/nginx.prod.conf" "$backup/nginx.prod.conf"
[[ ! -f $ingress/conf/Caddyfile ]] || cp -p "$ingress/conf/Caddyfile" "$backup/Caddyfile"
git -C "$app" rev-parse HEAD > "$backup/base-commit.txt"
printf '{"services":{"frontend":{"image":"%s"}}}\n' "$frontend_image" > "$backup/frontend-image.json"
compose=(docker compose --project-name "$project" --project-directory "$app" --env-file "$app/.env.prod"
  -f "$app/docker-compose.prod.yml" -f "$app/docker-compose.deploy.yml" -f "$backup/frontend-image.json")
recreate() { "${compose[@]}" up -d --no-deps --no-build --pull never --force-recreate --wait --wait-timeout 120 frontend; }
rollback() {
  trap - ERR INT TERM
  set +e
  if [[ $(git -C "$app" rev-parse HEAD) != $(cat "$backup/base-commit.txt") ]]; then
    echo "Git HEAD changed; refusing to overwrite a completed commit/concurrent deployment. Inspect $backup" >&2
    exit 1
  fi
  echo 'Cutover failed. Restoring the original frontend configuration...' >&2
  actual=$(docker inspect caddy --format '{{ index .Config.Labels "partybox.ingress-owner" }}' 2>/dev/null)
  if [[ $actual = "$owner" ]]; then docker rm -f caddy; fi
  cp -p "$backup/docker-compose.prod.yml" "$app/docker-compose.prod.yml"
  cp -p "$backup/nginx.prod.conf" "$app/frontend/nginx.prod.conf"
  git -C "$app" restore --staged -- docker-compose.prod.yml frontend/nginx.prod.conf
  if [[ -f $backup/Caddyfile ]]; then cp -p "$backup/Caddyfile" "$ingress/conf/Caddyfile"; fi
  if recreate; then
    echo "Original frontend restored. Backup: $backup" >&2
  else
    echo "ROLLBACK NEEDS ATTENTION. Original files: $backup" >&2
  fi
  exit 1
}
trap rollback ERR INT TERM

echo "Switching ingress; a brief interruption is expected. Backup: $backup"
cp "$staged/docker-compose.prod.yml" "$app/docker-compose.prod.yml"
cp "$staged/frontend/nginx.prod.conf" "$app/frontend/nginx.prod.conf"
cp -p "$staged/Caddyfile" "$ingress/conf/Caddyfile"
recreate
# Caddy is independent of Compose. Start on Baza's network, then join PartyBox's.
docker run -d --name caddy --label "partybox.ingress-owner=$owner" --restart unless-stopped \
  --network baza_proxy -p 80:80 -p 443:443 -p 443:443/udp \
  --mount "type=bind,src=$ingress/conf,dst=/etc/caddy,readonly" \
  --mount type=volume,src=caddy_data,dst=/data \
  --mount type=volume,src=caddy_config,dst=/config \
  --log-opt max-size=10m --log-opt max-file=3 "$caddy_image"
docker network connect partybox_proxy caddy

echo 'Waiting for the public Sorima certificate and health (up to 3 minutes)...'
deadline=$((SECONDS + timeout))
healthy=0
while (( SECONDS < deadline )); do
  if curl --fail --silent --show-error --max-time 5 --noproxy '*' \
      --resolve sorima.tech:443:127.0.0.1 https://sorima.tech/health \
      > /dev/null 2>"$ingress/health-last-error.log" &&
    curl --fail --silent --show-error --max-time 5 --noproxy '*' \
      --resolve sorima.tech:443:127.0.0.1 https://sorima.tech/ \
      > /dev/null 2>"$ingress/health-last-error.log"; then
    healthy=1; break
  fi
  sleep 2
done
[[ $healthy = 1 ]]
# Keep server HEAD compatible with ingress so the first future Baza CD rollback
# cannot reintroduce the old 80/443 publication. This does not push anything.
git -C "$app" add -- docker-compose.prod.yml frontend/nginx.prod.conf
git -C "$app" -c user.name='VPS ingress migration' -c user.email='deploy@localhost' \
  commit --only -m 'ops: serve Baza behind standalone Docker Caddy' -- docker-compose.prod.yml frontend/nginx.prod.conf
trap - ERR INT TERM
commit=$(git -C "$app" rev-parse HEAD)
branch="ops/caddy-ingress-$owner"
git -C "$app" branch "$branch" "$commit" || echo "Could not create backup branch; preserve commit $commit before further CD." >&2
printf '%s\n' "$commit" > "$backup/ingress-commit.txt"
printf '%s\n' "$backup" > "$ingress/last-cutover-backup"
echo "CADDY LIVE: Sorima root and health passed verified HTTPS."
echo "LOCAL BAZA COMMIT: $commit"
echo "BACKUP: $backup"
echo 'Keep Baza CD idle until this commit is published/merged into master.'
echo 'PartyBox can return 502 until its API has been deployed. No push was performed.'
