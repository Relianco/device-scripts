#!/bin/bash
# Linux Tailscale package. Every machine call is replaced; nothing is installed or joined.
# The fakes run in a child bash, so shellcheck sees them as unreachable.
# shellcheck disable=SC2317,SC2016
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/linux/packages/tailscale/tailscale.sh"
RELEASE="$ROOT/linux/releases/tailscale.json"

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

TAG='tag:client-example'
# Built at runtime so no committed literal has the shape of a real key. Real keys are far longer.
KEY_PREFIX="ts""key"
FAKE_KEY="$KEY_PREFIX-auth-x"
FIELD_KEY="$KEY_PREFIX-auth-field"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
CALLS="$WORK/calls"
UPARGS="$WORK/upargs"
KEYSEEN="$WORK/keyseen"

# Fake machine. State lives in files so it survives the subshell ts_main runs in.
fake_reset() {
  : > "$CALLS"
  : > "$UPARGS"
  : > "$KEYSEEN"
  printf '%s' "${1:-}" > "$WORK/installed"
  printf '%s' "${2:-}" > "$WORK/status"
  printf '%s' "${3:-}" > "$WORK/field"
  printf '%s' "${4:-0}" > "$WORK/field_missing"
  printf '%s' "${5:-1.104.4}" > "$WORK/after_install"
  printf '%s' "${6:-}" > "$WORK/status_after_install"
}
ts_is_root() { return 0; }
ts_codename() { printf 'bookworm'; }
ts_short_hostname() { printf 'testhost'; }
ts_installed_version() { cat "$WORK/installed"; }
ts_has_cli() { [[ -s "$WORK/installed" ]]; }
ts_status_json() { cat "$WORK/status"; }
ts_install() {
  printf 'install\n' >> "$CALLS"
  cat "$WORK/after_install" > "$WORK/installed"
  cat "$WORK/status_after_install" > "$WORK/status"
}
ts_ninja_get() {
  printf 'field:%s\n' "$1" >> "$CALLS"
  if [[ "$(cat "$WORK/field_missing")" == 1 ]]; then
    TS_NINJA_MISSING=1
    return 1
  fi
  [[ "$1" == 'tailscaleAuthKey' ]] || return 1
  cat "$WORK/field"
}
ts_tailscale() {
  local arg
  printf '%s\n' "$1" >> "$CALLS"
  printf '%s\n' "$@" > "$UPARGS"
  for arg in "$@"; do
    case "$arg" in
      --auth-key=file:*)
        local path="${arg#--auth-key=file:}"
        { cat "$path"; printf '\n'; stat -c '%a' "$path"; } > "$KEYSEEN"
        ;;
    esac
  done
  return 0
}

json() {
  # $1 state, $2 tags as a JSON array body
  printf '{"BackendState":"%s","Self":{"Tags":[%s]}}' "$1" "${2:-}"
}

run() {
  # run <env assignments...> -- <ts_main args>
  LAST_CODE=0
  LAST_ERR="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    source "$1"; shift
    source "$1"; shift
    ts_main --deployment-type Install --action "${ACTION:-Install}" --pin-version "${PIN-1.104.4}"
  ' _ "$PACKAGE" "$WORK/fakes.sh" 2>&1 > /dev/null)" || LAST_CODE=$?
}

# The fakes, written out so a clean bash can load them after the package.
declare -f fake_reset ts_is_root ts_codename ts_short_hostname ts_installed_version ts_has_cli \
  ts_status_json ts_install ts_ninja_get ts_tailscale > "$WORK/fakes.sh"
{
  printf 'WORK=%q\nCALLS=%q\nUPARGS=%q\nKEYSEEN=%q\n' "$WORK" "$CALLS" "$UPARGS" "$KEYSEEN"
} >> "$WORK/fakes.sh"

calls() { tr '\n' ',' < "$CALLS"; }

