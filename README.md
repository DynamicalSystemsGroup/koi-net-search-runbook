# KOI-net Local Network (Quickstart)

This repo orchestrates a 7-node KOI-net stack locally.

For full operational detail, advanced setup, and troubleshooting, see [RUNBOOK.md](RUNBOOK.md).

## What This Does

- Clones all node repos
- Initializes `.env` files
- Syncs Python envs (`uv`)
- Starts/stops all nodes in protocol-safe order
- Auto-propagates coordinator contact and search target RIDs
- Runs end-to-end search queries

## Zero to Hero (Copy/Paste)

Run from this repo root.

### 1) Bootstrap

```bash
make bootstrap
```

### 2) Set shared node key password

```bash
make set-shared-password PASSWORD='replace-with-strong-secret'
```

### 3) Configure GitHub sensor

```bash
make configure-github \
  GITHUB_API_TOKEN='ghp_...' \
  GITHUB_REPOSITORIES='owner/repo,owner/repo'
```

### 4) Configure HackMD sensor

```bash
make configure-hackmd \
  HACKMD_API_TOKEN='your-hackmd-token' \
  HACKMD_NOTE_IDS='note-id-1,note-id-2'
```

Optional for HackMD:

```bash
# add workspace scoping if needed
make configure-hackmd \
  HACKMD_API_TOKEN='your-hackmd-token' \
  HACKMD_WORKSPACE_ID='workspace-id' \
  HACKMD_NOTE_IDS='note-id-1,note-id-2'
```

### 5) Validate envs

```bash
make env-check
```

### 6) Start network

```bash
make up
```

### 7) Verify all nodes are up

```bash
make status
```

### 8) Run a query

```bash
make query \
  Q='koi network architecture' \
  TYPE=hybrid \
  TOP_K=10
```

### 9) Stop network

```bash
make down
```

## Common Commands

```bash
make help
make logs
make restart
make query-tail UUID='<query-uuid>'
```

## Full Documentation

- Full setup + token guidance + troubleshooting: [RUNBOOK.md](RUNBOOK.md)
