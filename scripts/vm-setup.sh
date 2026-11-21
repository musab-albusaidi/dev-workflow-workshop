#!/usr/bin/env bash
# Root half of scripts/provision-vm.sh. It is copied to the VM and run there with sudo:
#
#   sudo bash vm-setup.sh <uat|prod> <uv-version> <unpacked-dir> <admin-user> <deploy-pubkey>
#
# Safe to run again. Never run it on your own machine.
set -euo pipefail
ENV_NAME="$1" UV_VERSION="$2" SRC="$3" ADMIN="$4" PUBKEY="$5"
export DEBIAN_FRONTEND=noninteractive
log() { echo "    [vm] $*"; }

log "packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl fail2ban python3-systemd >/dev/null
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null
if [[ "$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]]; then
  curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" \
    | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh >/dev/null
fi

log "environment marker /etc/workshop/env = $ENV_NAME"
install -d -m 755 /etc/workshop
echo "$ENV_NAME" > /etc/workshop/env

log "deploy user + forced-command key"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
chmod 750 /home/deploy
install -d -o deploy -g deploy -m 700 /home/deploy/.ssh /home/deploy/workshop-envs "/home/deploy/workshop-envs/$ENV_NAME"
install -m 755 "$SRC/scripts/workshop-receive.sh" /usr/local/bin/workshop-receive
echo "command=\"/usr/local/bin/workshop-receive\",restrict $PUBKEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

log "postgres stack in /opt/workshop/infra"
install -d -m 755 /opt/workshop/infra
cp "$SRC/infra/docker-compose.yml" /opt/workshop/infra/
rm -rf /opt/workshop/infra/init && cp -r "$SRC/infra/init" /opt/workshop/infra/init
envfile="/opt/workshop/infra/$ENV_NAME.env"
if [[ ! -f "$envfile" ]]; then
  password="$(openssl rand -hex 16)"
  sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$password/" "$SRC/infra/env/$ENV_NAME.env.example" > "$envfile"
  log "created $envfile with a random password"
fi
chown root:root "$envfile"; chmod 600 "$envfile"
docker compose -p "$ENV_NAME" --env-file "$envfile" -f /opt/workshop/infra/docker-compose.yml up -d --wait --quiet-pull

log "sshd hardening (AllowUsers $ADMIN deploy)"
cat > /etc/ssh/sshd_config.d/10-workshop.conf <<EOF
# Managed by scripts/provision-vm.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $ADMIN deploy
EOF
sshd -t
systemctl try-reload-or-restart ssh

log "fail2ban on sshd"
cat > /etc/fail2ban/jail.d/workshop.local <<'EOF'
# Managed by scripts/provision-vm.sh
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban >/dev/null
systemctl restart fail2ban

rm -rf "$SRC"
log "done"
