#!/bin/bash
# macOS runner contract. Bash 3.2. No mapfile, no associative arrays.
# Digest goes through the runner's relian_sha256, which calls shasum.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/macos/runner/relian-runner.sh"
PACKAGE="$ROOT/macos/packages/noop/noop.sh"
RELEASE="$ROOT/macos/releases/noop.json"
README="$ROOT/README.md"
WORKFLOW="$ROOT/.github/workflows/pr-verify.yml"

FAILURES=0
PASSES=0
FAIL_MARK=0
LABEL=""
DOWNLOADS=0
HTTP_INDEX=0
HTTP_STATUS=()
HTTP_CODE=()
HTTP_BODY=()
SLEEPS=()
LAST_CODE=0
LAST_ERR=""
LAST_OUT=""
FIXTURE=""
FIXTURE_HASH=""
PKG_URL="https://example.invalid/noop.sh"

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

reset_stubs() {
  DOWNLOADS=0
  HTTP_INDEX=0
  HTTP_STATUS=()
  HTTP_CODE=()
  HTTP_BODY=()
  SLEEPS=()
  unset RELIAN_DEPLOY_KEEP_WORK
  unset RELIAN_FIXTURE_FAIL_UNINSTALL
}

queue_http() {
  HTTP_STATUS+=("$1")
  HTTP_CODE+=("$2")
  HTTP_BODY+=("$3")
}

