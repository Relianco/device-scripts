#!/bin/bash
# NinjaOne layer for the Linux wazuh package. Paste this file into NinjaOne and run it as root instead of
# linux/runner/relian-runner.sh for linux/packages/wazuh/wazuh.sh.
#
#   --runner-url     raw URL of linux/runner/relian-runner.sh at a pinned commit
#   --runner-sha256  SHA256 of that file, lowercase. Empty exits 0 and does nothing.
#   --wazuh-manager  manager host name; the package checks its characters
#   every other argument (--package-url, --package-sha256, --action, --pin-version) goes to the runner as is
#
# It reads the organization fields wazuhGroup and wazuhRegistrationPassword (type Secure, script read)
# with ninjarmm-cli. An empty wazuhGroup means the organization is not on Wazuh: exit 0 before the
# password is read or anything is downloaded. A set group with an empty password exits 1.
# The password goes into a root-only 0600 file in a 0700 directory. The runner's child (the package)
# gets WazuhPasswordFile, WazuhManager, WazuhGroup (default,<wazuhGroup>) and WazuhNamePrefix (wazuhGroup
# without a trailing _group) from the environment. The password is never on a command line and never
# printed; the file is removed when the runner returns. The runner and the package call no NinjaOne.
# No trace output: a trace would print the password.
{ set +x; } 2>/dev/null

RWE_CLI='/opt/NinjaRMMAgent/programdata/ninjarmm-cli'

rwe_error() { printf '%s\n' "$1" >&2; }
rwe_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Seams. Tests replace them.
rwe_get_field() { "$RWE_CLI" get "$1"; }
# curl retries timeouts and HTTP 408, 429, 500, 502, 503 and 504, as the runner does.
rwe_fetch() { curl --fail --silent --show-error --retry 2 --retry-delay 5 --max-time 120 --output "$2" -- "$1"; }
rwe_run_runner() { bash -- "$@"; }

rwe_main() {
  local runner_url='' runner_sha='' manager='' forward=() i
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runner-url|--runner-sha256|--wazuh-manager)
        [[ $# -ge 2 ]] || { rwe_error "missing value for $1"; return 1; }
        case "$1" in
          --runner-url) runner_url="$2" ;;
          --runner-sha256) runner_sha="$2" ;;
          --wazuh-manager) manager="$2" ;;
        esac
        shift 2
        ;;
      *) forward+=("$1"); shift ;;
    esac
  done
  if [[ "$runner_url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@ ]]; then
    rwe_error 'refusing a URL that contains userinfo'; return 1
  fi
  # An empty hash is the off switch, as in the runner: exit 0 before anything is read or downloaded.
  [[ -n "$(rwe_trim "$runner_sha")" ]] || return 0
  for ((i = 0; i + 1 < ${#forward[@]}; i++)); do
    if [[ "${forward[$i]}" == '--package-sha256' && -z "$(rwe_trim "${forward[$((i + 1))]}")" ]]; then
      return 0
    fi
  done
  [[ "$runner_sha" =~ ^[0-9a-f]{64}$ ]] || { rwe_error '--runner-sha256 must be 64 lowercase hex characters'; return 1; }
  [[ -n "$runner_url" ]] || { rwe_error '--runner-url is required'; return 1; }
  manager="$(rwe_trim "$manager")"
  [[ -n "$manager" ]] || { rwe_error '--wazuh-manager is required'; return 1; }

  # Errors name the field only: the CLI's output could carry the value.
  local group password
  group="$(rwe_get_field wazuhGroup 2>/dev/null)" || { rwe_error 'could not read wazuhGroup'; return 1; }
  group="$(rwe_trim "$group")"
  if [[ -z "$group" ]]; then
    printf 'wazuhGroup is empty: this organization is not on Wazuh\n'
    return 0
  fi
  # Command substitution drops the CLI's trailing newline; edge spaces stay part of the password.
  password="$(rwe_get_field wazuhRegistrationPassword 2>/dev/null)" || { rwe_error 'could not read wazuhRegistrationPassword'; return 1; }
  [[ -n "$(rwe_trim "$password")" ]] || { rwe_error 'wazuhRegistrationPassword is empty'; return 1; }

  local work code=0
  work="$(mktemp -d)" || { rwe_error 'could not create a work directory'; return 1; }
  # printf is a builtin: the password is not on any process command line.
  if ! (umask 077 && printf '%s' "$password" > "$work/authd.pass"); then
    rm -rf -- "$work"; rwe_error 'could not write the password file'; return 1
  fi
  password=''
  if ! rwe_fetch "$runner_url" "$work/runner.sh"; then
    rm -rf -- "$work"; rwe_error 'runner download failed'; return 1
  fi
  local actual
  actual="$(sha256sum -- "$work/runner.sh")"
  if [[ "${actual%%[[:space:]]*}" != "$runner_sha" ]]; then
    rm -rf -- "$work"; rwe_error 'hash mismatch for runner'; return 1
  fi
  (
    export WazuhManager="$manager" WazuhGroup="default,$group" WazuhNamePrefix="${group%_group}" WazuhPasswordFile="$work/authd.pass"
    rwe_run_runner "$work/runner.sh" "${forward[@]}"
  ) || code=$?
  rm -rf -- "$work"
  return "$code"
}

# Sourcing defines the functions and does nothing else.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -uo pipefail
code=0
rwe_main "$@" || code=$?
exit "$code"
