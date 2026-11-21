#!/usr/bin/env bash
# Operate the three environments from your machine.
#
#   dev       = this project folder + a local Postgres container (localhost:5433)
#   uat, prod = one Azure VM each, reached with your SSH aliases UAT / PROD
#               (override with UAT_SSH / PROD_SSH)
#
#   scripts/envs.sh up              start the local dev database (creates config on first run)
#   scripts/envs.sh down            stop the local dev database (data is kept)
#   scripts/envs.sh status          dev container + what is deployed on uat and prod
#   scripts/envs.sh url dev         print the dev DATABASE_URL
#   scripts/envs.sh psql <env> ...  open psql in that environment's database
#   scripts/envs.sh run <env>       run the pipeline in that environment, on purpose
#   scripts/envs.sh nuke            delete the dev container and its data
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_INFRA=/opt/workshop/infra
VM_ENVS=/home/deploy/workshop-envs

dev_env_file() { echo "$ROOT/infra/env/dev.env"; }

dev_compose() {
  docker compose -p dev --env-file "$(dev_env_file)" -f "$ROOT/infra/docker-compose.yml" "$@"
}

vm_host() {
  case "$1" in
    uat)  echo "${UAT_SSH:-UAT}" ;;
    prod) echo "${PROD_SSH:-PROD}" ;;
  esac
}

check_env() {
  case "${1:-}" in dev|uat|prod) ;; *) echo "usage: $0 $2 <dev|uat|prod>" >&2; exit 2 ;; esac
}

ensure_dev_env_file() {
  local file; file="$(dev_env_file)"
  if [[ ! -f "$file" ]]; then
    local password; password="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$password/" "$file.example" > "$file"
    chmod 600 "$file"
    echo "[dev] created $file with a random password"
  fi
}

dev_database_url() {
  # shellcheck disable=SC1090
  ( source "$(dev_env_file)"
    echo "postgresql+psycopg://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:$PG_PORT/$POSTGRES_DB" )
}

# Run a command on a VM; arguments are quoted so they survive the remote shell.
on_vm() {
  local env="$1"; shift
  local tty=-T; [[ -t 0 && -t 1 ]] && tty=-t
  ssh "$tty" "$(vm_host "$env")" "$(printf '%q ' "$@")"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    ensure_dev_env_file
    dev_compose up -d --wait
    echo "[dev] postgres ready on localhost:$(grep ^PG_PORT "$(dev_env_file)" | cut -d= -f2)"
    ;;
  down)
    dev_compose down
    ;;
  status)
    echo "== dev (local)"
    docker ps --filter label=workshop.env=dev --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo "code: $(git -C "$ROOT" rev-parse --short HEAD) on $(git -C "$ROOT" branch --show-current) (your working copy)"
    for env in uat prod; do
      echo
      echo "== $env ($(vm_host "$env"))"
      if ! on_vm "$env" bash -c "
          sudo docker ps --filter label=workshop.env=$env --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
          printf 'code: '
          sudo head -1 $VM_ENVS/$env/VERSION 2>/dev/null || echo '(nothing deployed)'" 2>&1; then
        echo "(unreachable)"
      fi
    done
    ;;
  url)
    [[ "${1:-}" == dev ]] || { echo "only the dev URL is printed here; uat/prod's live on the VM and in GitHub secrets" >&2; exit 2; }
    dev_database_url
    ;;
  psql)
    check_env "${1:-}" psql
    env="$1"; shift
    if [[ "$env" == dev ]]; then
      dev_compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
    else
      exec_tty=-T; [[ -t 0 && -t 1 ]] && exec_tty=
      on_vm "$env" sudo docker compose -p "$env" --env-file "$VM_INFRA/$env.env" \
        -f "$VM_INFRA/docker-compose.yml" exec $exec_tty postgres \
        sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
    fi
    ;;
  run)
    check_env "${1:-}" run
    env="$1"
    if [[ "$env" == dev ]]; then
      cd "$ROOT"
      ENV=dev DATABASE_URL="$(dev_database_url)" .venv/bin/python pipeline.py
    else
      on_vm "$env" sudo -u deploy -H bash -c "cd $VM_ENVS/$env/app && ../.venv/bin/python pipeline.py"
    fi
    ;;
  nuke)
    read -r -p "Delete the local dev container and its data? (uat/prod VMs are not touched) [y/N] " answer
    [[ "$answer" == "y" ]] || { echo "aborted"; exit 1; }
    [[ -f "$(dev_env_file)" ]] && dev_compose down -v
    ;;
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