expect_sleeps() {
  local got="" want=""
  local IFS=','
  if [[ ${#SLEEPS[@]} -gt 0 ]]; then
    got="${SLEEPS[*]}"
  fi
  if [[ $# -gt 0 ]]; then
    want="$*"
  fi
  if [[ "$got" != "$want" ]]; then
    fail "sleeps got [$got] want [$want]"
    return 1
  fi
  return 0
}

url_user() {
  printf '%s%s%s%s' 'https://' 'user' '@' 'example.invalid/noop.sh'
}

url_user_pw() {
  local secret
  secret="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s%s%s%s%s%s' 'https://' 'user' ':' "$secret" '@' 'example.invalid/noop.sh'
}

url_path_at() {
  printf '%s%s%s' 'https://example.invalid/a' '@' 'b/noop.sh'
}

url_query_at() {
  printf '%s%s%s' 'https://example.invalid/noop.sh?x=a' '@' 'b'
}

url_empty_user() {
  printf '%s%s%s' 'https://' '@' 'example.org/package.sh'
}

invoke_runner() {
  local log="$1"
  shift
  local err_file out_file
  err_file="$(mktemp)"
  out_file="$(mktemp)"
  LAST_CODE=0
  RELIAN_PACKAGE_LOG="$log" relian_runner_main "$@" >"$out_file" 2>"$err_file" || LAST_CODE=$?
  LAST_ERR="$(cat "$err_file")"
  LAST_OUT="$(cat "$out_file")"
  rm -f -- "$err_file" "$out_file"
}

setup_fixture() {
  local dir line
  dir="$(mktemp -d)"
  FIXTURE="$dir/pkg.sh"
  cat > "$FIXTURE" << 'EOF'
#!/bin/false
deployment=""
action=""
pin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-type)
      deployment="$2"
      shift 2
      ;;
    --action)
      action="$2"
      shift 2
      ;;
    --pin-version)
      pin="$2"
      shift 2
      ;;
    *)
      exit 2
      ;;
  esac
done
if [[ -n "${RELIAN_PACKAGE_LOG:-}" ]]; then
  printf 'deployment=%s action=%s pin=%s\n' "$deployment" "$action" "$pin" >> "$RELIAN_PACKAGE_LOG"
fi
if [[ "${RELIAN_FIXTURE_FAIL_UNINSTALL:-}" == "1" && "$action" == "Uninstall" ]]; then
  exit 9
fi
exit 0
EOF
  chmod +x "$FIXTURE"
  FIXTURE_HASH="$(relian_sha256 "$FIXTURE")"
}

queue_success() {
  queue_http 200 0 "$FIXTURE"
}

run_success() {
  local log="$1"
  shift
  queue_success
  invoke_runner "$log" "$@"
}

assert_no_url() {
  local url="$1"
  if [[ "$LAST_ERR" == *"$url"* || "$LAST_OUT" == *"$url"* ]]; then
    fail "output included the URL"
    return 1
  fi
  return 0
}

check_file_text() {
  local file="$1"
  local word
  if [[ ! -f "$file" ]]; then
    fail "missing $file"
    return 1
  fi
  if LC_ALL=C grep -q $'\r' "$file"; then
    fail "$file contains CR"
  fi
  for word in ninjarmm-cli apt dnf zypper sha256sum; do
    if grep -F -q -- "$word" "$file"; then
      fail "$file contains $word"
    fi
  done
  if grep -E -q 'declare -A|mapfile|readarray|\|&' "$file"; then
    fail "$file uses bash 4 syntax"
  fi
  if grep -E -q '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}' "$file"; then
    fail "$file lowercases with bash 4"
  fi
  return 0
}

test_static_files() {
  begin "runner, package, and release exist"
  check_file_text "$RUNNER" || true
  check_file_text "$PACKAGE" || true
  if [[ ! -f "$RELEASE" ]]; then
    fail "missing $RELEASE"
  fi
  if [[ -f "$RUNNER" ]]; then
    local first
    first="$(head -n 1 "$RUNNER")"
    if [[ "$first" != '#!/bin/bash' ]]; then
      fail "runner shebang is [$first]"
    fi
    if grep -F -q 'sha256sum' "$RUNNER"; then
      fail "runner calls sha256sum"
    fi
    if ! grep -F -q 'shasum -a 256' "$RUNNER"; then
      fail "runner does not call shasum -a 256"
    fi
    if grep -F -q 'linux/runner/relian-runner.sh' "$RUNNER"; then
      fail "runner references the linux runner"
    fi
  fi
  if [[ -f "$PACKAGE" ]]; then
    local first_pkg
    first_pkg="$(head -n 1 "$PACKAGE")"
    if [[ "$first_pkg" != '#!/bin/bash' ]]; then
      fail "package shebang is [$first_pkg]"
    fi
  fi
  ok

  begin "release record matches noop.sh"
  if [[ ! -f "$RELEASE" || ! -f "$PACKAGE" ]]; then
    fail "release or package missing"
  else
    local json_err
    json_err="$(ROOT="$ROOT" node 2>&1 << 'JS'
const fs = require('fs')
const crypto = require('crypto')
const path = require('path')
const root = process.env.ROOT
const release = JSON.parse(fs.readFileSync(path.join(root, 'macos', 'releases', 'noop.json'), 'utf8'))
const hash = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'macos', 'packages', 'noop', 'noop.sh'))).digest('hex')
const errors = []
if (release.name !== 'noop') errors.push('name ' + JSON.stringify(release.name))
if (release.installsSoftware !== false) errors.push('installsSoftware ' + JSON.stringify(release.installsSoftware))
if (release.file !== 'noop.sh') errors.push('file ' + JSON.stringify(release.file))
if (!/^[0-9a-f]{64}$/.test(String(release.sha256))) errors.push('sha256 form')
if (release.sha256 !== hash) errors.push('sha256 ' + release.sha256 + ' != ' + hash)
if (errors.length) {
  console.error(errors.join('\n'))
  process.exit(1)
}
JS
)" || fail "noop.json disagree: ${json_err:-exit $?}"
  fi
  ok

  begin "readme keeps deploy needles and names both shell runners"
  if [[ ! -f "$README" ]]; then
    fail "missing README"
  else
    local text rest needle next
    text="$(cat "$README")"
    local description='NinjaOne installs software by pasting `windows/runner/Invoke-RelianRunner.ps1`. That file is the installer. `windows/bootstrap.ps1` loads an inventory collector. It is not the installer.'
    case "$text" in
      "# device-scripts"*) ;;
      *) fail "README title changed" ;;
    esac
    case "$text" in
      *"$description"*) ;;
      *) fail "README description removed" ;;
    esac
    rest="${text#*"## Deploy runner"}"
    if [[ "$rest" == "$text" ]]; then
      fail "Deploy runner section missing"
    fi
    local needles=(
      'windows/runner/Invoke-RelianRunner.ps1'
      'PackageSha256'
      'ToolkitSha256'
      'BrandPackSha256'
      'An empty pin exits 0'
      'three download attempts'
      'A bad hash is not retried'
      '130'
      'https://relianpub.blob.core.windows.net/pub/sec/'
      'bootstrap.ps1 remains the collector loader'
    )
    for needle in "${needles[@]}"; do
      next="${rest#*"$needle"}"
      if [[ "$next" == "$rest" ]]; then
        fail "README missing $needle"
        break
      fi
      rest="$next"
    done
    if ! awk '
      /^## Deploy runner$/ { deploy = NR }
      /^## Shell runners$/ { shell = NR }
      END {
        if (deploy == 0 || shell == 0 || shell < deploy) exit 1
      }
    ' "$README"; then
      fail "Shell runners section is not after Deploy runner"
    fi
    local linux_sentence='`linux/runner/relian-runner.sh` is the Linux script to paste. It is not the macOS runner.'
    local macos_sentence='`macos/runner/relian-runner.sh` is the macOS script to paste. It is not the Windows runner and not the Linux runner.'
    case "$text" in
      *"$linux_sentence"*) ;;
      *) fail "README linux shell runners sentence missing" ;;
    esac
    case "$text" in
      *"$macos_sentence"*) ;;
      *) fail "README macos shell runners sentence missing" ;;
    esac
    local after_linux="${text#*"$linux_sentence"}"
    case "$after_linux" in
      *"$macos_sentence"*) ;;
      *) fail "README macos sentence is not after the linux sentence" ;;
    esac
  fi
  ok

  begin "ci runs the macos tests after linux"
  if [[ ! -f "$WORKFLOW" ]]; then
    fail "missing workflow"
  else
    local workflow rest
    workflow="$(cat "$WORKFLOW")"
    case "$workflow" in
      *"bash tests/linux/run-tests.sh"*) ;;
      *) fail "workflow missing linux tests" ;;
    esac
    case "$workflow" in
      *"bash tests/macos/run-tests.sh"*) ;;
      *) fail "workflow missing macos tests" ;;
    esac
    rest="${workflow#*"bash tests/linux/run-tests.sh"}"
    case "$rest" in
      *"bash tests/macos/run-tests.sh"*) ;;
      *) fail "macos tests are not after linux tests" ;;
    esac
    case "$workflow" in
      *"ubuntu-24.04"*) ;;
      *) fail "workflow is not ubuntu-24.04" ;;
    esac
  fi
  ok
}

