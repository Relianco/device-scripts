#!/bin/bash
# Linux Wazuh package. Every machine call is replaced; nothing is installed or enrolled.
# The fakes run in a child bash, so shellcheck sees them as unreachable.
# shellcheck disable=SC2317,SC2016
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/linux/packages/wazuh/wazuh.sh"
RELEASE="$ROOT/linux/releases/wazuh.json"

FAILURES=0
PASSES=0
FAIL_MARK=0
LABEL=""

fail() {
  printf 'FAIL %s\n' "${LABEL:+$LABEL: }$*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() {
  printf 'PASS %s\n' "$1"
  PASSES=$((PASSES + 1))
}
begin() {
  LABEL="$1"
  FAIL_MARK="$FAILURES"
}
ok() {
  if [[ "$FAILURES" -eq "$FAIL_MARK" ]]; then
    pass "$LABEL"
  fi
}

# shellcheck disable=SC1090
source "$PACKAGE"

# Built at runtime so no password is committed.
SECRET="pw-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
CALLS="$WORK/calls"
PASSFILE="$WORK/authd.src"
printf '%s' "$SECRET" > "$PASSFILE"

# Fake machine. State lives in files so it survives the subshell wz_main runs in.
fake_reset() {
  : > "$CALLS"
  printf '%s' "${1:-}" > "$WORK/installed"
  printf '%s' "${2:-0}" > "$WORK/keys"
  printf '%s' "${3:-4.14.3}" > "$WORK/after_install"
}
wz_is_root() { return 0; }
wz_short_hostname() { printf 'testhost'; }
wz_installed_version() { cat "$WORK/installed"; }
wz_keys_present() { [[ "$(cat "$WORK/keys")" == 1 ]]; }
wz_stat_pass() { printf '0 600 file'; }
wz_install() {
  printf 'install %s\n' "$1" >> "$CALLS"
  cat "$WORK/after_install" > "$WORK/installed"
}
wz_install_password() { printf 'password-file %s\n' "$1" >> "$CALLS"; }
wz_set_manager() { printf 'manager %s\n' "$1" >> "$CALLS"; }
wz_agent_auth() {
  printf 'agent-auth %s\n' "$*" >> "$CALLS"
  printf '1' > "$WORK/keys"
  printf 'agent-auth ran for %s\n' "$3"
}
wz_enable_service() { printf 'enable\n' >> "$CALLS"; }
wz_hold() { printf 'hold\n' >> "$CALLS"; }

run() {
  # run <env assignments...>; stdout and stderr both land in LAST_OUT.
  LAST_CODE=0
  LAST_OUT="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    source "$1"; shift
    source "$1"; shift
    wz_main --deployment-type Install --action "${ACTION:-Install}" --pin-version "${PIN-4.14.3}"
  ' _ "$PACKAGE" "$WORK/fakes.sh" 2>&1)" || LAST_CODE=$?
}
declare -f fake_reset wz_is_root wz_short_hostname wz_installed_version wz_keys_present wz_stat_pass \
  wz_install wz_install_password wz_set_manager wz_agent_auth wz_enable_service wz_hold > "$WORK/fakes.sh"
printf 'WORK=%q\nCALLS=%q\n' "$WORK" "$CALLS" >> "$WORK/fakes.sh"

calls() { tr '\n' ',' < "$CALLS"; }
# shellcheck disable=SC2054
GOOD=(WazuhManager=waz.example.test WazuhGroup=default,client WazuhNamePrefix=client "WazuhPasswordFile=$PASSFILE")

