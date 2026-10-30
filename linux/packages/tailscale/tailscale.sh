#!/bin/bash
# Tailscale for Debian and Proxmox VE hosts. The runner passes only
# --deployment-type, --action, and --pin-version, so the rest comes from
# NinjaOne script variables on the runner, which arrive as environment variables:
#   ClientTag     the tag to advertise, such as tag:client-example (required)
#   AuthKey       the auth key; when empty, the Secure custom field is read
#   AuthKeyField  the Secure custom field name, default tailscaleAuthKey
# The pin version is a floor. apt installs the newest version in the repo.
# The key never goes on a command line: tailscale reads it from a 0600 file.
# Nothing else on the host is changed: no firewall, no sshd, no PVE config.

TS_REPO='https://pkgs.tailscale.com/stable/debian'
# sha256 of <codename>.noarmor.gpg, the same file for both codenames.
# Primary key fingerprint 2596A99EAAB33821893C0A79458CA832957F5868 (see linux/releases/tailscale.json).
TS_SIGNER_SHA256='3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'
TS_CODENAMES='bookworm trixie'
TS_KEYRING='/usr/share/keyrings/tailscale-archive-keyring.gpg'
TS_LIST='/etc/apt/sources.list.d/tailscale.list'
TS_KEY_DIR=''
TS_NINJA_MISSING=0

ts_error() {
  printf '%s\n' "$1" >&2
}

ts_is_blank() {
  [[ -z "${1//[[:space:]]/}" ]]
}

ts_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

ts_valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# True when $1 is a lower version than $2.
ts_version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

ts_valid_tag() {
  [[ "$1" =~ ^tag:[A-Za-z][A-Za-z0-9-]*$ ]]
}

ts_valid_key() {
  local re='^tskey-[^[:space:]"]+$'
  [[ "$1" =~ $re ]]
}

# First non-empty variable among the names given. NinjaOne's variable name casing is not documented here.
ts_first_env() {
  local name
  for name in "$@"; do
    if ! ts_is_blank "${!name:-}"; then
      ts_trim "${!name}"
      return 0
    fi
  done
  return 0
}

# Pure. Sets PLAN_EXIT (empty when there is work), PLAN_INSTALL (0/1),
# PLAN_JOIN (none, key, up, set), and PLAN_REASON.
ts_plan() {
  local action="$1" pin="$2" installed="$3" state="$4" tags="$5" has_key="$6" tag="$7"
  PLAN_EXIT=''
  PLAN_INSTALL=0
  PLAN_JOIN='none'
  PLAN_REASON=''
  if ts_is_blank "$pin"; then
    PLAN_EXIT=0
    return 0
  fi
  if ! ts_valid_version "$pin"; then
    PLAN_EXIT=1; PLAN_REASON='invalid pin version'; return 0
  fi
  case "$action" in
    Install|Update|Repair) ;;
    *) PLAN_EXIT=1; PLAN_REASON="action $action is not supported"; return 0 ;;
  esac
  if ! ts_valid_tag "$tag"; then
    PLAN_EXIT=1; PLAN_REASON='ClientTag must look like tag:client-name'; return 0
  fi
  if [[ -n "$installed" ]] && ! ts_valid_version "$installed"; then
    PLAN_EXIT=1; PLAN_REASON='installed Tailscale version is unreadable'; return 0
  fi
  if [[ "$state" == 'Unreadable' ]]; then
    PLAN_EXIT=1; PLAN_REASON='could not read tailscale status; not joining'; return 0
  fi
  # A node joined under any other identity is never re-joined.
  if [[ -n "$tags" && "$tags" != "$tag" ]]; then
    PLAN_EXIT=1; PLAN_REASON="node has tags $tags, wanted $tag; not re-joining"; return 0
  fi
  if [[ "$state" == 'Running' && "$tags" != "$tag" ]]; then
    PLAN_EXIT=1; PLAN_REASON="node is joined without $tag; not re-joining"; return 0
  fi
  if [[ -z "$installed" ]] || ts_version_lt "$installed" "$pin"; then
    PLAN_INSTALL=1
  fi
  if [[ "$state" == 'Running' ]]; then
    PLAN_JOIN='set'
  elif [[ "$tags" == "$tag" ]]; then
    PLAN_JOIN='up'
  else
    PLAN_JOIN='key'
    if [[ "$has_key" != 1 ]]; then
      PLAN_EXIT=1
      PLAN_REASON='a join is needed and no auth key was found in the AuthKey script variable or the auth key custom field'
    fi
  fi
  return 0
}

