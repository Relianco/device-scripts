#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash tests/linux/runner-test.sh