begin "plan cases"
check_plan() {
  local want="$1"; shift
  wz_plan "$@"
  local got="${PLAN_EXIT:-_}/$PLAN_INSTALL/$PLAN_ENROL"
  [[ "$got" == "$want" ]] || fail "plan [$*] got $got want $want"
}
check_plan '_/1/1' Install 4.14.3 '' 0 m g p /f
check_plan '_/0/0' Install 4.14.3 4.14.3 1 m g p ''
check_plan '_/0/0' Repair 4.14.3 4.14.10 1 m g p ''
check_plan '_/0/1' Install 4.14.3 4.14.9 0 m g p /f
check_plan '_/1/0' Update 4.14.3 4.13.1 1 m g p ''
check_plan '1/1/1' Install 4.14.3 '' 0 m g p ''
check_plan '1/0/0' Install 4.14.3 '' 0 '' g p /f
check_plan '1/0/0' Install 4.14.3 '' 0 m '' p /f
check_plan '1/0/0' Install 4.14.3 '' 0 m g '  ' /f
check_plan '1/0/0' Install 4.14.3 '' 0 'm;rm' g p /f
check_plan '1/0/0' Install 4.14.3 '' 0 m 'g h' p /f
check_plan '1/0/0' Uninstall 4.14.3 '' 0 m g p /f
check_plan '1/0/0' Install 4.x '' 0 m g p /f
check_plan '1/0/0' Install 4.14.3 garbage 0 m g p /f
ok

begin "version order is numeric, not textual"
wz_version_lt 4.9.2 4.14.3 || fail "4.9.2 should be lower than 4.14.3"
! wz_version_lt 4.14.10 4.14.3 || fail "4.14.10 is not lower than 4.14.3"
! wz_version_lt 4.14.3 4.14.3 || fail "equal is not lower"
ok

begin "refusal on empty variables: nothing is installed, written, or enrolled"
for missing in WazuhManager WazuhGroup WazuhNamePrefix; do
  fake_reset
  args=()
  for kv in "${GOOD[@]}"; do [[ "$kv" == "$missing="* ]] || args+=("$kv"); done
  run "${args[@]}"
  [[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "$missing unset: code=$LAST_CODE calls=$(calls)"
  [[ "$LAST_OUT" == *'environment variable is empty'* ]] || fail "$missing unset: out=[$LAST_OUT]"
  fake_reset
  args=()
  for kv in "${GOOD[@]}"; do [[ "$kv" == "$missing="* ]] && args+=("$missing=  ") || args+=("$kv"); done
  run "${args[@]}"
  [[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "$missing blank: code=$LAST_CODE calls=$(calls)"
done
fake_reset 4.14.9 1
run WazuhManager= WazuhGroup=g WazuhNamePrefix=p
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "empty vars on a keyed host must still refuse: code=$LAST_CODE"
fake_reset
run WazuhManager=waz.example.test WazuhGroup=default,client WazuhNamePrefix=client
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "no password file: code=$LAST_CODE calls=$(calls)"
[[ "$LAST_OUT" == *'WazuhPasswordFile environment variable is empty'* ]] || fail "out=[$LAST_OUT]"
ok

begin "fresh host: install the floor, write the password, enrol once, hold"
fake_reset
run "${GOOD[@]}"
want="install 4.14.3,password-file $PASSFILE,manager waz.example.test,agent-auth waz.example.test default,client client--testhost,enable,hold,"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == "$want" ]] || fail "code=$LAST_CODE calls=$(calls) out=[$LAST_OUT]"
ok

begin "keys present: never re-enrol, even with a password file and empty install state"
fake_reset 4.14.3 1
run "${GOOD[@]}"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'hold,' ]] || fail "keyed current: code=$LAST_CODE calls=$(calls)"
fake_reset 4.13.0 1 4.14.3
run "${GOOD[@]}"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'install 4.14.3,enable,hold,' ]] || fail "keyed old: code=$LAST_CODE calls=$(calls)"
case "$(calls)" in *agent-auth*|*password-file*|*manager*) fail "re-enrolled a keyed agent: $(calls)" ;; esac
# A keyed host needs no password file at all.
fake_reset 4.14.3 1
run WazuhManager=m WazuhGroup=g WazuhNamePrefix=p
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'hold,' ]] || fail "keyed, no password file: code=$LAST_CODE calls=$(calls)"
ok

begin "no downgrade: a newer agent is kept, an older one is raised to the floor"
for v in 4.14.9 4.14.10 5.0.0; do
  fake_reset "$v" 1
  run "${GOOD[@]}"
  [[ "$LAST_CODE" -eq 0 && "$(calls)" == 'hold,' ]] || fail "installed $v: code=$LAST_CODE calls=$(calls)"