begin "plan cases"
check_plan() {
  local want="$1"; shift
  ts_plan "$@"
  local got="${PLAN_EXIT:-_}/$PLAN_INSTALL/$PLAN_JOIN"
  if [[ "$got" != "$want" ]]; then
    fail "plan [$*] got $got want $want"
  fi
}
check_plan '_/1/key' Install 1.104.4 '' '' '' 1 "$TAG"
check_plan '1/1/key' Install 1.104.4 '' '' '' 0 "$TAG"
check_plan '_/0/key' Install 1.104.4 1.104.4 NeedsLogin '' 1 "$TAG"
check_plan '1/0/key' Install 1.104.4 1.104.4 NeedsLogin '' 0 "$TAG"
check_plan '_/0/set' Install 1.104.4 1.104.4 Running "$TAG" 0 "$TAG"
check_plan '_/0/set' Repair 1.104.4 1.106.0 Running "$TAG" 0 "$TAG"
check_plan '_/1/set' Update 1.104.4 1.90.0 Running "$TAG" 0 "$TAG"
check_plan '_/0/up' Install 1.104.4 1.104.4 Stopped "$TAG" 0 "$TAG"
check_plan '1/0/none' Install 1.104.4 1.104.4 Running 'tag:client-other' 1 "$TAG"
check_plan '1/0/none' Install 1.104.4 1.104.4 Stopped 'tag:client-other' 1 "$TAG"
check_plan '1/0/none' Install 1.104.4 1.104.4 Running "$TAG,tag:extra" 1 "$TAG"
check_plan '1/0/none' Install 1.104.4 1.104.4 Running '' 1 "$TAG"
check_plan '1/0/none' Install 1.104.4 1.104.4 Unreadable '' 1 "$TAG"
check_plan '0/0/none' Install '' '' '' '' 0 ''
check_plan '1/0/none' Uninstall 1.104.4 '' '' '' 1 "$TAG"
check_plan '1/0/none' Reinstall 1.104.4 '' '' '' 1 "$TAG"
check_plan '1/0/none' Install 1.104.4 '' '' '' 1 'client-example'
check_plan '1/0/none' Install 1.104.4 garbage '' '' 1 "$TAG"
check_plan '1/0/none' Install x.y '' '' '' 1 "$TAG"
ok

begin "status parsing"
got="$(json Running '"tag:client-example"' | ts_parse_status)"
[[ "$got" == "Running $TAG" ]] || fail "with tag [$got]"
got="$(printf '{"BackendState":"NeedsLogin","Self":{}}' | ts_parse_status)"
[[ "$got" == "NeedsLogin " ]] || fail "no tags [$got]"
for bad in 'not json' '' '{}' '{"BackendState":""}' 'failed to connect to local tailscaled'; do
  got="$(printf '%s' "$bad" | ts_parse_status)"
  [[ "$got" == "Unreadable " ]] || fail "bad [$bad] gave [$got]"
done
ok

begin "key and tag shape"
ts_valid_key "$FAKE_KEY" || fail "fake key rejected"
! ts_valid_key "$KEY_PREFIX-a b" || fail "key with space accepted"
! ts_valid_key "abc" || fail "non-key accepted"
! ts_valid_tag 'tag:a b' || fail "tag with space accepted"
ok

begin "fresh install joins with the script-variable key through a 0600 file"
fake_reset '' '' '' 0 1.104.4 "$(json NeedsLogin)"
run AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'install,up,' ]] || fail "code=$LAST_CODE calls=$(calls) err=[$LAST_ERR]"
for want in "--advertise-tags=$TAG" '--hostname=testhost' '--accept-dns=false' '--accept-routes=false' '--ssh=false'; do
  grep -qxF -- "$want" "$UPARGS" || fail "up is missing $want"
done
if grep -qF -- "$FAKE_KEY" "$UPARGS"; then fail "the key is on the tailscale command line"; fi
grep -qE -- '--auth-key=file:' "$UPARGS" || fail "no --auth-key=file:"
[[ "$(head -n 1 "$KEYSEEN")" == "$FAKE_KEY" ]] || fail "key file did not hold the key"
[[ "$(tail -n 1 "$KEYSEEN")" == '600' ]] || fail "key file mode $(tail -n 1 "$KEYSEEN")"
keypath="$(grep -E -- '--auth-key=file:' "$UPARGS")"
keypath="${keypath#--auth-key=file:}"
[[ ! -e "$keypath" ]] || fail "key file left behind"
if grep -qE -- '--ssh$|--ssh=true|exit-node|advertise-routes' "$UPARGS"; then fail "unwanted flag"; fi
[[ "$LAST_ERR" != *"$FAKE_KEY"* ]] || fail "key in output"
ok

