#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash tests/macos/runner-test.sh
