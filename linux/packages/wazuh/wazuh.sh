#!/bin/bash
# Wazuh agent for Debian, Ubuntu, Proxmox VE (apt) and Fedora/RHEL family (dnf).
# The runner passes only --deployment-type, --action, and --pin-version, so the rest
# comes from environment variables (package arguments, or whatever starts the runner):
#   WazuhManager       manager address (required)
#   WazuhGroup         agent group(s), such as default,client-group (required)
#   WazuhNamePrefix    agent name is <prefix>--<short hostname> (required)
#   WazuhPasswordFile  path to a root-only file holding the enrolment password.
#                      Needed only when the agent must enrol. Never read onto a
#                      command line or printed.
# The pin version is a floor (the release record pins 4.14.3; an empty pin disables). The package never downgrades: an
# agent at or above the floor is kept, because the manager's WPK upgrades own versions.
# It never re-enrols while /var/ossec/etc/client.keys has content.
# The agent package is held (apt-mark hold / dnf versionlock) so unattended upgrades
# never pass the manager. No firewall, sshd, or PVE config is touched.

WZ_KEY_URL='https://packages.wazuh.com/key/GPG-KEY-WAZUH'
# Primary key "Wazuh.com (Wazuh Signing Key) <support@wazuh.com>", expires 2027-05-15.
WZ_KEY_FPR='0DCF CA55 47B1 9D2A 6099  5060 96B3 EE5F 2911 1145'
WZ_KEY_FPR="${WZ_KEY_FPR// /}"
WZ_APT_REPO='https://packages.wazuh.com/4.x/apt/'
WZ_KEYRING='/usr/share/keyrings/wazuh-archive-keyring.gpg'
WZ_LIST='/etc/apt/sources.list.d/wazuh.list'
WZ_YUM_REPO='https://packages.wazuh.com/4.x/yum/'
WZ_RPM_KEY='/etc/pki/rpm-gpg/RPM-GPG-KEY-WAZUH'
WZ_REPO_FILE='/etc/yum.repos.d/wazuh.repo'
WZ_KEYS='/var/ossec/etc/client.keys'
WZ_PASS='/var/ossec/etc/authd.pass'
WZ_CONF='/var/ossec/etc/ossec.conf'

wz_error() {
  printf '%s\n' "$1" >&2
}

wz_is_blank() {
  [[ -z "${1//[[:space:]]/}" ]]
}

wz_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

wz_valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Letters, digits, dot, comma, dash, underscore: safe in sed, a file name, and a hostname.
wz_valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9._,-]+$ ]]
}

# True when $1 is a lower version than $2.
wz_version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Pure. Sets PLAN_EXIT (empty when there is work), PLAN_INSTALL (0/1),
# PLAN_ENROL (0/1), and PLAN_REASON.
wz_plan() {
  local action="$1" floor="$2" installed="$3" keys="$4" manager="$5" group="$6" prefix="$7" passfile="$8"
  PLAN_EXIT=''
  PLAN_INSTALL=0
  PLAN_ENROL=0
  PLAN_REASON=''
  case "$action" in
    Install|Update|Repair) ;;
    *) PLAN_EXIT=1; PLAN_REASON="action $action is not supported"; return 0 ;;
  esac
  if ! wz_valid_version "$floor"; then
    PLAN_EXIT=1; PLAN_REASON='invalid pin version'; return 0
  fi
  local name value
  for name in manager group prefix; do
    value="${!name}"
    if wz_is_blank "$value"; then
      PLAN_EXIT=1; PLAN_REASON="the Wazuh $name environment variable is empty"; return 0
    fi
    if ! wz_valid_token "$value"; then
      PLAN_EXIT=1; PLAN_REASON="the Wazuh $name value has characters that are not allowed"; return 0
    fi
  done
  if [[ -n "$installed" ]] && ! wz_valid_version "$installed"; then
    PLAN_EXIT=1; PLAN_REASON='installed Wazuh version is unreadable'; return 0
  fi
  # Never downgrade: only a missing or lower agent is installed.
  if [[ -z "$installed" ]] || wz_version_lt "$installed" "$floor"; then
    PLAN_INSTALL=1
  fi
  # Never re-enrol: an agent with keys keeps them.
  if [[ "$keys" != 1 ]]; then
    PLAN_ENROL=1
    if wz_is_blank "$passfile"; then
      PLAN_EXIT=1; PLAN_REASON='enrolment is needed and the WazuhPasswordFile environment variable is empty'
    fi
  fi
  return 0
}