done
fake_reset 4.14.9 0
run "${GOOD[@]}"
case "$(calls)" in *install*4.14.3*) fail "newer agent without keys was reinstalled at the floor: $(calls)" ;; esac
[[ "$LAST_CODE" -eq 0 && "$(calls)" == "password-file $PASSFILE,manager waz.example.test,agent-auth waz.example.test default,client client--testhost,enable,hold," ]] \
  || fail "newer unkeyed: code=$LAST_CODE calls=$(calls)"
fake_reset 4.13.9 1
run "${GOOD[@]}" PIN=4.14.3
[[ "$(calls)" == 'install 4.14.3,enable,hold,' ]] || fail "older agent: calls=$(calls)"
ok

begin "the pin version is a parameter; an empty pin disables"
fake_reset
run "${GOOD[@]}" PIN=4.14.8 
[[ "$(calls)" == install\ 4.14.8,* ]] || fail "explicit pin: calls=$(calls)"
fake_reset
run "${GOOD[@]}" PIN=
[[ "$LAST_CODE" -eq 0 && "$(calls)" == '' ]] || fail "empty pin should disable: code=$LAST_CODE calls=$(calls)"
fake_reset
run "${GOOD[@]}" PIN= ACTION=Uninstall
[[ "$LAST_CODE" -eq 0 && "$(calls)" == '' ]] || fail "empty pin and Uninstall should exit 0: code=$LAST_CODE"
ok

begin "password never in argv, calls, or output; the file is checked first"
fake_reset
run "${GOOD[@]}"
if grep -qF -- "$SECRET" "$CALLS"; then fail "password in a recorded command"; fi
[[ "$LAST_OUT" != *"$SECRET"* ]] || fail "password in output"
grep -qxF "password-file $PASSFILE" "$CALLS" || fail "password not passed by path"
# The real functions: none reads the password file or puts a password flag on a command line.
real="$(bash -c 'source "$1"; declare -f wz_install_password wz_agent_auth wz_enrol wz_main' _ "$PACKAGE")"
if grep -qE -- '(^|[^[:alnum:]_])(cat|head|read)[[:space:]].*(passfile|WZ_PASS)|\$\(<|[[:space:]]-P[[:space:]]|--password' <<< "$real"; then
  fail "a package function reads the password or passes it as a flag"
fi
ok

begin "password file policy"
wz_stat_pass() { printf '%s' "$FAKE_STAT"; }
FAKE_STAT='0 600 file';  wz_check_passfile /x 2> /dev/null || fail "root 600 refused"
FAKE_STAT='0 400 file';  wz_check_passfile /x 2> /dev/null || fail "root 400 refused"
FAKE_STAT='0 640 file';  ! wz_check_passfile /x 2> /dev/null || fail "group-readable accepted"
FAKE_STAT='0 644 file';  ! wz_check_passfile /x 2> /dev/null || fail "world-readable accepted"
FAKE_STAT='1000 600 file'; ! wz_check_passfile /x 2> /dev/null || fail "non-root owner accepted"
FAKE_STAT='0 600 empty'; ! wz_check_passfile /x 2> /dev/null || fail "empty file accepted"
FAKE_STAT='0 000 link';  ! wz_check_passfile /x 2> /dev/null || fail "symlink accepted"
unset -f wz_stat_pass
# shellcheck disable=SC1090
source "$PACKAGE"
ln -s "$PASSFILE" "$WORK/link"
: > "$WORK/empty"
[[ "$(wz_stat_pass "$WORK/link")" == '0 000 link' ]] || fail "real stat link: $(wz_stat_pass "$WORK/link")"
[[ "$(wz_stat_pass "$WORK/empty")" == *' empty' ]] || fail "real stat empty"
[[ "$(wz_stat_pass "$WORK/none")" == '0 000 missing' ]] || fail "real stat missing"
ok

begin "bad password file stops before install"
# Reload the fakes, then point at a file the policy rejects.
# shellcheck disable=SC1090,SC1091
source "$WORK/fakes.sh"
wz_stat_pass() { printf '0 644 file'; }
declare -f wz_stat_pass >> "$WORK/fakes.sh"
fake_reset
run "${GOOD[@]}"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "code=$LAST_CODE calls=$(calls)"
ok

begin "agent-auth gets the enrolment group with -G, never -g"
real="$(bash -c 'source "$1"; declare -f wz_agent_auth' _ "$PACKAGE")"
[[ "$real" == *'-G "$2"'* && "$real" != *' -g '* ]] || fail "agent-auth flags: $real"
ok