test_package_direct() {
  begin "noop package exits 0 for every accepted action"
  local pair deployment action log got code lines
  for pair in "Install Install" "Install Update" "Repair Repair" "Uninstall Uninstall" "Uninstall Reinstall"; do
    deployment="${pair%% *}"
    action="${pair#* }"
    log="$(mktemp)"
    code=0
    RELIAN_PACKAGE_LOG="$log" bash "$PACKAGE" --deployment-type "$deployment" --action "$action" --pin-version 1.2.3 >/dev/null 2>"$log.err" || code=$?
    if [[ "$code" -ne 0 ]]; then
      fail "$pair exited $code"
      continue
    fi
    got="$(cat "$log")"
    if [[ "$got" != "deployment=${deployment} action=${action} pin=1.2.3" ]]; then
      fail "$pair log [$got]"
    fi
    lines="$(wc -l < "$log" | tr -d '[:space:]')"
    if [[ "$lines" -ne 1 ]]; then
      fail "$pair wrote $lines lines"
    fi
  done
  code=0
  env -u RELIAN_PACKAGE_LOG bash "$PACKAGE" --deployment-type Install --action Install --pin-version 1.2.3 >/dev/null || code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "unset log exited $code"
  fi
  code=0
  bash "$PACKAGE" --deployment-type Install --action Nope --pin-version 1.2.3 >/dev/null 2>&1 || code=$?
  if [[ "$code" -eq 0 ]]; then
    fail "unknown package action exited 0"
  fi
  code=0
  bash "$PACKAGE" --action Install --pin-version 1.2.3 >/dev/null 2>&1 || code=$?
  if [[ "$code" -eq 0 ]]; then
    fail "missing deployment type exited 0"
  fi
  ok
}