begin "fresh install with a slow tailscaled still joins"
fake_reset '' '' '' 0 1.104.4 'failed to connect'
run AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'install,up,' ]] || fail "code=$LAST_CODE calls=$(calls)"
ok

begin "installed, not joined, key from the Secure custom field"
fake_reset 1.104.4 "$(json NeedsLogin)" " $FIELD_KEY "
run ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'field:tailscaleAuthKey,up,' ]] || fail "code=$LAST_CODE calls=$(calls) err=[$LAST_ERR]"
[[ "$(head -n 1 "$KEYSEEN")" == "$FIELD_KEY" ]] || fail "field key not used"
ok

begin "script variable wins over the field"
fake_reset 1.104.4 "$(json NeedsLogin)" "$FIELD_KEY"
run authKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'up,' ]] || fail "code=$LAST_CODE calls=$(calls)"
[[ "$(head -n 1 "$KEYSEEN")" == "$FAKE_KEY" ]] || fail "field key used"
ok

begin "AuthKeyField names another field"
fake_reset 1.104.4 "$(json NeedsLogin)" "$FIELD_KEY"
run ClientTag="$TAG" AuthKeyField=otherField
[[ "$LAST_CODE" -eq 1 && "$(calls)" == 'field:otherField,' ]] || fail "code=$LAST_CODE calls=$(calls)"
ok

begin "already Running with the wanted tag: set only, no key read needed"
fake_reset 1.104.4 "$(json Running '"tag:client-example"')"
run AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'set,' ]] || fail "code=$LAST_CODE calls=$(calls)"
grep -qxF -- '--ssh=false' "$UPARGS" || fail "set is missing --ssh=false"
if grep -qF -- 'advertise-tags' "$UPARGS"; then fail "set changed tags"; fi
ok

begin "stopped with the wanted tag: up without a key"
fake_reset 1.104.4 "$(json Stopped '"tag:client-example"')"
run ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == 'field:tailscaleAuthKey,up,' ]] || fail "code=$LAST_CODE calls=$(calls)"
if grep -qF -- 'auth-key' "$UPARGS"; then fail "a key was passed"; fi
grep -qxF -- "--advertise-tags=$TAG" "$UPARGS" || fail "up does not restate the tag"
ok

begin "wrong tag fails loudly and does not re-join"
fake_reset 1.104.4 "$(json Running '"tag:client-other"')"
run AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "code=$LAST_CODE calls=$(calls)"
[[ "$LAST_ERR" == *'not re-joining'* ]] || fail "err=[$LAST_ERR]"
ok

begin "unreadable status on an installed node fails closed"
fake_reset 1.104.4 'garbage'
run AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "code=$LAST_CODE calls=$(calls)"
ok

begin "no key anywhere"
fake_reset '' '' '' 0
run ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == 'field:tailscaleAuthKey,' ]] || fail "code=$LAST_CODE calls=$(calls)"
[[ "$LAST_ERR" == *'script variable or the auth key custom field'* ]] || fail "err=[$LAST_ERR]"
fake_reset '' '' '' 1
run ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$LAST_ERR" == *'ninjarmm-cli was not found'* ]] || fail "missing cli not reported: [$LAST_ERR]"
ok

begin "bad key shape is refused and not printed"
fake_reset '' '' 'Field secretvalue not found' 0
run ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == 'field:tailscaleAuthKey,' ]] || fail "code=$LAST_CODE calls=$(calls)"
[[ "$LAST_ERR" != *secretvalue* ]] || fail "value printed"
run AuthKey="$KEY_PREFIX-x --ssh" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$LAST_ERR" != *"$KEY_PREFIX-x"* ]] || fail "spaced key: code=$LAST_CODE err=[$LAST_ERR]"
ok

