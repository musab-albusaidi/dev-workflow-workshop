#!/usr/bin/env bash
# Deploy one commit of this repo to one environment.
#
#   scripts/deploy.sh <dev|uat|prod> [git-ref] [label]   (ref defaults to HEAD;
#                                                     label, e.g. v1.0.0, defaults to ref)
#
# What "deploy" means here (it never touches the database):
#   1. export exactly that commit's pipeline code (not your uncommitted edits)
#   2. install its dependencies into the environment's own venv
#   3. smoke test: run the pipeline in memory (--dry-run) with that venv
#   4. only if the smoke test passes, swap the new code in and write VERSION
# A failed deploy leaves the environment running the previous version.
set -euo pipefail

ENV_NAME="${1:-}"
REF="${2:-HEAD}"
LABEL="${3:-$REF}"
case "$ENV_NAME" in dev|uat|prod) ;; *) echo "usage: $0 <dev|uat|prod> [git-ref] [label]" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${DEPLOY_ROOT:-$HOME/workshop-envs}/$ENV_NAME"
SHA="$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")"
SHORT="${SHA:0:7}"

echo "==> Deploying $SHORT ($LABEL) to $ENV_NAME at $TARGET"
mkdir -p "$TARGET"

echo "==> 1/4 Export code from the commit"
rm -rf "$TARGET/app.next"
mkdir -p "$TARGET/app.next"
git -C "$ROOT" archive "$SHA" pipeline.py requirements.txt | tar -x -C "$TARGET/app.next"

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
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "run:         $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  fi
} > "$TARGET/VERSION"

echo "==> $ENV_NAME is now on $SHORT"
cat "$TARGET/VERSION"
