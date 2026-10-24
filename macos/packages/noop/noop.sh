#!/bin/bash
# No-op package. It installs nothing.

set -euo pipefail

deployment=""
action=""
pin=""
seen_deployment=0
seen_action=0
seen_pin=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-type)
      if [[ $# -lt 2 ]]; then
        exit 1
      fi
      deployment="$2"
      seen_deployment=1
      shift 2
      ;;
    --action)
      if [[ $# -lt 2 ]]; then
        exit 1
      fi
      action="$2"
      seen_action=1
      shift 2
      ;;
    --pin-version)
      if [[ $# -lt 2 ]]; then
        exit 1
      fi
      pin="$2"
      seen_pin=1
      shift 2
      ;;
    *)
      exit 1
      ;;
  esac
done

if [[ "$seen_deployment" -ne 1 || "$seen_action" -ne 1 || "$seen_pin" -ne 1 ]]; then
  exit 1
fi

case "$action" in
  Install|Update|Repair|Reinstall|Uninstall) ;;
  *)
    exit 1
    ;;
esac

if [[ -n "${RELIAN_PACKAGE_LOG:-}" ]]; then
  printf 'deployment=%s action=%s pin=%s\n' "$deployment" "$action" "$pin" >> "$RELIAN_PACKAGE_LOG"
fi

exit 0
