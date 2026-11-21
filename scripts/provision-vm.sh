#!/usr/bin/env bash
# Set up (or re-apply) one environment's Azure VM. Run by hand from your
# machine; safe to run again. CD never runs this: infrastructure changes are
# made on purpose, deploys only ship app code.
#
#   scripts/provision-vm.sh <uat|prod> [--skip-github]
#
# Connects with your personal SSH alias (UAT / PROD in ~/.ssh/config, or set
# UAT_SSH / PROD_SSH). On the VM, as root, it:
#   - installs Docker (official repo), uv, fail2ban
#   - hardens sshd: keys only, no root login, AllowUsers <you> deploy
#   - creates the 'deploy' user whose key may only run workshop-receive
#   - copies infra/ to /opt/workshop/infra and starts Postgres (127.0.0.1:5432)
# Then, unless --skip-github, it writes the GitHub Environment's secrets
# (SSH_PRIVATE_KEY, DATABASE_URL) and variables (SSH_HOST, SSH_USER,
# SSH_KNOWN_HOSTS). Secrets are piped to gh, never printed.
#
# The deploy key pair is kept at ~/.ssh/workshop-deploy-<env> so re-running
# doesn't rotate it. Delete that file and re-run to rotate.
set -euo pipefail

ENV_NAME="${1:-}"
SKIP_GITHUB=false
[[ "${2:-}" == "--skip-github" ]] && SKIP_GITHUB=true
case "$ENV_NAME" in
  uat)  HOST="${UAT_SSH:-UAT}" ;;
  prod) HOST="${PROD_SSH:-PROD}" ;;
  *) echo "usage: $0 <uat|prod> [--skip-github]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UV_VERSION=0.13.7
KEY="$HOME/.ssh/workshop-deploy-$ENV_NAME"
IP="$(ssh -G "$HOST" 2>/dev/null | awk '$1 == "hostname" {print $2}')"
SSH=(ssh -T -o BatchMode=yes "$HOST")

echo "==> [$ENV_NAME] provisioning $HOST ($IP)"

if [[ ! -f "$KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "workshop-deploy-$ENV_NAME" -f "$KEY"
  echo "==> [$ENV_NAME] created deploy key $KEY"
fi
PUBKEY="$(cat "$KEY.pub")"

echo "==> [$ENV_NAME] copying infra/ and workshop-receive to the VM"
tar -cz -C "$ROOT" infra/docker-compose.yml infra/init "infra/env/$ENV_NAME.env.example" \
    scripts/workshop-receive.sh scripts/vm-setup.sh \
  | "${SSH[@]}" 'rm -rf ~/.workshop-provision && mkdir -p ~/.workshop-provision && tar -xz -C ~/.workshop-provision'

echo "==> [$ENV_NAME] configuring the VM (sudo)"
"${SSH[@]}" "sudo bash \"\$HOME/.workshop-provision/scripts/vm-setup.sh\" $ENV_NAME $UV_VERSION \"\$HOME/.workshop-provision\" \"\$(id -un)\" '$PUBKEY'" </dev/null

echo "==> [$ENV_NAME] checking that admin login still works after sshd changes"
"${SSH[@]}" true

KNOWN_HOSTS="$IP $("${SSH[@]}" 'cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub')"

echo "==> [$ENV_NAME] checking the deploy key (forced command)"
printf '%s\n' "$KNOWN_HOSTS" > "$KEY.known_hosts"
ssh -T -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o UserKnownHostsFile="$KEY.known_hosts" -o StrictHostKeyChecking=yes \
    "deploy@$IP" check

if [[ "$SKIP_GITHUB" == true ]]; then
  echo "==> [$ENV_NAME] skipped GitHub (--skip-github)"
  exit 0
fi

echo "==> [$ENV_NAME] writing GitHub Environment '$ENV_NAME' secrets and variables"
"${SSH[@]}" "sudo cat /opt/workshop/infra/$ENV_NAME.env" \
  | ( set -a; source /dev/stdin; set +a
      printf 'postgresql+psycopg://%s:%s@localhost:%s/%s' \
        "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$PG_PORT" "$POSTGRES_DB" ) \
  | gh secret set DATABASE_URL --env "$ENV_NAME"
gh secret set SSH_PRIVATE_KEY --env "$ENV_NAME" < "$KEY"
gh variable set SSH_HOST --env "$ENV_NAME" --body "$IP"
gh variable set SSH_USER --env "$ENV_NAME" --body deploy
gh variable set SSH_KNOWN_HOSTS --env "$ENV_NAME" --body "$KNOWN_HOSTS"

echo "==> [$ENV_NAME] ready: $HOST ($IP)"
