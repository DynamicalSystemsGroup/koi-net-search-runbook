# KOI-net Local Network Runbook

This repository is a network orchestrator for a 7-node KOI-net stack.

It automates:
- cloning all node repos
- initializing `.env` files
- syncing Python environments (`uv`)
- starting/stopping the full network in protocol-safe order
- propagating coordinator contact (`COORDINATOR_RID`, `COORDINATOR_URL`) to node `.env` files
- propagating search target RIDs (`TEXT_SEARCH_NODE_RID`, `VECTOR_SEARCH_NODE_RID`) into general-search `.env`
- running end-to-end queries via the general search node

## Network Topology

| Node | Repo | Port | Purpose |
|---|---|---:|---|
| coordinator | `koi-net-coordinator-node` | 8080 | network registry + routing anchor |
| hackmd sensor | `koi-net-hackmd-sensor-node` | 8081 | ingests HackMD notes |
| github sensor | `koi-net-github-sensor-node` | 8082 | ingests GitHub repos |
| text normalizer | `koi-net-text-normalizer-node` | 8083 | transforms source objects into `orn:normalized.text` |
| text search | `koi-net-text-search-node` | 8084 | full-text index/query backend |
| vector search | `koi-net-vector-search-node` | 8085 | embedding + vector index/query backend |
| general search | `koi-net-general-search-node` | 8086 | orchestrates hybrid search and writes query results |

## Prerequisites

