#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <env-file> <key> <value>" >&2
  exit 1
fi

env_file="$1"
key="$2"
value="$3"

if [ ! -f "$env_file" ]; then
  echo "Env file not found: $env_file" >&2
  exit 1
fi

tmp_file="$(mktemp)"

awk -v key="$key" -v value="$value" '
BEGIN {
  done = 0
}
{
  if ($0 ~ "^[[:space:]]*" key "=") {
    print key "=" value
    done = 1
  } else {
    print
  }
}
END {
  if (!done) {
    print key "=" value
  }
}
' "$env_file" > "$tmp_file"

mv "$tmp_file" "$env_file"
