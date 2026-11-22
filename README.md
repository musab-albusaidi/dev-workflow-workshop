# Developer Workflow Workshop: dev → uat → prod

A ~90-minute live demo for the data engineering team, covering:

- why we keep **separate environments** (dev, uat, prod) with an identical stack;
- how **one commit** is promoted from dev to uat to prod, and never rebuilt along the way;
- **git branching**, **pull requests**, **CI/CD** and **testing** for data pipelines.

dev runs on your laptop (WSL + Docker Engine). uat and prod are two Azure VMs, deployed by GitHub Actions over SSH.

---

## What's in the repo

| Path | What it is |
|---|---|
| `pipeline.py` | Entry point: runs `bronze()` → `silver()` → `gold()` → `check_quality()`, then writes to Postgres |
| `etl/` | One module per stage: `source.py` (raw data), `config.py`, `bronze.py`, `silver.py`, `gold.py`, `quality.py`, `load.py` |
| `tests/test_pipeline.py` | Unit, data quality and integration tests |
| `infra/docker-compose.yml` | **One** stack definition (Postgres 17), used by dev, uat and prod |
| `infra/env/*.env.example` | Per-environment config (port, user, db). Real `.env` files are gitignored or live only on the VM |
| `scripts/envs.sh` | Operate the environments: local dev database, plus uat/prod over SSH |
| `scripts/provision-vm.sh` | Set up a uat/prod VM by hand (Docker, Postgres, `deploy` user, sshd hardening, GitHub secrets) |
| `scripts/vm-setup.sh` | The root half of provisioning, copied to and run on the VM |
| `scripts/ship.sh` | CD: send one commit to one VM over SSH |
| `scripts/workshop-receive.sh` | On the VM: the only command the deploy key can run |
| `scripts/deploy.sh` | On the VM: install the commit, smoke test it, swap it in, write `VERSION` |
| `.github/workflows/ci.yml` | CI: lint, unit tests and integration tests on every PR |
| `.github/workflows/cd.yml` | CD: uat (auto) → prod (approval) → release tag |

### The pipeline

| Layer | Function | Output table | What it does |
|---|---|---|---|
| Bronze | `etl/bronze.py` → `bronze()` | `bronze.orders_raw` (20 rows) | Lands the raw orders **as received**: every value a string, mess included |
| Silver | `etl/silver.py` → `silver()` | `silver.orders` (13 rows) | Trims and normalises text, casts types, drops invalid rows, **deduplicates on `order_id`**, adds `revenue` |
| Gold | `etl/gold.py` → `gold()` | `gold.sales_by_country_month`, `gold.customer_summary` | Business-ready tables. Only *completed* orders count as revenue |

On every run, `check_quality()` (`etl/quality.py`) enforces these rules: no duplicate orders, no nulls in key columns, no negative revenue, no empty gold tables, and both gold tables must agree on total revenue (**5,197.50**).

### The environments

| Env | Where | Postgres | Code | Promotion |
|---|---|---|---|---|
| dev | your laptop | `localhost:5433` (Docker) | this project folder, your working copy | none: you run it yourself |
| uat | Azure VM `UAT` | `127.0.0.1:5432` on the VM (Docker) | `/home/deploy/workshop-envs/uat/` | automatic on merge to `main` |
| prod | Azure VM `PROD` | `127.0.0.1:5432` on the VM (Docker) | `/home/deploy/workshop-envs/prod/` | manual approval, then tagged `vX.Y.0` |

dev is never deployed. CI is the shared check that a change works, and uat is the first deployed environment. Each VM runs the **same** `infra/docker-compose.yml`, so uat and prod only differ in config.

```
UAT / PROD VM
├── /opt/workshop/infra/            docker-compose.yml, init/, <env>.env (root only, mode 600)
└── /home/deploy/workshop-envs/<env>/
    ├── app/        the deployed pipeline.py + etl/ + requirements.txt
    ├── app.prev/   the previous version (kept after a deploy)
    ├── .venv/      this environment's own Python packages
    ├── .env        ENV + DATABASE_URL (sent by CD from a GitHub Environment secret)
    └── VERSION     which commit (and tag, e.g. v1.0.0) is deployed, when, by whom, from which CI run
```

