#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash tests/linux/runner-test.sh
bash tests/linux/tailscale-test.sh
bash tests/linux/runner-args-test.sh
