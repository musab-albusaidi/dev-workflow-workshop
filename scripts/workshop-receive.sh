#!/usr/bin/env bash
# The ONLY thing the deploy key can run on a uat/prod VM.
#
# Installed by scripts/provision-vm.sh as /usr/local/bin/workshop-receive and
# set as a forced command in /home/deploy/.ssh/authorized_keys:
#
#   command="/usr/local/bin/workshop-receive",restrict ssh-ed25519 AAAA...
#
# so whatever the SSH client asks for, sshd runs this script instead and puts
# the request in SSH_ORIGINAL_COMMAND. Two requests are accepted:
#
#   check                                     print which environment this is
#   deploy <sha> <label> <actor> <run-url>    stdin = .tar.gz bundle from scripts/ship.sh
#
# The bundle holds pipeline.py, requirements.txt, scripts/deploy.sh and a
# "dotenv" file with DATABASE_URL. The environment name is never taken from
# the client: it comes from /etc/workshop/env, written at provisioning time.
set -euo pipefail
umask 077

die() { echo "workshop-receive: $*" >&2; exit 1; }

ENV_NAME="$(cat /etc/workshop/env)"
ROOT="$HOME/workshop-envs"

read -r verb sha label actor run_url extra <<< "${SSH_ORIGINAL_COMMAND:-}" || true

case "${verb:-}" in
  check)
    [[ -z "${sha:-}" ]] || die "check takes no arguments"
    echo "ok: this is $ENV_NAME ($(hostname))"
    exit 0
    ;;
  deploy) ;;
  *) die "only 'check' and 'deploy' are allowed" ;;
esac

[[ -z "${extra:-}" ]]                                                || die "too many arguments"
[[ "${sha:-}" =~ ^[0-9a-f]{40}$ ]]                                   || die "bad commit sha"
[[ "${label:-}" =~ ^[A-Za-z0-9._/-]{1,100}$ ]]                       || die "bad label"
[[ "${actor:-}" =~ ^[A-Za-z0-9-]{1,39}(\[bot\])?$ ]]                 || die "bad actor"
[[ "${run_url:-}" =~ ^https://github\.com/[A-Za-z0-9._/-]+/actions/runs/[0-9]+$ ]] || die "bad run url"

mkdir -p "$ROOT/$ENV_NAME"
stage="$(mktemp -d "$ROOT/.incoming.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# At most 20 MB; GNU tar refuses absolute paths and '..' in member names.
head -c 20000000 | tar -xz -C "$stage" --no-same-owner --no-same-permissions

for f in pipeline.py requirements.txt scripts/deploy.sh dotenv; do
  [[ -f "$stage/$f" && ! -L "$stage/$f" ]] || die "bundle is missing $f"
done

url="$(sed -n 's/^DATABASE_URL=//p' "$stage/dotenv" | head -1)"
[[ -n "$url" ]] || die "bundle has no DATABASE_URL"
printf 'ENV=%s\nDATABASE_URL=%s\n' "$ENV_NAME" "$url" > "$ROOT/$ENV_NAME/.env.next"
mv "$ROOT/$ENV_NAME/.env.next" "$ROOT/$ENV_NAME/.env"
rm -f "$stage/dotenv"

GITHUB_ACTOR="$actor" RUN_URL="$run_url" \
  bash "$stage/scripts/deploy.sh" "$ENV_NAME" "$stage" "$sha" "$label"