define_stubs() {
  relian_http_get() {
    local dest="$2"
    local i="$HTTP_INDEX"
    HTTP_INDEX=$((HTTP_INDEX + 1))
    DOWNLOADS=$((DOWNLOADS + 1))
    if [[ "$i" -ge ${#HTTP_STATUS[@]} ]]; then
      printf '500'
      return 0
    fi
    local body="${HTTP_BODY[$i]}"
    if [[ -n "$body" ]]; then
      cp -- "$body" "$dest"
    else
      : > "$dest"
    fi
    local status="${HTTP_STATUS[$i]}"
    if [[ -n "$status" ]]; then
      printf '%s' "$status"
    fi
    return "${HTTP_CODE[$i]}"
  }

  relian_sleep() {
    SLEEPS+=("$1")
  }
}

test_source_defines_functions() {
  begin "sourcing under test does not download"
  local bin code sentinel
  bin="$(mktemp -d)"
  sentinel="$bin/curl-called"
  cat > "$bin/curl" << 'EOF'
#!/bin/bash
: > "$CURL_SENTINEL"
printf 'curl-called\n' >&2
exit 99
EOF
  chmod +x "$bin/curl"
  code=0
  PATH="$bin:$PATH" CURL_SENTINEL="$sentinel" RELIAN_DEPLOY_TEST=1 \
    bash -c 'source "$1" || exit; type relian_runner_main >/dev/null; type relian_http_get >/dev/null; type relian_sleep >/dev/null' \
    _ "$RUNNER" >/dev/null || code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "source exited $code"
  fi
  if [[ -e "$sentinel" ]]; then
    fail "source called curl"
  fi
  ok
}

test_http_get_default() {
  begin "default http get uses curl and prints a real status"
  local bin dest code stdout args_file
  bin="$(mktemp -d)"
  dest="$(mktemp)"
  args_file="$(mktemp)"
  cat > "$bin/curl" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$CURL_ARGS"
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--output" ]]; then
    out="$arg"
  fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  printf 'x' > "$out"
fi
case "$CURL_MODE" in
  ok)
    printf '200'
    exit 0
    ;;
  missing)
    printf '000'
    exit 6
    ;;
  denied)
    printf '404'
    exit 0
    ;;
esac
exit 9
EOF
  chmod +x "$bin/curl"
  code=0
  stdout="$(
    CURL_MODE=ok CURL_ARGS="$args_file" RELIAN_DEPLOY_TEST=1 PATH="$bin:$PATH" \
      bash -c 'source "$1"; relian_http_get "$2" "$3"' _ "$RUNNER" "$PKG_URL" "$dest"
  )" || code=$?
  if [[ "$code" -ne 0 || "$stdout" != "200" ]]; then
    fail "ok status code=$code stdout=[$stdout]"
  fi
  local -a args=()
  local line
  while IFS= read -r line; do
    args+=("$line")
  done < "$args_file"
  local -a want=(
    --silent
    --show-error
    --max-time
    120
    --output
    "$dest"
    --write-out
    '%{http_code}'
    --
    "$PKG_URL"
  )
  local n="${#args[@]}"
  if [[ "$n" -ne ${#want[@]} ]]; then
    fail "curl argc $n"
  else
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
      if [[ "${args[$i]}" != "${want[$i]}" ]]; then
        fail "curl arg $i got [${args[$i]}] want [${want[$i]}]"
      fi
    done
  fi
  code=0
  stdout="$(
    CURL_MODE=missing CURL_ARGS="$args_file" RELIAN_DEPLOY_TEST=1 PATH="$bin:$PATH" \
      bash -c 'source "$1"; relian_http_get "$2" "$3"' _ "$RUNNER" "$PKG_URL" "$dest"
  )" || code=$?
  if [[ "$code" -ne 6 || -n "$stdout" ]]; then
    fail "missing response code=$code stdout=[$stdout]"
  fi
  code=0
  stdout="$(
    CURL_MODE=denied CURL_ARGS="$args_file" RELIAN_DEPLOY_TEST=1 PATH="$bin:$PATH" \
      bash -c 'source "$1"; relian_http_get "$2" "$3"' _ "$RUNNER" "$PKG_URL" "$dest"
  )" || code=$?
  if [[ "$code" -ne 0 || "$stdout" != "404" ]]; then
    fail "404 status code=$code stdout=[$stdout]"
  fi
  ok
}

