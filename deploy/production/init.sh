#!/usr/bin/env bash
set -euo pipefail
umask 077
root=${1:-/opt/partybox}
[[ $root = /* && $root =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Use an absolute directory without spaces.' >&2; exit 1; }
[[ $(id -u) != 0 ]] || { echo 'Run as the dedicated non-root deploy user.' >&2; exit 1; }
mkdir -p "$root/secrets" "$root/releases"
chmod 700 "$root" "$root/secrets" "$root/releases"
for name in database_password room_token_secret; do
  if [[ ! -e $root/secrets/$name ]]; then
    # noclobber also protects against a concurrent initializer.
    (set -o noclobber; openssl rand -hex 32 > "$root/secrets/$name")
  fi
  [[ -s $root/secrets/$name && ! -L $root/secrets/$name ]] || exit 1
  chmod 600 "$root/secrets/$name"
done
if [[ ! -e $root/.env ]]; then
  (set -o noclobber; printf 'PARTYBOX_UID=%s\nPARTYBOX_GID=%s\nPARTYBOX_PROXY_NETWORK=partybox_proxy\n' "$(id -u)" "$(id -g)" > "$root/.env")
fi
chmod 600 "$root/.env"
echo "Initialized $root; existing secrets preserved."