# Prints "STATE TAGS" from `tailscale status --json`, or "Unreadable".
ts_parse_status() {
  local line
  line="$(perl -MJSON::PP -e '
    local $/; my $j = eval { decode_json(<STDIN>) };
    exit 3 unless ref $j eq "HASH" && defined $j->{BackendState} && length $j->{BackendState};
    my $t = (ref $j->{Self} eq "HASH" && ref $j->{Self}{Tags} eq "ARRAY") ? join(",", @{$j->{Self}{Tags}}) : "";
    print "$j->{BackendState} $t\n";' 2>/dev/null)" || line=''
  if [[ -z "$line" ]]; then
    printf 'Unreadable \n'
    return 0
  fi
  printf '%s\n' "$line"
}

# Machine calls. Tests replace each of these.
ts_is_root() { [[ "$(id -u)" -eq 0 ]]; }
# shellcheck disable=SC1091
ts_codename() { (. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}"); }
ts_short_hostname() { hostname -s; }
ts_installed_version() {
  local line
  line="$(dpkg-query -W -f='${Status} ${Version}' tailscale 2>/dev/null)" || return 0
  case "$line" in
    'install ok installed '*) printf '%s' "${line##* }" ;;
  esac
}
ts_has_cli() { command -v tailscale > /dev/null 2>&1; }
ts_status_json() { tailscale status --json --peers=false 2>/dev/null; }
# Prints the HTTP status. Returns curl's exit code.
ts_curl() { curl -sS --max-time 120 -o "$2" -w '%{http_code}' -- "$1"; }
ts_sleep() { sleep "$1"; }
ts_apt_update() {
  # Only the Tailscale source: a Proxmox enterprise repo with no subscription fails a full update.
  apt-get update -q -o Dir::Etc::sourcelist="$TS_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
}
ts_apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q tailscale; }
ts_enable_service() { systemctl enable --now tailscaled; }
ts_tailscale() { tailscale "$@"; }
ts_ninja_get() {
  local cli="${NINJA_DATA_PATH:-/opt/NinjaRMMAgent/programdata}/ninjarmm-cli"
  if [[ ! -x "$cli" ]]; then
    TS_NINJA_MISSING=1
    return 1
  fi
  # Exit 1 prints an error description, which must not be taken as the key.
  "$cli" get "$1" 2>/dev/null
}