- Python `>=3.10`
- [`uv`](https://docs.astral.sh/uv/)
- `git`
- `lsof` (used by status/stop checks)

## Access Tokens and Data Access Prerequisites

### GitHub (`GITHUB_API_TOKEN`)

Your GitHub sensor calls:
- `GET /repos/{owner}/{repo}` (repo metadata)
- `GET /repos/{owner}/{repo}/readme` (README content)

So token requirements are:
- Public repos only: token is optional, but strongly recommended.
  - GitHub allows unauthenticated access for public resources.
  - Unauthenticated rate limit is low (`60 requests/hour` per IP).
- Private repos: token is required.

Recommended token type:
- Fine-grained PAT (preferred by GitHub).

Minimum repository permissions for this sensor:
- `Metadata: Read` (for repo metadata endpoint)
- `Contents: Read` (for README endpoint)

Where to create it:
- GitHub token settings UI: <https://github.com/settings/tokens>
- GitHub docs: <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens>

Quick creation path:
1. GitHub profile -> **Settings**
2. **Developer settings** -> **Personal access tokens** -> **Fine-grained tokens**
3. **Generate new token**
4. Select resource owner and repositories
5. Grant `Metadata: Read` and `Contents: Read`
6. Copy token and store it in `GITHUB_API_TOKEN`

Notes:
- Org policies may require token approval. Pending tokens may only read public resources until approved.

### HackMD (`HACKMD_API_TOKEN`)

For this stack, HackMD token is required in practice.

Why:
- Your HackMD sensor always authenticates with `Authorization: Bearer <token>`.
- HackMD OpenAPI docs mark the note/team/user endpoints with token security.
- The ingestion flow uses account/team endpoints (`/notes`, `/teams/{teampath}/notes`) rather than anonymous public note URLs.

Where to create it:
- HackMD API settings: <https://hackmd.io/settings#api>
- HackMD guide: <https://hackmd.io/@docs/issue-revoke-api-token-en>
- HackMD API auth doc: <https://hackmd.io/@hackmd-api/api-authorization>

Quick creation path:
1. HackMD -> **My account** -> **Settings**
2. **API** -> **Create API token**
3. Name token, create it, copy once, and store in `HACKMD_API_TOKEN`

HackMD API limits (documented as beta limits):
- `2000` calls/month
- `100` calls per 5 minutes

### Public vs private summary

| Source | Public data without token | Private data without token |
|---|---|---|
| GitHub | Yes (limited rate) | No |
| HackMD (this sensor/API flow) | Effectively no | No |

## 1) Bootstrap from Scratch

From this repo root:

```bash
make bootstrap
```

This runs:
- `make clone` (idempotent)
- `make env-init` (`.env.example` -> `.env`, idempotent)
- `make sync` (`uv sync --refresh --reinstall` in each node repo)

If repos are already present, `clone` skips them.

## 2) Configure Secrets and Sensor Inputs

### 2.1 Set one shared node key password everywhere

```bash
make set-shared-password PASSWORD='replace-with-strong-secret'
```

### 2.2 Configure GitHub sensor (token + repo list)

```bash
make configure-github \
  GITHUB_API_TOKEN='ghp_...' \
  GITHUB_REPOSITORIES='BlockScience/rid-lib,sayertindall/koi-net-demo'
```

### 2.3 Configure HackMD sensor (token + optional workspace/note filters)

```bash
make configure-hackmd \
  HACKMD_API_TOKEN='your-hackmd-token' \
  HACKMD_WORKSPACE_ID='workspace-id' \
  HACKMD_NOTE_IDS='note-id-1,note-id-2'
```

`HACKMD_WORKSPACE_ID` and `HACKMD_NOTE_IDS` are optional, but at least a token is required.

### 2.4 Validate env files exist

```bash
make env-check
```

### 2.5 General Search target RID behavior

General search is RID-driven for downstream targets:
- `TEXT_SEARCH_NODE_RID`
- `VECTOR_SEARCH_NODE_RID`

You do **not** need to set these manually during normal startup.

`make up` now handles this in-order:
1. start text search (8084)
2. start vector search (8085)
3. read their generated RIDs from their `config.yaml`
4. write those values into `koi-net-general-search-node/.env`
5. start general search (8086)

Manual sync command (if needed):

```bash
make sync-search-target-rids
```

## 3) Start the Network

```bash
make up
```

`make up` starts nodes in this exact order:
1. coordinator
2. hackmd sensor
3. github sensor
4. text normalizer
5. text search
6. vector search
7. general search

It writes logs to `./logs/*.log` and pid files to `./.pids/*.pid`.

`make up` also runs `make sync-coordinator-contact` after coordinator starts, which copies:
- `COORDINATOR_RID`
- `COORDINATOR_URL`

into all non-coordinator node `.env` files.

`make up` also runs `make sync-search-target-rids` after text/vector start, which copies:
- `TEXT_SEARCH_NODE_RID`
- `VECTOR_SEARCH_NODE_RID`

into `koi-net-general-search-node/.env` before general-search starts.

Verify listeners:

```bash
make status
```

## 4) Seed Content into Sensors

Sensors ingest from their configured env inputs:
- GitHub repos from `GITHUB_REPOSITORIES`
- HackMD scope from `HACKMD_WORKSPACE_ID` and/or `HACKMD_NOTE_IDS`

After changing sensor env values, restart network (or node):

```bash
make restart
```

Single-node foreground runs are available:

```bash
make coordinator
make hackmd
make github
make normalizer
make text
make vector
make general
```

## 5) Verify Ingestion -> Normalization -> Indexing

Tail logs:

```bash
make logs
```

Key signals to look for:
- normalizer log:
  - `normalized-hackmd ...`
  - `normalized-github ...`
- text search log:
  - `Indexed normalized doc ...`
- vector search log:
  - `Embedded ... -> orn:vector:...`
  - index upsert/search events

## 6) Run Search Queries (General Search Node)

### 6.1 One-command query

```bash
make query \
  Q='koi network architecture' \
  TYPE=hybrid \
  TOP_K=10 \
  TEXT_WEIGHT=1.0 \
  VECTOR_WEIGHT=0.5 \
  SIMILARITY_THRESHOLD=0.0 \
  TIMEOUT=45
```

This:
1. creates a query file via `koi-net-general-search-node/bin/query.py`
2. waits for result materialization
3. prints result JSON

Result files are written to:
- `koi-net-general-search-node/results/<uuid>.json`

Processed query files move to:
- `koi-net-general-search-node/processed/`

### 6.2 Print a known result file

```bash
make query-tail UUID='<query-uuid>'
```

## 7) Operations

Stop all nodes:

```bash
make down
```

Restart all nodes:

```bash
make restart
```

Check listeners only:

```bash
make ports
```

Remove all `uv.lock` files:

```bash
make lock
```

Deep clean node repos (virtualenvs, caches, logs, etc.):

```bash
make clean
```

## 8) Scripts (`scripts/`)

This repo uses two helper scripts. They are called by Make targets, but you can run them directly.

### `scripts/set_env_var.sh`

Purpose:
- Upsert a key in a `.env` file.
- If key exists, replace value.
- If key does not exist, append `KEY=value` at end of file.

Exact usage:

```bash
./scripts/set_env_var.sh <env-file> <key> <value>
```

Examples:

```bash
./scripts/set_env_var.sh koi-net-github-sensor-node/.env GITHUB_API_TOKEN 'ghp_xxx'
./scripts/set_env_var.sh koi-net-general-search-node/.env TEXT_SEARCH_NODE_RID 'orn:koi-net.node:text_search+...'
```

Used by:
- `make set-shared-password`
- `make configure-github`
- `make configure-hackmd`
- `make sync-coordinator-contact`
- `make sync-search-target-rids`

### `scripts/run_query.sh`

Purpose:
- Submit a query through `koi-net-general-search-node/bin/query.py`
- Parse `Query UUID` from script output
- Wait for `results/<uuid>.json`
- Print result JSON (or timeout)

Exact usage:

```bash
./scripts/run_query.sh --query "text" [options]
```

Options:
- `--type <text|vector|hybrid>` default `hybrid`
- `--top-k <int>` default `10`
- `--text-weight <float>` default `1.0`
- `--vector-weight <float>` default `0.5`
- `--similarity-threshold <float>` default `0.0`
- `--timeout <seconds>` default `45`
- `--query-dir <dir>` default `queries`
- `--result-dir <dir>` default `results`
- `--repo-dir <path>` default `koi-net-general-search-node`

Examples:

```bash
./scripts/run_query.sh --query "koi network architecture"
./scripts/run_query.sh --query "embedding pipeline" --type hybrid --top-k 20 --timeout 90
```

Used by:
- `make query`

## Troubleshooting

### `UnknownNodeError` / peer cannot resolve node
- Cause: handshake/routing not settled yet.
- Fix:
  1. `make down`
  2. `make up`

### General query times out, text/vector get no messages
- Cause: `koi-net-general-search-node` is dispatching to wrong `TEXT_SEARCH_NODE_RID` / `VECTOR_SEARCH_NODE_RID`.
- Fix:
  1. `make sync-search-target-rids`
  2. `make restart`
  3. wait for startup stabilization and edge approval events in logs

### Ports missing on `make status`
- Cause: crashed node or startup failed.
- Fix:
  1. inspect `logs/<node>.log`
  2. run affected node in foreground with `make <node>`

### No search results
- Verify sensors are configured with real data sources:
  - GitHub repos list non-empty
  - HackMD token valid and scope configured
- Verify normalization/indexing logs are present before querying.

### Query times out
- Increase timeout:

```bash
make query Q='...' TIMEOUT=90
```

## Command Summary

```bash
make help
```
