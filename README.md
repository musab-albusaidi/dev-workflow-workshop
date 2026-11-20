# Developer Workflow Workshop: dev → uat → prod

A ~90-minute live demo for the data engineering team, covering:

- why we keep **separate environments** (dev, uat, prod) with an identical stack;
- how **one commit** is promoted from dev to uat to prod, and never rebuilt along the way;
- **git branching**, **pull requests**, **CI/CD** and **testing** for data pipelines.

Everything runs for free on one laptop (WSL + Docker Engine + GitHub Actions).

---

## What's in the repo

| Path | What it is |
|---|---|
| `pipeline.py` | The whole pipeline: `bronze()` → `silver()` → `gold()` |
| `tests/test_pipeline.py` | Unit, data quality and integration tests |
| `infra/docker-compose.yml` | **One** stack definition (Postgres 17), started three times |
| `infra/env/*.env.example` | Per-environment config (port, user, db). Real `.env` files are gitignored |
| `scripts/envs.sh` | Start, stop and inspect the three environments |
| `scripts/deploy.sh` | Deploy one commit to one environment |
| `.github/workflows/ci.yml` | CI: lint, unit tests and integration tests on every PR |
| `.github/workflows/cd.yml` | CD: dev (auto) → uat (approval) → prod (approval) → release tag |

### The pipeline

| Layer | Function | Output table | What it does |
|---|---|---|---|
| Bronze | `bronze()` | `bronze.orders_raw` (20 rows) | Lands the raw orders **as received**: every value a string, mess included |
| Silver | `silver()` | `silver.orders` (13 rows) | Trims and normalises text, casts types, drops invalid rows, **deduplicates on `order_id`**, adds `revenue` |
| Gold | `gold()` | `gold.sales_by_country_month`, `gold.customer_summary` | Business-ready tables. Only *completed* orders count as revenue |

On every run, `check_quality()` enforces these rules: no duplicate orders, no nulls in key columns, no negative revenue, no empty gold tables, and both gold tables must agree on total revenue (**5,197.50**).

### The simulated environments

At work each environment is its own VM. Here, each one is a Docker Compose *project* (its own container, network and volume) plus a deploy folder:

| Env | Postgres | Deploy folder | Promotion |
|---|---|---|---|
| dev | `localhost:5433` | `~/workshop-envs/dev/` | automatic on merge to `main` |
| uat | `localhost:5434` | `~/workshop-envs/uat/` | manual approval |
| prod | `localhost:5435` | `~/workshop-envs/prod/` | manual approval, then tagged `vX.Y.0` |

```
~/workshop-envs/uat/
├── app/        the deployed pipeline.py + requirements.txt
├── app.prev/   the previous version (kept after a deploy)
├── .venv/      this environment's own Python packages
├── .env        ENV + DATABASE_URL (written by CD from a GitHub Environment secret)
└── VERSION     which commit is deployed, when, by whom, from which CI run
```

**Deploying and running are separate steps.** A deploy puts the code in place and runs an in-memory smoke test (`--dry-run`). It never touches the database. Running the pipeline against an environment's database is something an operator does on purpose.

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

