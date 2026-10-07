#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary="$repo_dir/app/build/linux/x64/release/bundle/money_tracker"
if [ ! -x "$binary" ]; then
  printf '%s\n' 'Build MoneyTracker first: cd app && flutter build linux --release' >&2
  exit 1
fi
if [ -f "$repo_dir/.private/ledger.json" ]; then
  export MONEYTRACKER_LEGACY_DIR="$repo_dir/.private"
fi
exec "$binary" "$@"
