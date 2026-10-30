#!/bin/bash
# Linux runner --package-arguments-b64. Downloads are faked; the package is a local fixture.
# The stubs are called by the sourced runner.
# shellcheck disable=SC2317
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/linux/runner/relian-runner.sh"

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

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# The fixture package writes the variables it sees, one per line, to RELIAN_PACKAGE_LOG.
FIXTURE="$WORK/pkg.sh"
cat > "$FIXTURE" << 'EOF'
for name in ClientTag AuthKeyField Spaced Inert OnlyFlag i; do
  printf '%s=%s\n' "$name" "${!name-UNSET}" >> "$RELIAN_PACKAGE_LOG"
done
exit 0
EOF
FIXTURE_HASH="$(sha256sum -- "$FIXTURE" | cut -d ' ' -f 1)"

export RELIAN_DEPLOY_TEST=1
# shellcheck disable=SC1090
source "$RUNNER"

DOWNLOADS=0
relian_http_get() {
  DOWNLOADS=$((DOWNLOADS + 1))
  cp -- "$FIXTURE" "$2"
  printf '200'
  return 0
}
relian_sleep() { :; }
# Records what the runner's own later step sees.
AFTER=""
relian_remove_work() {
  AFTER="${OnlyFlag-UNSET}/${ClientTag-UNSET}"
  rm -rf -- "$2"
}

b64() {
  printf '%s' "$1" | base64 -w0
}

LOG="$WORK/log"
run() {
  # run <b64 or -> [action]
  : > "$LOG"
  DOWNLOADS=0
  AFTER=""
  LAST_CODE=0
  local args=(--package-url 'https://example.invalid/p.sh' --package-sha256 "$FIXTURE_HASH" --action "${2:-Install}" --pin-version 1)
  if [[ "$1" != '-' ]]; then
    args+=(--package-arguments-b64 "$1")
  fi
  RELIAN_PACKAGE_LOG="$LOG" relian_runner_main "${args[@]}" > "$WORK/out" 2> "$WORK/err" || LAST_CODE=$?
  LAST_OUT="$(cat "$WORK/out")"
  LAST_ERR="$(cat "$WORK/err")"
}

seen() {
  grep -m 1 "^$1=" "$LOG" | cut -d '=' -f 2-
}

begin "round trip of several pairs, with spaces, = and quotes"
blob="$(b64 $'ClientTag=tag:client-example\nAuthKeyField=tailscaleAuthKey\nSpaced=a b = "c" \'d\'\n')"
run "$blob"
[[ "$LAST_CODE" -eq 0 && "$DOWNLOADS" -eq 1 ]] || fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
[[ "$(seen ClientTag)" == 'tag:client-example' ]] || fail "ClientTag [$(seen ClientTag)]"
[[ "$(seen AuthKeyField)" == 'tailscaleAuthKey' ]] || fail "AuthKeyField [$(seen AuthKeyField)]"
[[ "$(seen Spaced)" == "a b = \"c\" 'd'" ]] || fail "Spaced [$(seen Spaced)]"
[[ "$LAST_OUT" == 'package arguments: 3 (ClientTag AuthKeyField Spaced)' ]] || fail "out [$LAST_OUT]"
ok

begin "no trailing newline and many pairs"
text=""
i=1
while [[ "$i" -le 40 ]]; do
  text="${text}Name$i=value $i"$'\n'
  i=$((i + 1))
done
text="${text}ClientTag=last"
run "$(b64 "$text")"
[[ "$LAST_CODE" -eq 0 && "$(seen ClientTag)" == 'last' ]] || fail "code=$LAST_CODE ClientTag=[$(seen ClientTag)]"
[[ "$LAST_OUT" == 'package arguments: 41 ('* ]] || fail "out [$LAST_OUT]"
ok

begin "shell syntax in a value stays inert"
marker="$WORK/expanded"
value="\$(touch $marker) \`touch $marker\`; touch $marker \${HOME}"
run "$(b64 "Inert=$value")"
[[ "$LAST_CODE" -eq 0 ]] || fail "code=$LAST_CODE err=[$LAST_ERR]"
[[ ! -e "$marker" ]] || fail "a value was expanded"
[[ "$(seen Inert)" == "$value" ]] || fail "Inert [$(seen Inert)]"
ok

begin "invalid arguments exit 1 and download nothing"
check_bad() {
  run "$1"
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 || "$LAST_ERR" != 'invalid package arguments' ]]; then
    fail "$2: code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
}
check_bad 'not base64!' 'bad characters'
check_bad 'QQ' 'bad padding'
check_bad "$(head -c 4097 /dev/zero | tr '\000' 'a' | sed 's/^/A=/' | base64 -w0)" 'oversize'
check_bad "$(printf 'A=1\000B=2' | base64 -w0)" 'NUL'
check_bad "$(b64 $'A=1\nA=2')" 'duplicate'
check_bad "$(b64 '=value')" 'empty name'
check_bad "$(b64 'NoEquals')" 'no ='
check_bad "$(b64 '1abc=x')" 'name starts with a digit'
check_bad "$(b64 'a-b=x')" 'name with a dash'
for denied in PATH path IFS SHELL HOME USER LANG LANGUAGE LC_ALL LD_PRELOAD BASH_ENV ENV TERM TMPDIR \
  PYTHONPATH PERL5LIB RUBYOPT NODE_OPTIONS RELIAN_DEPLOY_TEST NINJA_DATA_PATH relian_x \
  SHELLOPTS BASHOPTS PS4 PROMPT_COMMAND CDPATH GLOBIGNORE UID package_url Action \
  EXECIGNORE execignore FUNCNEST TMOUT SHLVL OPTIND GLOBSORT; do
  check_bad "$(b64 "$denied=x")" "denied $denied"