# Three attempts, as in the runner: retry curl proxy DNS, DNS, connection, timeout,
# and TLS connect failures (5, 6, 7, 28, 35) and HTTP 408, 429, 500, 502, 503, 504 only.
ts_fetch() {
  local url="$1" dest="$2" attempt status code
  for attempt in 1 2 3; do
    code=0
    status="$(ts_curl "$url" "$dest")" || code=$?
    if [[ "$code" -eq 0 && "$status" == '200' ]]; then
      return 0
    fi
    rm -f -- "$dest"
    case "$code/$status" in
      0/408|0/429|0/500|0/502|0/503|0/504|5/*|6/*|7/*|28/*|35/*) ;;
      *) return 1 ;;
    esac
    if [[ "$attempt" -eq 1 ]]; then
      ts_sleep 5
    elif [[ "$attempt" -eq 2 ]]; then
      ts_sleep 20
    fi
  done
  return 1
}

ts_cleanup_key() {
  if [[ -n "$TS_KEY_DIR" ]]; then
    rm -rf -- "$TS_KEY_DIR"
    TS_KEY_DIR=''
  fi
}

ts_install() {
  local codename tmp line
  codename="$(ts_codename)"
  case " $TS_CODENAMES " in
    *" $codename "*) ;;
    *) ts_error "unsupported Debian codename [$codename]"; return 1 ;;
  esac
  tmp="$(mktemp -d)" || return 1
  if ! ts_fetch "$TS_REPO/$codename.noarmor.gpg" "$tmp/key.gpg"; then
    rm -rf -- "$tmp"; ts_error 'download failed for the repository key'; return 1
  fi
  if [[ "$(sha256sum -- "$tmp/key.gpg" | cut -d ' ' -f 1)" != "$TS_SIGNER_SHA256" ]]; then
    rm -rf -- "$tmp"; ts_error 'hash mismatch for the repository key'; return 1
  fi
  if ! cmp -s -- "$tmp/key.gpg" "$TS_KEYRING"; then
    install -m 0644 -- "$tmp/key.gpg" "$TS_KEYRING" || { rm -rf -- "$tmp"; return 1; }
  fi
  rm -rf -- "$tmp"
  line="deb [signed-by=$TS_KEYRING] $TS_REPO $codename main"
  if [[ "$(cat -- "$TS_LIST" 2>/dev/null)" != "$line" ]]; then
    printf '%s\n' "$line" > "$TS_LIST" && chmod 0644 -- "$TS_LIST" || return 1
  fi
  ts_apt_update || { ts_error 'apt-get update failed for the Tailscale source'; return 1; }
  ts_apt_install || { ts_error 'apt-get install tailscale failed'; return 1; }
  ts_enable_service || { ts_error 'could not start tailscaled'; return 1; }
  return 0
}

# Runs tailscale, prints its output to stderr with the key blanked, returns its code.
ts_run_redacted() {
  local key="$1" out code=0
  shift
  out="$(ts_tailscale "$@" 2>&1)" || code=$?
  if [[ -n "$key" ]]; then
    out="${out//"$key"/[redacted]}"
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" >&2
  fi
  return "$code"
}

ts_main() {
  local deployment='' action='' pin='' seen=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deployment-type|--action|--pin-version)
        [[ $# -ge 2 ]] || return 1
        case "$1" in
          --deployment-type) deployment="$2" ;;
          --action) action="$2" ;;
          --pin-version) pin="$2" ;;
        esac
        seen=$((seen + 1))
        shift 2
        ;;
      *) ts_error 'unknown parameter'; return 1 ;;
    esac
  done
  if [[ "$seen" -ne 3 || -z "$deployment" ]]; then
    ts_error 'missing parameter'
    return 1
  fi
  # An empty pin disables the package before anything is read.
  if ts_is_blank "$pin"; then
    return 0
  fi

  local tag field key has_key=0
  tag="$(ts_first_env ClientTag clientTag clienttag)"
  field="$(ts_first_env AuthKeyField authKeyField authkeyfield)"
  [[ -n "$field" ]] || field='tailscaleAuthKey'
  key="$(ts_first_env AuthKey authKey authkey)"
  unset AuthKey authKey authkey
  if [[ -z "$key" ]]; then
    # Not in a command substitution, so TS_NINJA_MISSING survives.
    local field_file
    field_file="$(mktemp)" || return 1
    if ts_ninja_get "$field" > "$field_file"; then
      key="$(ts_trim "$(cat -- "$field_file")")"
    fi
    rm -f -- "$field_file"
  fi
  if [[ -n "$key" ]]; then
    if ! ts_valid_key "$key"; then
      key=''
      ts_error 'the auth key is not a Tailscale auth key'
      return 1
    fi
    has_key=1
  fi
  if ! ts_is_root; then
    ts_error 'must run as root'
    return 1
  fi

  local pass installed status state tags fresh=0 host code
  host="$(ts_short_hostname)"
  for pass in 1 2; do
    installed="$(ts_installed_version)"
    if ts_has_cli; then
      status="$(ts_status_json | ts_parse_status)"
    else
      status=' '
    fi
    state="${status%% *}"
    tags="${status#* }"
    if [[ "$pass" -eq 1 && -z "$state" ]]; then
      fresh=1
    elif [[ "$pass" -eq 2 && "$fresh" -eq 1 && "$state" == 'Unreadable' ]]; then
      # tailscaled may still be starting. There was no CLI before, so no identity to keep.
      state=''
      tags=''
    fi
    ts_plan "$action" "$pin" "$installed" "$state" "$tags" "$has_key" "$tag"
    if [[ -n "$PLAN_EXIT" ]]; then
      [[ -z "$PLAN_REASON" ]] || ts_error "$PLAN_REASON"
      if [[ "$PLAN_EXIT" -ne 0 && "$has_key" -eq 0 && "$TS_NINJA_MISSING" -eq 1 ]]; then
        ts_error 'ninjarmm-cli was not found in the package process'
      fi
      key=''
      return "$PLAN_EXIT"
    fi
    if [[ "$PLAN_INSTALL" -eq 1 ]]; then
      if [[ "$pass" -eq 2 ]]; then
        ts_error 'Tailscale is still below the pin after install'
        return 1
      fi
      ts_install || return 1
      continue
    fi
    local prefs=("--hostname=$host" '--accept-dns=false' '--accept-routes=false' '--ssh=false')
    code=0
    case "$PLAN_JOIN" in
      set)
        ts_run_redacted '' set "${prefs[@]}" || code=$?
        ;;
      up)
        ts_run_redacted '' up "--advertise-tags=$tag" "${prefs[@]}" '--timeout=120s' || code=$?
        ;;
      key)
        TS_KEY_DIR="$(mktemp -d)" || return 1
        trap ts_cleanup_key EXIT
        (umask 077 && printf '%s' "$key" > "$TS_KEY_DIR/key") || { ts_cleanup_key; return 1; }
        ts_run_redacted "$key" up "--auth-key=file:$TS_KEY_DIR/key" "--advertise-tags=$tag" "${prefs[@]}" '--reset' '--timeout=120s' || code=$?
        ts_cleanup_key
        ;;
    esac
    key=''
    if [[ "$code" -ne 0 ]]; then
      ts_error "tailscale $PLAN_JOIN failed with $code"
      return 1
    fi
    return 0
  done
  return 0
}

# Sourcing defines the functions and does nothing else.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -uo pipefail
code=0
ts_main "$@" || code=$?
exit "$code"