test_execute_runs_download() {
  begin "executing the file downloads and runs the package"
  local bin dir log code line args_text
  bin="$(mktemp -d)"
  dir="$(mktemp -d)"
  log="$dir/log"
  cat > "$bin/curl" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$CURL_ARGS"
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--output" ]]; then
    out="$arg"
  fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  cp -- "$CURL_BODY" "$out"
fi
printf '200'
exit 0
EOF
  chmod +x "$bin/curl"
  code=0
  CURL_ARGS="$dir/args" CURL_BODY="$FIXTURE" PATH="$bin:$PATH" RELIAN_PACKAGE_LOG="$log" RELIAN_DEPLOY_TEST=1 \
    bash "$RUNNER" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Update --pin-version 1.2.3 \
    >"$dir/out" 2>"$dir/err" || code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "execute with test flag exited $code stderr=$(cat "$dir/err")"
  fi
  if [[ "$(cat "$log" 2>/dev/null || true)" != "deployment=Install action=Update pin=1.2.3" ]]; then
    fail "execute log [$(cat "$log" 2>/dev/null || true)]"
  fi
  code=0
  : > "$log"
  env -u RELIAN_DEPLOY_TEST CURL_ARGS="$dir/args" CURL_BODY="$FIXTURE" PATH="$bin:$PATH" RELIAN_PACKAGE_LOG="$log" \
    bash "$RUNNER" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3 \
    >"$dir/out" 2>"$dir/err" || code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "execute exited $code stderr=$(cat "$dir/err")"
  fi
  if [[ "$(cat "$log")" != "deployment=Install action=Install pin=1.2.3" ]]; then
    fail "plain execute log [$(cat "$log")]"
  fi
  ok
}

test_empty_hash() {
  local action url
  for action in Install Update Repair Reinstall Uninstall; do
    begin "empty hash $action skips download"
    reset_stubs
    local log
    log="$(mktemp)"
    url="$(url_user)"
    invoke_runner "$log" --package-url "$url" --package-sha256 "" --action "$action" --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 0 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
    fi
    if [[ -s "$log" ]]; then
      fail "package ran"
    fi
    ok

    begin "whitespace hash $action skips download"
    reset_stubs
    log="$(mktemp)"
    url="$(url_user_pw)"
    invoke_runner "$log" --package-url "$url" --package-sha256 $' \t ' --action "$action" --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 0 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
    fi
    ok
  done
}

test_userinfo() {
  local url
  begin "userinfo without a password is refused"
  reset_stubs
  local log
  log="$(mktemp)"
  url="$(url_user)"
  invoke_runner "$log" --package-url "$url" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  if [[ "$LAST_ERR" != "refusing a URL that contains userinfo" ]]; then
    fail "stderr [$LAST_ERR]"
  fi
  assert_no_url "$url" || true
  ok

  begin "userinfo with a password is refused"
  reset_stubs
  log="$(mktemp)"
  url="$(url_user_pw)"
  invoke_runner "$log" --package-url "$url" --package-sha256 "$FIXTURE_HASH" --action Uninstall --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  if [[ "$LAST_ERR" != "refusing a URL that contains userinfo" ]]; then
    fail "stderr [$LAST_ERR]"
  fi
  assert_no_url "$url" || true
  ok

  begin "at sign in the path is not userinfo"
  reset_stubs
  log="$(mktemp)"
  url="$(url_path_at)"
  queue_success
  invoke_runner "$log" --package-url "$url" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  ok

  begin "at sign in the query is not userinfo"
  reset_stubs
  log="$(mktemp)"
  url="$(url_query_at)"
  queue_success
  invoke_runner "$log" --package-url "$url" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  ok

  begin "empty userinfo is refused"
  reset_stubs
  log="$(mktemp)"
  url="$(url_empty_user)"
  invoke_runner "$log" --package-url "$url" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  if [[ "$LAST_ERR" != "refusing a URL that contains userinfo" ]]; then
    fail "stderr [$LAST_ERR]"
  fi
  assert_no_url "$url" || true
  ok

  begin "blank hash with empty userinfo does not download"
  reset_stubs
  log="$(mktemp)"
  url="$(url_empty_user)"
  invoke_runner "$log" --package-url "$url" --package-sha256 "" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  if [[ -s "$log" ]]; then
    fail "package ran"
  fi
  ok
}

