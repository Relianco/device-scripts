#!/usr/bin/env bash
# Scan this branch with the committed betterleaks policy.
# Default range: commits not on origin/main (then deploy-runner, then teams-package).
# Pass "history" to scan every commit reachable from HEAD.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v betterleaks >/dev/null 2>&1; then
  echo "betterleaks is not installed. CI still runs the scan."
  echo "install: https://github.com/betterleaks/betterleaks/releases"
  exit 1
fi

if [ "${1:-}" = "history" ]; then
  betterleaks git . -c .betterleaks.toml --no-banner --redact
  exit $?
fi

baseline=""
for candidate in origin/main origin/deploy-runner origin/teams-package; do
  if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
    baseline="$candidate"
    break
  fi
done
if [ -z "$baseline" ]; then
  echo "No baseline ref. Pass nothing after fetching origin, or pass history."
  exit 1
fi

range="$(git merge-base "$baseline" HEAD)..HEAD"
if [ -z "$(git rev-list -n1 "$range" 2>/dev/null || true)" ]; then
  echo "No new commits versus ${baseline}."
  exit 0
fi
echo "Scanning ${range} (baseline ${baseline})"
betterleaks git . -c .betterleaks.toml --no-banner --redact --log-opts="$range"
