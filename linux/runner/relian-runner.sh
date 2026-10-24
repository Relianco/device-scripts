#!/bin/bash
# Linux package runner. Paste this file. It downloads one package script.

relian_error() {
  printf '%s\n' "$1" >&2
}

relian_is_blank() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ -z "$value" ]]
}

# Userinfo is an @ in the authority, including an empty name. An @ in the path or query is not.
relian_url_has_userinfo() {
  local url="$1"
  local rest="$url"
  local auth=""
  case "$url" in
    *://*) ;;
    *) return 1 ;;
  esac
  rest="${url#*://}"
  auth="$rest"
  auth="${auth%%/*}"
  auth="${auth%%\?*}"
  auth="${auth%%#*}"
  case "$auth" in
    *@*) return 0 ;;
  esac
  return 1
}

relian_temp_root() {
  local root="${TMPDIR:-/tmp}"
  root="${root%/}"
  if [[ -z "$root" ]]; then
    root="/tmp"
  fi
  printf '%s' "$root"
}

relian_remove_work() {
  local root="$1"
  local dir="$2"
  if [[ "${RELIAN_DEPLOY_KEEP_WORK:-}" == "1" ]]; then
    return 0
  fi
  case "$dir" in
    "$root"/*)
      rm -rf -- "$dir" || true
      ;;
  esac
  return 0
}

relian_should_retry() {
  local code="$1"
  local status="$2"
  if relian_status_is_http "$status"; then
    case "$status" in
      408|429|500|502|503|504) return 0 ;;
    esac
    return 1
  fi
  case "$code" in
    6|7|28|35) return 0 ;;
  esac
  return 1
}

relian_status_is_http() {
  case "$1" in
    [1-9][0-9][0-9]) return 0 ;;
  esac
  return 1
}

# Prints the HTTP status when a response arrived. Returns curl's exit code.
# 000 means curl got no response, so it is not printed.
relian_http_get() {
  local url="$1"
  local dest="$2"
  local status=""
  local code=0
  status="$(command curl --silent --show-error --max-time 120 --output "$dest" --write-out '%{http_code}' -- "$url")" || code=$?
  status="${status//[[:space:]]/}"
  case "$status" in
    ''|000) ;;
    [0-9][0-9][0-9])
      printf '%s\n' "$status"
      ;;
  esac
  return "$code"
}

relian_sleep() {
  sleep "$1"
}

relian_sha256() {
  local file="$1"
  local line=""
  line="$(sha256sum -- "$file")" || return 1
  line="${line%%[[:space:]]*}"
  printf '%s' "$line" | tr '[:upper:]' '[:lower:]'
}

# Three attempts. Sleep 5 seconds, then 20. Any other status is one attempt.
relian_download() {
  local url="$1"
  local dest="$2"
  local attempt=1
  local status=""
  local code=0
  local status_file="${dest}.http"
  while [[ "$attempt" -le 3 ]]; do
    status=""
    code=0
    # Redirect, not a command substitution: a test double must run in this shell.
    relian_http_get "$url" "$dest" > "$status_file" || code=$?
    status="$(cat "$status_file" 2>/dev/null || true)"
    rm -f -- "$status_file"
    status="${status//[[:space:]]/}"
    if [[ "$code" -eq 0 && "$status" == "200" ]]; then
      return 0
    fi
    if ! relian_should_retry "$code" "$status" || [[ "$attempt" -eq 3 ]]; then
      if relian_status_is_http "$status"; then
        relian_error "download failed with HTTP ${status} for package"
      else
        relian_error "download failed for package"
      fi
      return 1
    fi
    rm -f -- "$dest"
    if [[ "$attempt" -eq 1 ]]; then
      relian_sleep 5
    else
      relian_sleep 20
    fi
    attempt=$((attempt + 1))
  done
  relian_error "download failed for package"
  return 1
}

# Case-sensitive compare. The digest is lowercase, so an upper-case hash does not match.
relian_verify_hash() {
  local dest="$1"
  local expected="$2"
  local actual=""
  local hash_code=0
  if [[ ! -f "$dest" ]]; then
    relian_error "download wrote no file for package"
    return 1
  fi
  actual="$(relian_sha256 "$dest")" || hash_code=$?
  if [[ "$hash_code" -ne 0 || "$actual" != "$expected" ]]; then
    relian_error "hash mismatch for package"
    return 1
  fi
  return 0
}

relian_invoke() {
  local script="$1"
  local deployment="$2"
  local step="$3"
  local pin="$4"
  local code=0
  command bash -- "$script" --deployment-type "$deployment" --action "$step" --pin-version "$pin" || code=$?
  return "$code"
}

# Update uses deployment type Install. Reinstall is Uninstall, then Install.
# A non-zero uninstall skips the install. Do not pass action Reinstall through.
relian_dispatch() {
  local script="$1"
  local action="$2"
  local pin="$3"
  case "$action" in
    Install)
      relian_invoke "$script" Install Install "$pin" || return $?
      ;;
    Update)
      relian_invoke "$script" Install Update "$pin" || return $?
      ;;
    Repair)
      relian_invoke "$script" Repair Repair "$pin" || return $?
      ;;
    Uninstall)
      relian_invoke "$script" Uninstall Uninstall "$pin" || return $?
      ;;
    Reinstall)
      relian_invoke "$script" Uninstall Uninstall "$pin" || return $?
      relian_invoke "$script" Install Install "$pin" || return $?
      ;;
    *)
      relian_error "unknown action"
      return 1
      ;;
  esac
  return 0
}

relian_run_downloaded() {
  local work="$1"
  local package_url="$2"
  local package_sha256="$3"
  local action="$4"
  local pin_version="$5"
  local dest="$work/package.sh"
  relian_download "$package_url" "$dest" || return $?
  relian_verify_hash "$dest" "$package_sha256" || return $?
  relian_dispatch "$dest" "$action" "$pin_version" || return $?
  return 0
}

relian_runner_main() {
  local package_url=""
  local package_sha256=""
  local action=""
  local pin_version=""
  local seen_url=0
  local seen_hash=0
  local seen_action=0
  local seen_pin=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --package-url)
        if [[ $# -lt 2 ]]; then
          relian_error "missing parameter --package-url"
          return 1
        fi
        package_url="$2"
        seen_url=1
        shift 2
        ;;
      --package-sha256)
        if [[ $# -lt 2 ]]; then
          relian_error "missing parameter --package-sha256"
          return 1
        fi
        package_sha256="$2"
        seen_hash=1
        shift 2
        ;;
      --action)
        if [[ $# -lt 2 ]]; then
          relian_error "missing parameter --action"
          return 1
        fi
        action="$2"
        seen_action=1
        shift 2
        ;;
      --pin-version)
        if [[ $# -lt 2 ]]; then
          relian_error "missing parameter --pin-version"
          return 1
        fi
        pin_version="$2"
        seen_pin=1
        shift 2
        ;;
      *)
        relian_error "unknown parameter"
        return 1
        ;;
    esac
  done

  if [[ "$seen_url" -ne 1 ]]; then
    relian_error "missing parameter --package-url"
    return 1
  fi
  if [[ "$seen_hash" -ne 1 ]]; then
    relian_error "missing parameter --package-sha256"
    return 1
  fi
  if [[ "$seen_action" -ne 1 ]]; then
    relian_error "missing parameter --action"
    return 1
  fi
  if [[ "$seen_pin" -ne 1 ]]; then
    relian_error "missing parameter --pin-version"
    return 1
  fi

  case "$action" in
    Install|Update|Repair|Reinstall|Uninstall) ;;
    *)
      relian_error "unknown action"
      return 1
      ;;
  esac

  # Empty or whitespace hash returns before the URL is inspected.
  if relian_is_blank "$package_sha256"; then
    return 0
  fi

  if relian_url_has_userinfo "$package_url"; then
    relian_error "refusing a URL that contains userinfo"
    return 1
  fi

  local root=""
  root="$(relian_temp_root)"
  local work=""
  work="$(mktemp -d "${root}/relian-runner.XXXXXXXX" 2>/dev/null)" || {
    relian_error "download failed for package"
    return 1
  }
  local code=0
  relian_run_downloaded "$work" "$package_url" "$package_sha256" "$action" "$pin_version" || code=$?
  relian_remove_work "$root" "$work"
  return "$code"
}

# Sourcing defines the functions and does not download. Executing downloads.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -euo pipefail
code=0
relian_runner_main "$@" || code=$?
exit "$code"