**How a deploy reaches a VM.** CD runs on a GitHub-hosted runner. `scripts/ship.sh` bundles the commit's `pipeline.py`, `etl/` and `requirements.txt`, today's `scripts/deploy.sh` and the environment's `DATABASE_URL`, then pipes the bundle over SSH to the `deploy` user. That user's key is a *forced command* (`command="/usr/local/bin/workshop-receive",restrict`), so it can't open a shell or forward ports. It can only hand over a bundle, which `deploy.sh` then installs.

**Deploying and running are separate steps.** A deploy puts the code in place and runs an in-memory smoke test (`--dry-run`). It never touches the database. Running the pipeline against an environment's database is something an operator does on purpose (`scripts/envs.sh run <env>`).

---

## One-time setup

### 1. Docker Engine inside WSL (free, no Docker Desktop licence needed)

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"   # then restart the WSL shell
```

You also need [`uv`](https://docs.astral.sh/uv/) and the `gh` CLI. WSL needs `systemd=true` in `/etc/wsl.conf`.

### 2. Local Python environment and dev database

```bash
uv venv --python 3.12 && uv pip install -r requirements-dev.txt
.venv/bin/pytest -m "not integration"     # 10 tests, about 2 seconds
scripts/envs.sh up                        # local dev Postgres; creates infra/env/dev.env with a random password
scripts/envs.sh run dev                   # run the pipeline from this folder against it
```

### 3. The uat and prod VMs (Azure)

Each VM: Ubuntu, a **static** public IP, and an SSH alias in `~/.ssh/config` using your personal key:

```
Host UAT
    HostName <uat public ip>
    User azureuser
    IdentityFile ~/.ssh/UAT_key.pem
    IdentitiesOnly yes