You also need [`uv`](https://docs.astral.sh/uv/) and the `gh` CLI. WSL needs `systemd=true` in `/etc/wsl.conf`. All three environments together use about 300 MB of RAM.

### 2. Local Python environment

```bash
uv venv --python 3.12 && uv pip install -r requirements-dev.txt
.venv/bin/pytest -m "not integration"     # 10 tests, about 2 seconds
```

### 3. Start the three environments

```bash
scripts/envs.sh up        # creates infra/env/<env>.env with random passwords on first run
scripts/envs.sh status
```

### 4. GitHub: repo, environments, secrets, branch protection

- **Environments**: `dev` has no protection. `uat` and `prod` each have a required reviewer. All three are limited to the `main` branch.
- **Environment secret**: each environment gets its own `DATABASE_URL` (`scripts/envs.sh url <env>`). The same workflow code picks up a different secret depending on which environment it deploys to.
- **Branch protection on `main`**: a PR is required, and the checks `lint`, `unit` and `integration` must pass. No approvals are required, because with one presenter GitHub won't let you approve your own PR. In a real team you'd require one or more.
- **Actions → General → Fork pull request workflows**: require approval for all outside collaborators.

### 5. Self-hosted runner (the CD "agent" on the workshop machine)

Go to **Settings → Actions → Runners → New self-hosted runner → Linux** and follow the download and `config.sh` commands shown there. When asked for labels, enter `workshop`. Then, in a terminal you keep visible during the demo:

```bash
cd ~/actions-runner && ./run.sh
```

> **Security:** this runner only executes the `CD` workflow. That workflow only starts when CI passes for a push to `main` in this repo, or when someone with write access dispatches it by hand. It never runs for pull requests or forks.

---

## Demo script (~90 min)

> Before you start: `scripts/envs.sh status` shows all three environments healthy. Run `rm -rf ~/workshop-envs/*/app* ~/workshop-envs/*/VERSION` for a clean slate (this keeps each `.env` and `.venv`). Have the [architecture diagram](#architecture-diagram) and the runner terminal open.

### 1. Why separate environments? (10 min)

- Show `infra/docker-compose.yml`: **one** definition of the stack.
- Show `docker ps`: three containers built from it, on three ports, with three volumes.
- Show `infra/env/*.env.example`: the **only** differences are config. The code is identical.
- Lesson: if it works in uat, it works in prod, *because* they are the same stack.

### 2. Branching model (10 min)

- Trunk-based: short-lived `feature/*` branches, PRs into `main`, and `main` is always deployable.
- Promotion moves **the same commit** through the environments. Nothing is rebuilt along the way, so you never re-merge.
- Contrast: *branch per environment* (`dev`/`uat`/`main` branches). The branches drift apart, and the commit you tested isn't the commit you ship.

### 3. A feature, end to end (25 min)

```bash
git switch -c feature/aov-by-customer
# e.g. add avg_order_value to gold.customer_summary in pipeline.py, plus a test
.venv/bin/pytest -m "not integration"
git commit -am "Add average order value per customer" && git push -u origin HEAD
gh pr create --fill
```

1. On the PR, CI runs the three checks: lint, unit, integration. While they're red or pending, **Merge** is blocked.
2. Merge the PR. **CD** starts: `deploy-dev` runs immediately and `deploy-uat` shows *Waiting for review*.
3. Show the environment folders side by side:
   ```bash
   scripts/envs.sh status       # dev is on the new commit, uat/prod are not
   ```
4. Approve **uat** and watch the runner terminal pick up the job. `scripts/envs.sh status` now shows dev and uat on the same SHA.
5. Run the pipeline in uat on purpose, then compare:
   ```bash
   cd ~/workshop-envs/uat/app && ../.venv/bin/python pipeline.py && cd -
   scripts/envs.sh psql uat  -c 'select * from gold.customer_summary'
   scripts/envs.sh psql prod -c 'select * from gold.customer_summary'   # prod: old shape (or no tables yet)
   ```

### 4. Promote to prod and release (10 min)

- Approve **prod**. The `release` job tags the commit (`v1.0.0`, then `v1.1.0`, …) and creates a GitHub Release.
- `cat ~/workshop-envs/prod/VERSION` answers "what's in prod?": commit, time, who approved it, and a link to the run.

### 5. CI catching a data bug (15 min)

```bash
gh pr create --base main --head demo/broken-silver --title "Speed up silver" --body "Removes a slow step"
```

- The branch removes **one line**: the dedup on `order_id`. The code still runs.
- CI goes **red**: the unit tests show silver with 16 rows instead of 13 and total revenue of **7,648.50** instead of **5,197.50**. The business report would have overstated revenue by 47%.
- Lesson: the tests asserted *exact business numbers*, so CI stopped a wrong number from reaching UAT, not just a crash. Even if the tests were missing, `check_quality()` would fail the run, and so would the deploy smoke test.
- Close the PR without merging.

### 6. Rollback (5 min)

- **Actions → CD → Run workflow → ref = `v1.0.0`**. It goes through the same gates (dev → uat → prod), and no new tag is created.
- Show that `VERSION` in each environment now points to the old commit, and `app.prev/` holds what was replaced.

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
                     CD (self-hosted runner, same commit)    ▼
              dev :5433 ──approve──▶ uat :5434 ──approve──▶ prod :5435 ──▶ tag vX.Y.0
```

## Useful commands

```bash
scripts/envs.sh status                 # containers + what's deployed where
scripts/envs.sh psql prod -c '\dt gold.*'
scripts/deploy.sh dev                  # deploy your current HEAD to dev by hand
DATABASE_URL="$(scripts/envs.sh url dev)" .venv/bin/pytest -m integration   # never point this at prod
scripts/envs.sh down                   # stop everything, keep data
scripts/envs.sh nuke                   # delete containers, data and ~/workshop-envs
```
