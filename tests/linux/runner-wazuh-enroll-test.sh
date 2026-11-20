#!/bin/bash
# NinjaOne layer for the Linux wazuh package: linux/collectors/runner-wazuh-enroll.sh. Every NinjaOne,
# network and runner call is replaced; nothing is downloaded, installed or enrolled.
# shellcheck disable=SC2317,SC2016
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$ROOT/linux/collectors/runner-wazuh-enroll.sh"

FAILURES=0
LABEL=""
fail() { printf 'FAIL %s\n' "${LABEL:+$LABEL: }$*" >&2; FAILURES=$((FAILURES + 1)); }
begin() { LABEL="$1"; }

# shellcheck disable=SC1090
source "$WRAPPER"

# Built at runtime so no password is committed. Edge spaces must survive.
CORE="pw-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
SECRET=" $CORE "
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
RUNNER_BODY='# fake runner'
RUNNER_SHA="$(printf '%s' "$RUNNER_BODY" | sha256sum | cut -d' ' -f1)"
FORWARD=(--package-url https://example.invalid/wazuh.sh --package-sha256 "$(printf 'ab%.0s' {1..32})" --action Install --pin-version 4.14.3)

# Fakes. State lives in files so it survives the subshell each case runs in.
rwe_get_field() {
  printf '%s\n' "$1" >> "$WORK/reads"
  if [[ "$1" == "$(cat "$WORK/field_fails" 2>/dev/null)" ]]; then printf 'cli said %s\n' "$SECRET"; return 1; fi
  case "$1" in
    wazuhGroup) cat "$WORK/group" ;;
    wazuhRegistrationPassword) cat "$WORK/password" ;;
    *) return 1 ;;
  esac
}
rwe_fetch() { printf 'fetch\n' >> "$WORK/calls"; printf '%s' "$RUNNER_BODY" > "$2"; }
rwe_run_runner() {
  printf 'run\n' >> "$WORK/calls"
  shift
  printf '%s\n' "$@" > "$WORK/args"
  {
    printf 'manager=%s\n' "${WazuhManager-unset}"
    printf 'group=%s\n' "${WazuhGroup-unset}"
    printf 'prefix=%s\n' "${WazuhNamePrefix-unset}"
    printf 'mode=%s\n' "$(stat -c '%a' -- "$WazuhPasswordFile")"
    printf 'dirmode=%s\n' "$(stat -c '%a' -- "$(dirname -- "$WazuhPasswordFile")")"
  } > "$WORK/env"
  printf '%s' "$WazuhPasswordFile" > "$WORK/passpath"
  cp -- "$WazuhPasswordFile" "$WORK/passcopy"
  return "$(cat "$WORK/runner_code")"
}

