#!/usr/bin/env bash
set -euo pipefail

QUERY=""
TYPE="hybrid"
TOP_K="10"
TEXT_WEIGHT="1.0"
VECTOR_WEIGHT="0.5"
SIMILARITY_THRESHOLD="0.0"
TIMEOUT_SECONDS="45"
QUERY_DIR="queries"
RESULT_DIR="results"
GENERAL_REPO="koi-net-general-search-node"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)
      QUERY="${2:-}"
      shift 2
      ;;
    --type)
      TYPE="${2:-}"
      shift 2
      ;;
    --top-k)
      TOP_K="${2:-}"
      shift 2
      ;;
    --text-weight)
      TEXT_WEIGHT="${2:-}"
      shift 2
      ;;
    --vector-weight)
      VECTOR_WEIGHT="${2:-}"
      shift 2
      ;;
    --similarity-threshold)
      SIMILARITY_THRESHOLD="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --query-dir)
      QUERY_DIR="${2:-}"
      shift 2
      ;;
    --result-dir)
      RESULT_DIR="${2:-}"
      shift 2
      ;;
    --repo-dir)
      GENERAL_REPO="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 --query "text" [options]

Options:
  --type <text|vector|hybrid>      Default: hybrid
  --top-k <int>                    Default: 10
  --text-weight <float>            Default: 1.0
  --vector-weight <float>          Default: 0.5
  --similarity-threshold <float>   Default: 0.0
  --timeout <seconds>              Default: 45
  --query-dir <dir>                Default: queries
  --result-dir <dir>               Default: results
  --repo-dir <path>                Default: koi-net-general-search-node
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Missing required --query argument" >&2
  exit 1
fi

if [[ ! -d "$GENERAL_REPO" ]]; then
  echo "General search repo not found: $GENERAL_REPO" >&2
  exit 1
fi

query_output="$(
  cd "$GENERAL_REPO" && \
  uv run python bin/query.py "$QUERY" \
    --type "$TYPE" \
    --top-k "$TOP_K" \
    --text-weight "$TEXT_WEIGHT" \
    --vector-weight "$VECTOR_WEIGHT" \
    --similarity-threshold "$SIMILARITY_THRESHOLD" \
    --output-dir "$QUERY_DIR"
)"

echo "$query_output"

query_uuid="$(printf '%s\n' "$query_output" | awk -F': ' '/^Query UUID:/ {print $2}')"
if [[ -z "$query_uuid" ]]; then
  echo "Failed to parse query UUID from query generator output" >&2
  exit 1
fi

result_file="$GENERAL_REPO/$RESULT_DIR/$query_uuid.json"
deadline=$((SECONDS + TIMEOUT_SECONDS))

echo "Waiting up to ${TIMEOUT_SECONDS}s for result file: $result_file"
while [[ $SECONDS -lt $deadline ]]; do
  if [[ -f "$result_file" ]]; then
    echo "Result ready: $result_file"
    echo "-----"
    cat "$result_file"
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for result file: $result_file" >&2
exit 1
