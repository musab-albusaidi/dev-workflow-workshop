#!/usr/bin/env bash
# Send one commit to one VM. Runs in CD, on a GitHub-hosted runner.
#
#   scripts/ship.sh <uat|prod> <commit-sha> [label]
#
# Builds a bundle of the commit's pipeline.py + requirements.txt (+ etl/), this
# checkout's scripts/deploy.sh and the environment's DATABASE_URL, and pipes
# it over SSH to the deploy user on the VM. The deploy key can only run
# /usr/local/bin/workshop-receive there (a forced command), which installs it.
#
# deploy.sh comes from the checkout CD runs from (main), not from <commit-sha>,
# so rolling back to an old tag still uses today's deploy tooling.
#
# Reads from the GitHub Environment:
#   secrets:   SSH_PRIVATE_KEY, DATABASE_URL
#   variables: SSH_HOST, SSH_USER, SSH_KNOWN_HOSTS
set -euo pipefail

ENV_NAME="${1:-}"
SHA="${2:-}"
LABEL="${3:-$SHA}"
case "$ENV_NAME" in uat|prod) ;; *) echo "usage: $0 <uat|prod> <commit-sha> [label]" >&2; exit 2 ;; esac
for var in SSH_PRIVATE_KEY DATABASE_URL SSH_HOST SSH_USER SSH_KNOWN_HOSTS; do
  [[ -n "${!var:-}" ]] || { echo "$var is not set for the $ENV_NAME environment" >&2; exit 2; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA="$(git -C "$ROOT" rev-parse --verify "$SHA^{commit}")"
ACTOR="${GITHUB_ACTOR:-$USER}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local/local}/actions/runs/${GITHUB_RUN_ID:-0}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bundle/scripts"

# The etl/ package only exists from the module split onwards; older tags
# (rollbacks) are a single pipeline.py, and git archive fails on missing paths.
app_paths=(pipeline.py requirements.txt)
if git -C "$ROOT" cat-file -e "$SHA:etl" 2>/dev/null; then app_paths+=(etl); fi
git -C "$ROOT" archive "$SHA" "${app_paths[@]}" | tar -x -C "$work/bundle"
cp "$ROOT/scripts/deploy.sh" "$work/bundle/scripts/deploy.sh"
( umask 077; printf 'DATABASE_URL=%s\n' "$DATABASE_URL" > "$work/bundle/dotenv" )

( umask 077
  printf '%s\n' "$SSH_PRIVATE_KEY" > "$work/key"
  printf '%s\n' "$SSH_KNOWN_HOSTS" > "$work/known_hosts" )

ssh_opts=(
  -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes
  -o UserKnownHostsFile="$work/known_hosts" -o StrictHostKeyChecking=yes
  -o ConnectTimeout=20 -T
)

echo "==> Shipping ${SHA:0:7} ($LABEL) to $ENV_NAME ($SSH_HOST)"
tar -cz -C "$work/bundle" . \
  | ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "deploy $SHA $LABEL $ACTOR $RUN_URL"