reset_case() {
  rm -f -- "$WORK/reads" "$WORK/calls" "$WORK/args" "$WORK/env" "$WORK/passpath" "$WORK/passcopy" "$WORK/field_fails"
  printf '%s' "${1-tenant_group}" > "$WORK/group"
  printf '%s' "${2-$SECRET}" > "$WORK/password"
  printf '%s' "${3:-0}" > "$WORK/runner_code"
}
run_case() {
  LAST_CODE=0
  LAST_OUT="$( (rwe_main "$@") 2>&1)" || LAST_CODE=$?
  [[ "$LAST_OUT" != *"$CORE"* ]] || fail 'output leaked the password'
  if [[ -f "$WORK/args" ]] && grep -qF -- "$CORE" "$WORK/args"; then fail 'the password reached the runner command line'; fi
  if [[ -f "$WORK/passpath" && -e "$(cat "$WORK/passpath")" ]]; then fail 'the password file was left behind'; fi
}
calls() { tr '\n' ',' 2>/dev/null < "$WORK/calls"; }
reads() { tr '\n' ',' 2>/dev/null < "$WORK/reads"; }
GOOD=(--runner-url https://example.invalid/relian-runner.sh --runner-sha256 "$RUNNER_SHA" --wazuh-manager manager.example.invalid)

begin 'happy path'
reset_case
run_case "${GOOD[@]}" "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'fetch,run,' ]] || fail "code $LAST_CODE calls $(calls) out [$LAST_OUT]"
[[ "$(cat "$WORK/args" 2>/dev/null)" == "$(printf '%s\n' "${FORWARD[@]}")" ]] || fail 'forwarded args differ'
[[ "$(cat "$WORK/env" 2>/dev/null)" == "$(printf 'manager=manager.example.invalid\ngroup=default,tenant_group\nprefix=tenant\nmode=600\ndirmode=700')" ]] || fail "runner env was [$(cat "$WORK/env" 2>/dev/null)]"
cmp -s -- "$WORK/passcopy" <(printf '%s' "$SECRET") || fail 'password file is not the password verbatim'
[[ -z "${WazuhPasswordFile-}" && -z "${WazuhManager-}" ]] || fail 'variables leaked into the caller'

begin 'runner code is returned'
reset_case tenant_group "$SECRET" 5
run_case "${GOOD[@]}" "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 5 ]] || fail "code $LAST_CODE"

begin 'prefix drops only a trailing _group'
reset_case my_group_x
run_case "${GOOD[@]}" "${FORWARD[@]}"
grep -qx 'prefix=my_group_x' "$WORK/env" 2>/dev/null || fail 'prefix was cut'

begin 'empty group is the opt-out'
for g in '' '   '; do
  reset_case "$g"
  run_case "${GOOD[@]}" "${FORWARD[@]}"
  [[ "$LAST_CODE" -eq 0 && -z "$(calls)" && "$(reads)" == 'wazuhGroup,' ]] || fail "group [$g] code $LAST_CODE calls $(calls) reads $(reads)"
done

begin 'empty password is refused'
for p in '' '  '; do
  reset_case tenant_group "$p"
  run_case "${GOOD[@]}" "${FORWARD[@]}"
  [[ "$LAST_CODE" -eq 1 && -z "$(calls)" && "$LAST_OUT" == *wazuhRegistrationPassword* ]] || fail "password [$p] code $LAST_CODE calls $(calls)"
done

begin 'a failed field read names the field only'
for f in wazuhGroup wazuhRegistrationPassword; do
  reset_case
  printf '%s' "$f" > "$WORK/field_fails"
  run_case "${GOOD[@]}" "${FORWARD[@]}"
  [[ "$LAST_CODE" -eq 1 && -z "$(calls)" && "$LAST_OUT" == *"$f"* ]] || fail "$f code $LAST_CODE out [$LAST_OUT]"
done

begin 'runner pin guards'
reset_case
run_case --runner-url https://example.invalid/r --runner-sha256 '' --wazuh-manager m "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 0 && -z "$(calls)" && -z "$(reads)" ]] || fail "empty hash code $LAST_CODE"
reset_case
run_case "${GOOD[@]}" --package-url p --package-sha256 '' --action Install --pin-version 4.14.3
[[ "$LAST_CODE" -eq 0 && -z "$(calls)" && -z "$(reads)" ]] || fail "empty forwarded pin code $LAST_CODE"
for bad in "${RUNNER_SHA^^}" abc; do
  reset_case
  run_case --runner-url https://example.invalid/r --runner-sha256 "$bad" --wazuh-manager m "${FORWARD[@]}"
  [[ "$LAST_CODE" -eq 1 && -z "$(calls)" ]] || fail "bad hash [$bad] code $LAST_CODE"
done
reset_case
run_case --runner-url https://example.invalid/r --runner-sha256 "$(printf 'cd%.0s' {1..32})" --wazuh-manager m "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == 'fetch,' && "$LAST_OUT" == *'hash mismatch'* ]] || fail "mismatch code $LAST_CODE calls $(calls)"
reset_case
run_case --runner-url "https://u:p""@example.invalid/r" --runner-sha256 "$RUNNER_SHA" --wazuh-manager m "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 1 && -z "$(calls)" ]] || fail "userinfo code $LAST_CODE"
reset_case
run_case --runner-url https://example.invalid/r --runner-sha256 "$RUNNER_SHA" --wazuh-manager ' ' "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 1 && -z "$(calls)" ]] || fail "empty manager code $LAST_CODE"
reset_case
run_case --runner-url '' --runner-sha256 "$RUNNER_SHA" --wazuh-manager m "${FORWARD[@]}"
[[ "$LAST_CODE" -eq 1 && -z "$(calls)" ]] || fail "empty runner url code $LAST_CODE"

begin 'the real field seam calls ninjarmm-cli get; the newline is dropped by the caller'
(
  # shellcheck disable=SC1090
  source "$WRAPPER"
  RWE_CLI="$WORK/fake-cli"
  printf '#!/bin/bash\n[[ "$1 $2" == "get wazuhGroup" ]] && printf "tenant_group\\n"\n' > "$RWE_CLI"
  chmod +x "$RWE_CLI"
  [[ "$(rwe_get_field wazuhGroup)" == 'tenant_group' ]] || exit 1
) || fail 'field seam'

begin 'no trace output'
grep -q '^{ set +x; } 2>/dev/null$' "$WRAPPER" || fail 'wrapper does not turn tracing off'

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'runner-wazuh-enroll tests passed\n'