test_hash_mismatch() {
  begin "hash mismatch does not run or retry"
  reset_stubs
  local log
  log="$(mktemp)"
  queue_success
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps || true
  if [[ -s "$log" ]]; then
    fail "package ran"
  fi
  if [[ "$LAST_ERR" != "hash mismatch for package" ]]; then
    fail "stderr [$LAST_ERR]"
  fi
  assert_no_url "$PKG_URL" || true
  ok

  begin "uppercase hash does not match"
  reset_stubs
  log="$(mktemp)"
  local upper
  upper="$(printf '%s' "$FIXTURE_HASH" | tr 'a-f' 'A-F')"
  queue_success
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$upper" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 1 || -s "$log" ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps || true
  if [[ "$LAST_ERR" != "hash mismatch for package" ]]; then
    fail "stderr [$LAST_ERR]"
  fi
  ok

  begin "hash mismatch after a retry is not downloaded again"
  reset_stubs
  log="$(mktemp)"
  queue_http 500 0 ""
  queue_http 200 0 "$FIXTURE"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 2 || -s "$log" ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps 5 || true
  ok
}

test_http_retries() {
  begin "HTTP 404 is one attempt"
  reset_stubs
  local log
  log="$(mktemp)"
  queue_http 404 0 ""
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 1 || -s "$log" ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps || true
  assert_no_url "$PKG_URL" || true
  ok

  local status
  for status in 403 400; do
    begin "HTTP $status is one attempt"
    reset_stubs
    log="$(mktemp)"
    queue_http "$status" 0 ""
    invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 1 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS"
    fi
    expect_sleeps || true
    ok
  done

  begin "HTTP 500 then 200 retries once and runs"
  reset_stubs
  log="$(mktemp)"
  queue_http 500 0 ""
  queue_http 200 0 "$FIXTURE"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 2 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  expect_sleeps 5 || true
  if [[ "$(cat "$log")" != "deployment=Install action=Install pin=1.2.3" ]]; then
    fail "log [$(cat "$log" 2>/dev/null || true)]"
  fi
  ok

  for status in 408 429 502 503 504; do
    begin "HTTP $status retries once"
    reset_stubs
    log="$(mktemp)"
    queue_http "$status" 0 ""
    queue_http 200 0 "$FIXTURE"
    invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Uninstall --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 2 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
    fi
    expect_sleeps 5 || true
    ok
  done

  begin "three HTTP 500 responses stop"
  reset_stubs
  log="$(mktemp)"
  queue_http 500 0 ""
  queue_http 500 0 ""
  queue_http 500 0 ""
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 3 || -s "$log" ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps 5 20 || true
  assert_no_url "$PKG_URL" || true
  ok

  begin "HTTP 500 twice then 200 sleeps 5 then 20"
  reset_stubs
  log="$(mktemp)"
  queue_http 500 0 ""
  queue_http 500 0 ""
  queue_http 200 0 "$FIXTURE"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 3 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  expect_sleeps 5 20 || true
  ok
}

test_curl_retries() {
  local curl_code
  for curl_code in 6 7 28 35; do
    begin "curl exit $curl_code retries"
    reset_stubs
    local log
    log="$(mktemp)"
    queue_http "" "$curl_code" ""
    queue_http 200 0 "$FIXTURE"
    invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 2 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
    fi
    expect_sleeps 5 || true
    ok
  done

  begin "curl exit 22 is one attempt"
  reset_stubs
  local log
  log="$(mktemp)"
  queue_http "" 22 ""
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 1 || -s "$log" ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  expect_sleeps || true
  ok

  begin "curl exit 6 twice then success sleeps 5 then 20"
  reset_stubs
  log="$(mktemp)"
  queue_http "000" 6 ""
  queue_http "000" 6 ""
  queue_http 200 0 "$FIXTURE"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 3 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  expect_sleeps 5 20 || true
  ok
}

test_actions() {
  local action want
  for action in Install Update Repair Uninstall; do
    begin "action $action reaches the package"
    reset_stubs
    local log
    log="$(mktemp)"
    case "$action" in
      Install) want="deployment=Install action=Install pin=1.2.3" ;;
      Update) want="deployment=Install action=Update pin=1.2.3" ;;
      Repair) want="deployment=Repair action=Repair pin=1.2.3" ;;
      Uninstall) want="deployment=Uninstall action=Uninstall pin=1.2.3" ;;
    esac
    queue_success
    invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action "$action" --pin-version 1.2.3
    if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 1 ]]; then
      fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
    fi
    if [[ "$(cat "$log")" != "$want" ]]; then
      fail "log [$(cat "$log")] want [$want]"
    fi
    ok
  done

  begin "reinstall runs uninstall then install"
  reset_stubs
  local log
  log="$(mktemp)"
  queue_success
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Reinstall --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  local got want
  got="$(cat "$log")"
  want="$(printf '%s\n%s' 'deployment=Uninstall action=Uninstall pin=1.2.3' 'deployment=Install action=Install pin=1.2.3')"
  if [[ "$got" != "$want" ]]; then
    fail "log [$got]"
  fi
  ok

  begin "failing uninstall skips install"
  reset_stubs
  log="$(mktemp)"
  queue_success
  RELIAN_FIXTURE_FAIL_UNINSTALL=1 invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Reinstall --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 9 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  if [[ "$(cat "$log")" != "deployment=Uninstall action=Uninstall pin=1.2.3" ]]; then
    fail "log [$(cat "$log")]"
  fi
  ok
}