# Machine calls. Tests replace each of these.
wz_is_root() { [[ "$(id -u)" -eq 0 ]]; }
wz_short_hostname() { hostname -s; }
wz_pkg_manager() {
  if command -v apt-get > /dev/null 2>&1; then printf 'apt'
  elif command -v dnf > /dev/null 2>&1; then printf 'dnf'
  fi
}
# Upstream version (4.14.3) or nothing.
wz_installed_version() {
  local line
  if [[ "$(wz_pkg_manager)" == 'apt' ]]; then
    line="$(dpkg-query -W -f='${Status} ${Version}' wazuh-agent 2>/dev/null)" || return 0
    case "$line" in
      # A held package reports "hold ok installed".
      'install ok installed '*|'hold ok installed '*) line="${line##* }"; printf '%s' "${line%%-*}" ;;
    esac
  else
    rpm -q --qf '%{VERSION}' wazuh-agent 2>/dev/null | grep -E '^[0-9]' || true
  fi
}
wz_have_gpg() { command -v gpg > /dev/null 2>&1; }
wz_keys_present() { [[ -s "$WZ_KEYS" ]]; }
# Prints the HTTP status. Returns curl's exit code.
wz_curl() { curl -sS --max-time 120 -o "$2" -w '%{http_code}' -- "$1"; }
wz_sleep() { sleep "$1"; }
# Prints the primary key fingerprint when the file holds exactly one public key, else nothing.
wz_key_fpr() {
  local out
  out="$(gpg --show-keys --with-colons -- "$1" 2>/dev/null)" || return 0
  [[ "$(printf '%s\n' "$out" | grep -c '^pub:')" -eq 1 ]] || return 0
  printf '%s\n' "$out" | awk -F: '/^fpr:/{print $10; exit}'
}
wz_apt_update() {
  # Only the Wazuh source: a Proxmox enterprise repo with no subscription fails a full update.
  apt-get update -q -o Dir::Etc::sourcelist="$WZ_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
}
wz_pkg_install() {
  if [[ "$(wz_pkg_manager)" == 'apt' ]]; then
    apt-mark unhold wazuh-agent > /dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "wazuh-agent=$1-1"
  else
    dnf versionlock delete wazuh-agent > /dev/null 2>&1 || true
    dnf install -y -q "wazuh-agent-$1-1"
  fi
}
wz_hold() {
  if [[ "$(wz_pkg_manager)" == 'apt' ]]; then
    apt-mark hold wazuh-agent > /dev/null
  else
    dnf install -y -q python3-dnf-plugin-versionlock && dnf versionlock add wazuh-agent > /dev/null
  fi
}
wz_dearmor() { gpg --dearmor --output "$2" -- "$1"; }
# $1 file with the password. Copied, never read into a variable or a command line.
wz_install_password() {
  install -m 0640 -o root -g wazuh -- "$1" "$WZ_PASS"
}
wz_set_manager() {
  sed -i "s|<address>[^<]*</address>|<address>$1</address>|" "$WZ_CONF"
}
# agent-auth reads the password from etc/authd.pass, so none is passed. -G is the
# enrolment group; -g would mean the OS group to run as.
wz_agent_auth() { /var/ossec/bin/agent-auth -m "$1" -G "$2" -A "$3"; }
wz_enable_service() { systemctl enable --now wazuh-agent; }
# $1 path. Prints "OWNER MODE TYPE" so the policy check stays pure.
wz_stat_pass() {
  if [[ -L "$1" ]]; then printf '0 000 link'; return 0; fi
  if [[ ! -f "$1" ]]; then printf '0 000 missing'; return 0; fi
  printf '%s %s %s' "$(stat -c '%u' -- "$1")" "$(stat -c '%a' -- "$1")" "$([[ -s "$1" ]] && printf file || printf empty)"
}

# Root-owned regular non-empty file with no group or other access.
wz_check_passfile() {
  local owner mode kind
  read -r owner mode kind <<< "$(wz_stat_pass "$1")"
  [[ "$kind" == 'file' ]] || { wz_error "WazuhPasswordFile is not a non-empty regular file (not a link)"; return 1; }
  [[ "$owner" == '0' ]] || { wz_error 'WazuhPasswordFile must be owned by root'; return 1; }
  [[ "$mode" =~ ^[0-7]?[0-7]00$ ]] || { wz_error 'WazuhPasswordFile must not be readable by group or others (mode 600)'; return 1; }
  return 0
}

