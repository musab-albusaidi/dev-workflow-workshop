#!/usr/bin/env bash
# Install one commit's pipeline into one environment's folder.
#
# Runs ON the uat/prod VM, as the deploy user. You don't call it by hand:
# CD runs scripts/ship.sh, which sends the commit's code over SSH to
# /usr/local/bin/workshop-receive on the VM, which calls this script.
#
#   deploy.sh <uat|prod> <source-dir> <commit-sha> [label]
#
# <source-dir> holds that commit's pipeline.py and requirements.txt, plus its
# etl/ package (commits before the module split don't have one)
# (exported with `git archive`, so never anyone's uncommitted edits).
#
# What "deploy" means here (it never touches the database):
#   1. copy the commit's code into app.next/
#   2. install its dependencies into the environment's own venv
#   3. smoke test: run the pipeline in memory (--dry-run) with that venv
#   4. only if the smoke test passes, swap the new code in and write VERSION
# A failed deploy leaves the environment running the previous version.
set -euo pipefail

ENV_NAME="${1:-}"
SRC="${2:-}"
SHA="${3:-}"
LABEL="${4:-$SHA}"
case "$ENV_NAME" in uat|prod) ;; *) echo "usage: $0 <uat|prod> <source-dir> <commit-sha> [label]" >&2; exit 2 ;; esac
[[ -f "$SRC/pipeline.py" && -f "$SRC/requirements.txt" ]] || { echo "no pipeline.py/requirements.txt in '$SRC'" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "commit sha must be 40 hex characters" >&2; exit 2; }

TARGET="${DEPLOY_ROOT:-$HOME/workshop-envs}/$ENV_NAME"
SHORT="${SHA:0:7}"

echo "==> Deploying $SHORT ($LABEL) to $ENV_NAME at $(hostname):$TARGET"
mkdir -p "$TARGET"

echo "==> 1/4 Copy the commit's code"
rm -rf "$TARGET/app.next"
mkdir -p "$TARGET/app.next"
cp "$SRC/pipeline.py" "$SRC/requirements.txt" "$TARGET/app.next/"
[[ -d "$SRC/etl" ]] && cp -r "$SRC/etl" "$TARGET/app.next/"

echo "==> 2/4 Install dependencies"
[[ -x "$TARGET/.venv/bin/python" ]] || uv venv --quiet --python 3.12 "$TARGET/.venv"
uv pip install --quiet --python "$TARGET/.venv/bin/python" -r "$TARGET/app.next/requirements.txt"

echo "==> 3/4 Smoke test (in memory, no database writes)"
( cd "$TARGET/app.next" && ENV="$ENV_NAME" "$TARGET/.venv/bin/python" pipeline.py --dry-run )

echo "==> 4/4 Switch to the new version"
rm -rf "$TARGET/app.prev"
[[ -d "$TARGET/app" ]] && mv "$TARGET/app" "$TARGET/app.prev"
mv "$TARGET/app.next" "$TARGET/app"
{
  echo "$SHORT  $LABEL"
  echo "commit:      $SHA"
  echo "deployed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "deployed_by: ${GITHUB_ACTOR:-$USER}"
  if [[ -n "${RUN_URL:-}" ]]; then
    echo "run:         $RUN_URL"
  fi
} > "$TARGET/VERSION"

echo "==> $ENV_NAME is now on $SHORT"
cat "$TARGET/VERSION"