test_missing_parameters() {
  local log args
  begin "missing package url does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "missing package sha256 does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --action Install --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "missing action does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "missing pin version does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "pin flag without a value does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "unknown action does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Drop --pin-version 1.2.3
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok

  begin "unknown parameter does not download"
  reset_stubs
  log="$(mktemp)"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3 --extra 1
  if [[ "$LAST_CODE" -ne 1 || "$DOWNLOADS" -ne 0 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS"
  fi
  ok
}

test_work_dir() {
  begin "work directory is removed"
  reset_stubs
  local scratch log left
  scratch="$(mktemp -d)"
  log="$(mktemp)"
  queue_success
  TMPDIR="$scratch" invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  left="$(find "$scratch" -mindepth 1 | wc -l | tr -d '[:space:]')"
  if [[ "$LAST_CODE" -ne 0 || "$left" -ne 0 ]]; then
    fail "code=$LAST_CODE left=$left err=[$LAST_ERR]"
  fi
  ok

  begin "keep work leaves the directory"
  reset_stubs
  scratch="$(mktemp -d)"
  log="$(mktemp)"
  queue_success
  RELIAN_DEPLOY_KEEP_WORK=1 TMPDIR="$scratch" invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$FIXTURE_HASH" --action Install --pin-version 1.2.3
  left="$(find "$scratch" -mindepth 1 -type d | wc -l | tr -d '[:space:]')"
  if [[ "$LAST_CODE" -ne 0 || "$left" -eq 0 ]]; then
    fail "code=$LAST_CODE left=$left"
  fi
  ok
}

test_digest_matches_release() {
  begin "runner digest matches the noop release hash"
  local hash json_hash
  hash="$(relian_sha256 "$PACKAGE")"
  json_hash="$(ROOT="$ROOT" node -e 'const fs=require("fs");const path=require("path");const j=JSON.parse(fs.readFileSync(path.join(process.env.ROOT,"macos","releases","noop.json"),"utf8"));process.stdout.write(String(j.sha256))')"
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    fail "digest [$hash]"
  fi
  if [[ "$hash" != "$json_hash" ]]; then
    fail "digest [$hash] != release [$json_hash]"
  fi
  ok
}

test_real_noop_through_runner() {
  begin "runner can run the noop package"
  reset_stubs
  local log hash
  log="$(mktemp)"
  hash="$(relian_sha256 "$PACKAGE")"
  queue_http 200 0 "$PACKAGE"
  invoke_runner "$log" --package-url "$PKG_URL" --package-sha256 "$hash" --action Repair --pin-version 9
  if [[ "$LAST_CODE" -ne 0 || "$DOWNLOADS" -ne 1 ]]; then
    fail "code=$LAST_CODE downloads=$DOWNLOADS err=[$LAST_ERR]"
  fi
  if [[ "$(cat "$log")" != "deployment=Repair action=Repair pin=9" ]]; then
    fail "log [$(cat "$log" 2>/dev/null || true)]"
  fi
  ok
}

test_static_files

if [[ -f "$PACKAGE" ]]; then
  test_package_direct
fi

if [[ -f "$RUNNER" && -f "$PACKAGE" ]]; then
  export RELIAN_DEPLOY_TEST=1
  # shellcheck disable=SC1090
  source "$RUNNER"
  define_stubs
  setup_fixture
  test_source_defines_functions
  test_http_get_default
  test_execute_runs_download
  test_empty_hash
  test_userinfo
  test_hash_mismatch
  test_http_retries
  test_curl_retries
  test_actions
  test_missing_parameters
  test_work_dir
  test_digest_matches_release
  test_real_noop_through_runner
fi

printf 'SUMMARY passed=%s failed=%s\n' "$PASSES" "$FAILURES"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
exit 0