done
ok

begin "a pair named like a loop counter reaches the package and does not break the export"
# With a shared counter, i=5 would end the loop before ClientTag is exported.
run "$(b64 $'i=5\nClientTag=after')"
[[ "$LAST_CODE" -eq 0 && "$(seen i)" == '5' && "$(seen ClientTag)" == 'after' ]] || fail "code=$LAST_CODE i=[$(seen i)] ClientTag=[$(seen ClientTag)]"
ok

begin "the 4096-byte limit is inclusive"
run "$(head -c 4094 /dev/zero | tr '\000' 'a' | sed 's/^/A=/' | base64 -w0)"
[[ "$LAST_CODE" -eq 0 ]] || fail "4096 bytes rejected: [$LAST_ERR]"
ok

begin "an empty blob and an absent flag change nothing"
run ''
[[ "$LAST_CODE" -eq 0 && -z "$LAST_OUT" && "$(seen ClientTag)" == 'UNSET' ]] || fail "empty: code=$LAST_CODE out=[$LAST_OUT]"
run -
[[ "$LAST_CODE" -eq 0 && -z "$LAST_OUT" && "$(seen ClientTag)" == 'UNSET' ]] || fail "absent: code=$LAST_CODE out=[$LAST_OUT]"
ok

begin "inherited variable still works and a flag pair wins over it"
export ClientTag='inherited'
run -
[[ "$(seen ClientTag)" == 'inherited' ]] || fail "inherited not seen: [$(seen ClientTag)]"
run "$(b64 $'ClientTag=from-flag\nOnlyFlag=yes')"
[[ "$(seen ClientTag)" == 'from-flag' && "$(seen OnlyFlag)" == 'yes' ]] || fail "flag did not win: [$(seen ClientTag)] [$(seen OnlyFlag)]"
ok

begin "the runner's later steps and the caller do not get the pairs"
[[ "$AFTER" == 'UNSET/inherited' ]] || fail "later step saw [$AFTER]"
[[ "${OnlyFlag-UNSET}" == 'UNSET' && "$ClientTag" == 'inherited' ]] || fail "caller saw OnlyFlag=${OnlyFlag-UNSET} ClientTag=$ClientTag"
[[ "${#RELIAN_PKG_NAMES[@]}" -eq 0 ]] || fail "parsed pairs kept after the run"
unset ClientTag
ok

begin "Reinstall passes the pairs to both steps"
run "$(b64 'ClientTag=both')" Reinstall
[[ "$LAST_CODE" -eq 0 && "$(grep -c '^ClientTag=both$' "$LOG")" -eq 2 ]] || fail "code=$LAST_CODE log=[$(cat "$LOG")]"
ok

begin "values and the blob never reach output, errors, or a trace"
secret="$(printf '%s' 'sec' 'ret' '-' 'value' '-' "$RANDOM$RANDOM")"
good="$(b64 "Probe=$secret")"
run "$good"
[[ "$LAST_OUT$LAST_ERR" != *"$secret"* && "$LAST_OUT$LAST_ERR" != *"$good"* ]] || fail "value or blob in output"
bad="$(b64 $'Probe='"$secret"$'\nPATH=x')"
run "$bad"
[[ "$LAST_OUT$LAST_ERR" != *"$secret"* && "$LAST_OUT$LAST_ERR" != *"$bad"* && "$LAST_OUT$LAST_ERR" != *Probe* ]] || fail "value, name or blob in error output"
# Executed under bash -x. Each case stops before any download.
for args in "--package-arguments-b64 $bad --bogus" \
  "--package-url https://example.invalid/p.sh --package-sha256 $FIXTURE_HASH --action Install --pin-version 1 --package-arguments-b64 $bad" \
  "--package-url https://example.invalid/p.sh --package-sha256 $FIXTURE_HASH --action Install --pin-version 1 --package-arguments-b64 !$good"; do
  read -r -a argv <<< "$args"
  traced="$(env -u RELIAN_DEPLOY_TEST bash -x "$RUNNER" "${argv[@]}" 2>&1)"
  [[ "$traced" != *"$secret"* && "$traced" != *"$good"* && "$traced" != *"$bad"* ]] || fail "trace leaked for [${argv[*]:0:2}...]: [$traced]"
done
ok

printf 'SUMMARY passed=%s failed=%s\n' "$PASSES" "$FAILURES"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
exit 0