begin "empty pin disables; unsupported actions exit 1"
fake_reset
run PIN='' ClientTag="$TAG"
[[ "$LAST_CODE" -eq 0 && "$(calls)" == '' ]] || fail "empty pin code=$LAST_CODE calls=$(calls)"
run ACTION=Uninstall AuthKey="$FAKE_KEY" ClientTag="$TAG"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "uninstall code=$LAST_CODE"
run AuthKey="$FAKE_KEY"
[[ "$LAST_CODE" -eq 1 && "$(calls)" == '' ]] || fail "no tag code=$LAST_CODE"
ok

begin "real ts_ninja_get reports a missing CLI"
TS_NINJA_MISSING=0
(
  # shellcheck disable=SC1090
  source "$PACKAGE"
  export NINJA_DATA_PATH="$WORK/none"
  ts_ninja_get tailscaleAuthKey > /dev/null && exit 1
  [[ "$TS_NINJA_MISSING" -eq 1 ]]
) || fail "missing CLI not flagged"
ok

begin "key download retries only transient failures, three attempts"
check_fetch() {
  # check_fetch <want code> <want tries> <code/status per attempt...>
  local want_code="$1" want_tries="$2"
  shift 2
  FETCH_PLAN=("$@")
  printf '0' > "$WORK/tries"
  local got=0
  ts_fetch 'https://example.invalid/k.gpg' "$WORK/k.gpg" || got=$?
  FETCH_TRIES="$(cat "$WORK/tries")"
  if [[ "$got" -ne "$want_code" || "$FETCH_TRIES" -ne "$want_tries" ]]; then
    fail "[$*] code=$got tries=$FETCH_TRIES want $want_code/$want_tries"
  fi
}
# Runs inside $(...), so the attempt count lives in a file.
ts_curl() {
  local tries
  tries="$(cat "$WORK/tries")"
  local step="${FETCH_PLAN[$tries]:-22/000}"
  printf '%s' "$((tries + 1))" > "$WORK/tries"
  printf '%s' "${step#*/}"
  return "${step%%/*}"
}
ts_sleep() { :; }
check_fetch 0 1 0/200
check_fetch 1 1 0/404
check_fetch 1 1 0/401
check_fetch 1 1 22/000
check_fetch 0 2 6/000 0/200
check_fetch 0 3 7/000 28/000 0/200
check_fetch 1 3 0/503 0/503 0/503
check_fetch 0 2 0/429 0/200
check_fetch 1 3 35/000 6/000 7/000
check_fetch 0 2 5/000 0/200
ok

begin "release record matches the package"
sha="$(sha256sum -- "$PACKAGE" | cut -d ' ' -f 1)"
RELEASE="$RELEASE" SHA="$sha" KEYSHA="$TS_SIGNER_SHA256" node -e '
const r = JSON.parse(require("fs").readFileSync(process.env.RELEASE, "utf8"))
const e = []
if (r.name !== "tailscale") e.push("name")
if (r.installsSoftware !== true) e.push("installsSoftware")
if (r.file !== "tailscale.sh") e.push("file")
if (r.sha256 !== process.env.SHA) e.push("sha256 " + r.sha256 + " != " + process.env.SHA)
if (r.repoKey.sha256 !== process.env.KEYSHA) e.push("repo key sha256")
if (!/^[0-9A-F]{40}$/.test(r.repoKey.fingerprint)) e.push("fingerprint form")
if (e.length) { console.error(e.join("; ")); process.exit(1) }
' || fail "release record"
grep -qF "${TS_SIGNER_SHA256}" "$PACKAGE" || fail "key hash not inline"
fp="$(ROOT="$ROOT" node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.ROOT + "/linux/releases/tailscale.json","utf8")).repoKey.fingerprint)')"
grep -qF "$fp" "$PACKAGE" || fail "fingerprint not noted in the package"
[[ "$(head -n 1 "$PACKAGE")" == '#!/bin/bash' ]] || fail "shebang"
ok

printf 'SUMMARY passed=%s failed=%s\n' "$PASSES" "$FAILURES"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
exit 0