begin "dnf: an existing version lock is dropped before the package is raised"
real="$(bash -c 'source "$1"; declare -f wz_pkg_install' _ "$PACKAGE")"
[[ "$real" == *'versionlock delete wazuh-agent'* ]] || fail "no versionlock delete before dnf install"
ok

begin "unsigned or wrong repository key is refused before any package change"
# shellcheck disable=SC1090
source "$PACKAGE"
WZ_LIST="$WORK/wazuh.list"; WZ_KEYRING="$WORK/wazuh.gpg"
: > "$CALLS"
wz_pkg_manager() { printf 'apt'; }
wz_have_gpg() { return 0; }
wz_fetch() { printf 'key' > "$2"; }
wz_dearmor() { cp -- "$1" "$2"; }
wz_apt_update() { printf 'update\n' >> "$CALLS"; }
wz_pkg_install() { printf 'pkg %s\n' "$1" >> "$CALLS"; }
wz_key_fpr() { printf '%s' "${FAKE_FPR:-}"; }
FAKE_FPR='AAAA'
out="$(wz_install 4.14.3 2>&1)" && fail "wrong fingerprint accepted"
[[ "$out" == *'fingerprint mismatch'* ]] || fail "out=[$out]"
FAKE_FPR=''
wz_install 4.14.3 > /dev/null 2>&1 && fail "empty fingerprint (multi-key or unreadable file) accepted"
[[ ! -e "$WZ_LIST" && ! -e "$WZ_KEYRING" && "$(calls)" == '' ]] || fail "repo added or package touched: $(calls)"
FAKE_FPR="$WZ_KEY_FPR"
wz_install 4.14.3 > /dev/null 2>&1 || fail "pinned fingerprint refused"
[[ "$(calls)" == 'update,pkg 4.14.3,' ]] || fail "good key calls=$(calls)"
grep -qF "signed-by=$WZ_KEYRING" "$WZ_LIST" || fail "list does not use signed-by"
ok

begin "key download retries only transient failures, three attempts"
# shellcheck disable=SC1090
source "$PACKAGE"
check_fetch() {
  local want_code="$1" want_tries="$2"
  shift 2
  FETCH_PLAN=("$@")
  printf '0' > "$WORK/tries"
  local got=0
  wz_fetch 'https://example.invalid/k' "$WORK/k" || got=$?
  FETCH_TRIES="$(cat "$WORK/tries")"
  [[ "$got" -eq "$want_code" && "$FETCH_TRIES" -eq "$want_tries" ]] || fail "[$*] code=$got tries=$FETCH_TRIES want $want_code/$want_tries"
}
wz_curl() {
  local tries step
  tries="$(cat "$WORK/tries")"
  step="${FETCH_PLAN[$tries]:-22/000}"
  printf '%s' "$((tries + 1))" > "$WORK/tries"
  printf '%s' "${step#*/}"
  return "${step%%/*}"
}
wz_sleep() { :; }
check_fetch 0 1 0/200
check_fetch 1 1 0/404
check_fetch 0 2 6/000 0/200
check_fetch 1 3 0/503 0/503 0/503
ok

begin "release record matches the package"
sha="$(sha256sum -- "$PACKAGE" | cut -d ' ' -f 1)"
RELEASE="$RELEASE" SHA="$sha" FPR="$WZ_KEY_FPR" node -e '
const r = JSON.parse(require("fs").readFileSync(process.env.RELEASE, "utf8"))
const e = []
if (r.name !== "wazuh") e.push("name")
if (r.installsSoftware !== true) e.push("installsSoftware")
if (r.file !== "wazuh.sh") e.push("file")
if (r.sha256 !== process.env.SHA) e.push("sha256 " + r.sha256 + " != " + process.env.SHA)
if (r.pinVersion !== "4.14.3") e.push("pinVersion")
if (r.repoKey.fingerprint !== process.env.FPR) e.push("fingerprint")
if (e.length) { console.error(e.join("; ")); process.exit(1) }
' || fail "release record"
[[ "$(head -n 1 "$PACKAGE")" == '#!/bin/bash' ]] || fail "shebang"
ok

printf 'SUMMARY passed=%s failed=%s\n' "$PASSES" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
