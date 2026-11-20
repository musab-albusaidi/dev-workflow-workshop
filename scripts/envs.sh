#!/usr/bin/env bash
# Manage the three simulated environments (dev, uat, prod) on this machine.
#
# Each environment = one Postgres container (its own Compose project, network,
# volume and port) + one deploy folder under ~/workshop-envs/<env>/.
#
#   scripts/envs.sh up              start all three (creates config on first run)
#   scripts/envs.sh down            stop all three (data is kept)
#   scripts/envs.sh status          containers + what version is deployed where
#   scripts/envs.sh url <env>       print the DATABASE_URL for one environment
#   scripts/envs.sh psql <env> ...  open psql inside that environment's database
#   scripts/envs.sh nuke            delete containers, data and deploy folders
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_ROOT="${DEPLOY_ROOT:-$HOME/workshop-envs}"
ENVS=(dev uat prod)

env_file() { echo "$ROOT/infra/env/$1.env"; }

compose() {
  local env="$1"; shift
  docker compose -p "$env" --env-file "$(env_file "$env")" -f "$ROOT/infra/docker-compose.yml" "$@"
}

check_env() {
  case "${1:-}" in dev|uat|prod) ;; *) echo "usage: $0 $2 <dev|uat|prod>" >&2; exit 2 ;; esac
}

ensure_env_file() {
  local env="$1" file; file="$(env_file "$env")"
  if [[ ! -f "$file" ]]; then
    local password; password="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$password/" "$file.example" > "$file"
    chmod 600 "$file"
    echo "[$env] created $file with a random password"
  fi
}

database_url() {
  local env="$1"
  # shellcheck disable=SC1090
  ( source "$(env_file "$env")"
    echo "postgresql+psycopg://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:$PG_PORT/$POSTGRES_DB" )
}

write_deploy_env() {
  local env="$1" dir="$DEPLOY_ROOT/$1"
  mkdir -p "$dir"
  ( umask 077; printf 'ENV=%s\nDATABASE_URL=%s\n' "$env" "$(database_url "$env")" > "$dir/.env" )
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    for env in "${ENVS[@]}"; do
      ensure_env_file "$env"
      compose "$env" up -d --wait
      write_deploy_env "$env"
      echo "[$env] postgres ready on localhost:$(grep ^PG_PORT "$(env_file "$env")" | cut -d= -f2), folder $DEPLOY_ROOT/$env"
    done
    ;;
  down)
    for env in "${ENVS[@]}"; do compose "$env" down; done
    ;;
  status)
    docker ps --filter label=workshop.env --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    for env in "${ENVS[@]}"; do
      printf '%-5s ' "$env"
      if [[ -f "$DEPLOY_ROOT/$env/VERSION" ]]; then head -1 "$DEPLOY_ROOT/$env/VERSION"; else echo "(nothing deployed)"; fi
    done
    ;;
  url)
    check_env "${1:-}" url
    database_url "$1"
    ;;
  psql)
    check_env "${1:-}" psql
    env="$1"; shift
    compose "$env" exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
    ;;
  nuke)
    read -r -p "Delete ALL workshop containers, data and $DEPLOY_ROOT? [y/N] " answer
    [[ "$answer" == "y" ]] || { echo "aborted"; exit 1; }
    for env in "${ENVS[@]}"; do
      [[ -f "$(env_file "$env")" ]] && compose "$env" down -v
      rm -rf "${DEPLOY_ROOT:?}/$env"
    done
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