# Three attempts, as in the runner: retry transient curl and HTTP failures only.
wz_fetch() {
  local url="$1" dest="$2" attempt status code
  for attempt in 1 2 3; do
    code=0
    status="$(wz_curl "$url" "$dest")" || code=$?
    if [[ "$code" -eq 0 && "$status" == '200' ]]; then
      return 0
    fi
    rm -f -- "$dest"
    case "$code/$status" in
      0/408|0/429|0/500|0/502|0/503|0/504|5/*|6/*|7/*|28/*|35/*) ;;
      *) return 1 ;;
    esac
    if [[ "$attempt" -eq 1 ]]; then
      wz_sleep 5
    elif [[ "$attempt" -eq 2 ]]; then
      wz_sleep 20
    fi
  done
  return 1
}

# Adds the repo with its key pinned by fingerprint, then installs the floor version.
wz_install() {
  local floor="$1" tmp pm
  pm="$(wz_pkg_manager)"
  [[ -n "$pm" ]] || { wz_error 'neither apt-get nor dnf found'; return 1; }
  wz_have_gpg || { wz_error 'gpg is required to verify the repository key'; return 1; }
  tmp="$(mktemp -d)" || return 1
  if ! wz_fetch "$WZ_KEY_URL" "$tmp/key.asc"; then
    rm -rf -- "$tmp"; wz_error 'download failed for the repository key'; return 1
  fi
  if [[ "$(wz_key_fpr "$tmp/key.asc")" != "$WZ_KEY_FPR" ]]; then
    rm -rf -- "$tmp"; wz_error 'fingerprint mismatch for the repository key'; return 1
  fi
  if [[ "$pm" == 'apt' ]]; then
    if ! wz_dearmor "$tmp/key.asc" "$tmp/key.gpg" || [[ "$(wz_key_fpr "$tmp/key.gpg")" != "$WZ_KEY_FPR" ]]; then
      rm -rf -- "$tmp"; wz_error 'could not prepare the repository key'; return 1
    fi
    install -m 0644 -- "$tmp/key.gpg" "$WZ_KEYRING" || { rm -rf -- "$tmp"; return 1; }
    printf '%s\n' "deb [signed-by=$WZ_KEYRING] $WZ_APT_REPO stable main" > "$WZ_LIST" || { rm -rf -- "$tmp"; return 1; }
    chmod 0644 -- "$WZ_LIST"
    rm -rf -- "$tmp"
    wz_apt_update || { wz_error 'apt-get update failed for the Wazuh source'; return 1; }
  else
    install -m 0644 -- "$tmp/key.asc" "$WZ_RPM_KEY" || { rm -rf -- "$tmp"; return 1; }
    rm -rf -- "$tmp"
    printf '[wazuh]\nname=Wazuh repository\nbaseurl=%s\ngpgcheck=1\ngpgkey=file://%s\nenabled=1\n' "$WZ_YUM_REPO" "$WZ_RPM_KEY" > "$WZ_REPO_FILE" \
      || return 1
  fi
  wz_pkg_install "$floor" || { wz_error 'installing wazuh-agent failed'; return 1; }
  return 0
}

wz_enrol() {
  local manager="$1" group="$2" name="$3" passfile="$4"
  wz_check_passfile "$passfile" || return 1
  wz_install_password "$passfile" || { wz_error 'could not write authd.pass'; return 1; }
  wz_set_manager "$manager" || { wz_error 'could not set the manager address'; return 1; }
  wz_agent_auth "$manager" "$group" "$name" || { wz_error 'enrolment failed'; return 1; }
  wz_keys_present || { wz_error 'enrolment left no client key'; return 1; }
  wz_enable_service || { wz_error 'could not start wazuh-agent'; return 1; }
  return 0
}

wz_main() {
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
      *) wz_error 'unknown parameter'; return 1 ;;
    esac
  done
  if [[ "$seen" -ne 3 || -z "$deployment" ]]; then
    wz_error 'missing parameter'
    return 1
  fi
  pin="$(wz_trim "$pin")"
  # An empty pin disables the package before anything is read, as in the other Linux packages.
  if [[ -z "$pin" ]]; then
    return 0
  fi

  local manager group prefix passfile
  manager="$(wz_trim "${WazuhManager:-}")"
  group="$(wz_trim "${WazuhGroup:-}")"
  prefix="$(wz_trim "${WazuhNamePrefix:-}")"
  passfile="$(wz_trim "${WazuhPasswordFile:-}")"
  if ! wz_is_root; then
    wz_error 'must run as root'
    return 1
  fi

  local installed keys=0
  installed="$(wz_installed_version)"
  if wz_keys_present; then keys=1; fi
  wz_plan "$action" "$pin" "$installed" "$keys" "$manager" "$group" "$prefix" "$passfile"
  if [[ -n "$PLAN_EXIT" ]]; then
    [[ -z "$PLAN_REASON" ]] || wz_error "$PLAN_REASON"
    return "$PLAN_EXIT"
  fi
  if [[ "$PLAN_ENROL" -eq 1 ]]; then
    wz_check_passfile "$passfile" || return 1
  fi
  if [[ "$PLAN_INSTALL" -eq 1 ]]; then
    wz_install "$pin" || return 1
    installed="$(wz_installed_version)"
    if [[ -z "$installed" ]] || wz_version_lt "$installed" "$pin"; then
      wz_error 'Wazuh is still below the pin after install'
      return 1
    fi
  fi
  if [[ "$PLAN_ENROL" -eq 1 ]]; then
    wz_enrol "$manager" "$group" "$prefix--$(wz_short_hostname)" "$passfile" || return 1
  fi
  # A package upgrade of a keyed agent must leave it running; enrolment already starts it.
  if [[ "$PLAN_INSTALL" -eq 1 && "$PLAN_ENROL" -eq 0 ]]; then
    wz_enable_service || { wz_error 'could not start wazuh-agent'; return 1; }
  fi
  wz_hold || { wz_error 'could not hold wazuh-agent'; return 1; }
  return 0
}

# Sourcing defines the functions and does nothing else.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -uo pipefail
code=0
wz_main "$@" || code=$?
exit "$code"