```

(the same for `PROD`). The VM's network security group allows inbound TCP 22 from **any** source, because GitHub-hosted runners connect from changing IPs. sshd is key-only and fail2ban is on. Postgres is never exposed. Then, from this folder:

```bash
scripts/provision-vm.sh uat
scripts/provision-vm.sh prod
```

This is safe to rerun. It installs Docker, uv and fail2ban, hardens sshd (no passwords, no root, `AllowUsers <you> deploy`), creates the `deploy` user with a forced-command key, starts Postgres from `infra/`, and writes the GitHub Environment's secrets and variables (below). The deploy key pair stays at `~/.ssh/workshop-deploy-<env>`; delete it and rerun to rotate. Rerun it after changing anything in `infra/`: CD only ships app code.

### 4. GitHub: environments, secrets, branch protection

- **Environments**: `uat` has no reviewer, so it deploys on every merge. `prod` has a required reviewer. Both are limited to the `main` branch. There's no `dev` environment.
- **Per-environment config** (written by `provision-vm.sh`). Secrets: `DATABASE_URL`, `SSH_PRIVATE_KEY`. Variables: `SSH_HOST`, `SSH_USER` (`deploy`), `SSH_KNOWN_HOSTS` (the VM's pinned host key). The same workflow code picks up different values depending on which environment it deploys to, and uat's key can't reach prod.
- **Branch protection on `main`**: a PR is required, and the checks `lint`, `unit` and `integration` must pass. No approvals are required, because with one presenter GitHub won't let you approve your own PR. In a real team you'd require one or more.
- **Actions → General → Fork pull request workflows**: require approval for all outside collaborators.
- **No self-hosted runners**: every job runs on GitHub-hosted machines, which matters for a public repo.

---

## Demo script (~90 min)

> Before you start: `scripts/envs.sh status` shows dev healthy and both VMs reachable. Have the [architecture diagram](#architecture-diagram) and the Actions tab open.

### 1. Why separate environments? (10 min)

- Show `infra/docker-compose.yml`: **one** definition of the stack.
- Show `scripts/envs.sh status`: the same stack running on your laptop (dev) and on two VMs (uat, prod).
- Show `infra/env/*.env.example`: the **only** differences are config. The code is identical.
- Lesson: if it works in uat, it works in prod, *because* they are the same stack.

### 2. Branching model (10 min)

- Trunk-based: short-lived `feature/*` branches, PRs into `main`, and `main` is always deployable.
- Promotion moves **the same commit** through the environments. Nothing is rebuilt along the way, so you never re-merge.
- Contrast: *branch per environment* (`dev`/`uat`/`main` branches). The branches drift apart, and the commit you tested isn't the commit you ship.

### 3. A feature, end to end (25 min)

```bash
git switch -c feature/aov-by-customer
# e.g. add avg_order_value to gold.customer_summary in etl/gold.py, plus a test
.venv/bin/pytest -m "not integration"
git commit -am "Add average order value per customer" && git push -u origin HEAD
gh pr create --fill
```

1. On the PR, CI runs the three checks: lint, unit, integration. While they're red or pending, **Merge** is blocked.
2. Merge the PR. **CD** starts: `deploy-uat` ships the commit to the uat VM straight away, and `deploy-prod` shows *Waiting for review*.
3. Show what's deployed where:
   ```bash
   scripts/envs.sh status       # uat is on the new commit, prod is not
   ```
4. Run the pipeline in uat on purpose, then compare:
   ```bash
   scripts/envs.sh run uat
   scripts/envs.sh psql uat  -c 'select * from gold.customer_summary'
   scripts/envs.sh psql prod -c 'select * from gold.customer_summary'   # prod: old shape (or no tables yet)
   ```

### 4. Promote to prod and release (10 min)

- Approve **prod**. The `release` job tags the commit (`v1.0.0`, then `v1.1.0`, …) and creates a GitHub Release.
- `scripts/envs.sh status` (it reads `VERSION` on each VM) answers "what's in prod?": commit, time, who triggered it, and a link to the run.

### 5. CI catching a data bug (15 min)

```bash
gh pr create --base main --head demo/broken-silver --title "Speed up silver" --body "Removes a slow step"
```

- The branch removes **one line**: the dedup on `order_id`. The code still runs.
- CI goes **red**: the unit tests show silver with 16 rows instead of 13 and total revenue of **7,648.50** instead of **5,197.50**. The business report would have overstated revenue by 47%.
- Lesson: the tests asserted *exact business numbers*, so CI stopped a wrong number from reaching UAT, not just a crash. Even if the tests were missing, `check_quality()` would fail the run, and so would the deploy smoke test.
- Close the PR without merging.

### 6. Rollback (5 min)

- **Actions → CD → Run workflow → ref = `v1.0.0`**. It goes through the same gates (uat → prod approval), and no new tag is created. The old tag's app code is shipped with today's deploy tooling.
- Show that `scripts/envs.sh status` now shows the old commit on both VMs, and that `app.prev/` holds what was replaced.

### 7. Testing recap (5 min)

| Kind | Where | Question it answers | Speed |
|---|---|---|---|
| Unit | `pytest -m "not integration"` | Is each function's logic right? | milliseconds |
| Data quality | `check_quality()`, every run, every env | Is *this* data right? | milliseconds |
| Integration | CI job with a throwaway Postgres | Does the whole pipeline work for real? | seconds |
| Smoke | `deploy.sh` → `--dry-run` | Does the deployed code run in *this* environment? | seconds |

---

## Architecture diagram

See the published diagram page (link in the workshop invite), or the summary below:

```
feature/* ──PR──▶ CI (lint · unit · integration) ──merge──▶ main
                                                             │
                  CD (GitHub-hosted, SSH, same commit)       ▼
   dev = your laptop        uat VM ──approve──▶ prod VM ──▶ tag vX.Y.0
   (not deployed)          (auto)
```

## Useful commands

```bash
scripts/envs.sh status                 # dev container + what's deployed on uat and prod
scripts/envs.sh psql prod -c '\dt gold.*'
scripts/envs.sh run dev                # run the pipeline from this folder against the dev database
scripts/envs.sh run uat                # run the deployed pipeline on the uat VM, on purpose
DATABASE_URL="$(scripts/envs.sh url dev)" .venv/bin/pytest -m integration   # never point this at prod
scripts/provision-vm.sh uat            # re-apply VM setup after changing infra/
scripts/envs.sh down                   # stop the dev database, keep data
scripts/envs.sh nuke                   # delete the dev container and its data (VMs untouched)
```
