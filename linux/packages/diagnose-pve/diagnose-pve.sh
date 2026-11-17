#!/bin/bash
# Read-only diagnostics for Proxmox VE and Debian hosts. It prints plain text
# to stdout and changes nothing on the host: no file writes, no service,
# kernel or package commands, no disk scans or SMART reads.
# Every command runs under timeout, at nice 19 and in the idle I/O class where
# available. A failure prints an [unavailable: <name>] line and the script
# still exits 0. tests/linux/diagnose-pve-test.sh scans this file for
# forbidden commands and fails on any.
# Optional environment, from --package-arguments-b64:
#   Sample   seconds between the two /proc/diskstats reads, default 5, 1..10
# The runner's --deployment-type, --action and --pin-version are ignored.

# Fixed here, never read from the environment. Tests reset them after sourcing.
DP_FS=''
DP_TIMEOUT=10
# No command starts later than this many seconds into the run, and none runs past it.
DP_DEADLINE=43
DP_START=0
DP_NICE=()
DP_SECTIONS=()

dp_now_us() {
  local t="${EPOCHREALTIME:-0.0}"
  printf '%s' "$((10#${t%.*} * 1000000 + 10#${t#*.}))"
}

dp_elapsed() {
  printf '%s' "$((($(dp_now_us) - DP_START) / 1000000))"
}

# Sample seconds: a whole number clamped to 1..10. Anything else is 5.
dp_sample() {
  local v="${1//[[:space:]]/}"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    printf '5'
    return 0
  fi
  if [[ "${#v}" -gt 2 ]]; then
    printf '10'
    return 0
  fi
  v=$((10#$v))
  if ((v < 1)); then v=1; fi
  if ((10 < v)); then v=10; fi
  printf '%s' "$v"
}

# [d] keeps the secret scanner from reading the pattern as a password.
dp_redact() {
  sed -E 's/tskey-[A-Za-z0-9-]+/<redacted>/g; s/passwor[d]=[^[:space:]]+/<redacted>/Ig'
}

# Prints at most <max> lines of stdin (0 is no limit) and says what it dropped.
dp_lines() {
  awk -v m="$1" 'm == 0 || NR <= m { print; next } { d++ } END { if (d) print "[truncated: " d " more lines]" }'
}

# dp_cmd <max lines> <command> [args...]: one external command, read-only.
dp_cmd() {
  local max="$1" out code=0 left t
  shift
  if ! command -v "$1" > /dev/null 2>&1; then
    printf '[unavailable: %s (not found)]\n' "$*"
    return 0
  fi
  left=$((DP_DEADLINE - $(dp_elapsed)))
  if ((left < 1)); then
    printf '[unavailable: %s (time budget)]\n' "$*"
    return 0
  fi
  t="$DP_TIMEOUT"
  if ((left < t)); then t="$left"; fi
  out="$(timeout -k 1 "$t" "${DP_NICE[@]}" "$@" 2>/dev/null)" || code=$?
  if [[ "$code" -eq 124 || "$code" -eq 137 ]]; then
    printf '[unavailable: %s (timed out)]\n' "$*"
    return 0
  fi
  if [[ -z "$out" ]]; then
    if [[ "$code" -ne 0 ]]; then
      printf '[unavailable: %s (exit %s)]\n' "$*" "$code"
    else
      printf '(no output)\n'
    fi
    return 0
  fi
  printf '%s\n' "$out" | dp_lines "$max"
  if [[ "$code" -ne 0 ]]; then
    printf '(exit %s)\n' "$code"
  fi
  return 0
}

# dp_file <max lines> <label> <path under DP_FS>
dp_file() {
  local path="$DP_FS$3"
  if [[ -r "$path" ]]; then
    dp_lines "$1" < "$path"
  else
    printf '[unavailable: %s]\n' "$2"
  fi
}

# One-line value from a file: "label: value".
dp_kv() {
  local line=''
  if [[ -r "$DP_FS$2" ]] && IFS= read -r line < "$DP_FS$2"; then
    printf '%s: %s\n' "$1" "$line"
  else
    printf '[unavailable: %s]\n' "$1"
  fi
}

# Summaries of JSON from pvesh and tailscale. Input that is not JSON passes through.
dp_json() {
  perl -MJSON::PP -MPOSIX=strftime -e '
    my ($mode) = @ARGV;
    my $in = do { local $/; readline(*STDIN) } // "";
    if ($in =~ /^\[unavailable/) { print $in; exit 0 }
    my $j = eval { decode_json($in) };
    unless (ref $j) { print "[unavailable: $mode (unparsable)]\n"; exit 0 }
    my $v = sub { my ($h, $k) = @_; defined $h->{$k} && length $h->{$k} ? $h->{$k} : "-" };
    my $ts = sub { my $t = shift; defined $t && $t =~ /^\d+$/ ? strftime("%F %T", localtime $t) : "-" };
    if ($mode eq "jobs") {
      print "no backup jobs\n" unless @$j;
      for my $job (@$j) {
        my $who = $job->{all} ? "all" : $v->($job, "vmid");
        print join(" ", map { "$_=" . $v->($job, $_) } qw(id enabled schedule storage mode compress bwlimit ionice)), " vmid=$who\n";
      }
    } elsif ($mode eq "tasks") {
      print "no tasks\n" unless @$j;
      for my $t (@$j) {
        print join(" ", map({ "$_=" . $v->($t, $_) } qw(type id user status)), "start=" . $ts->($t->{starttime}), "end=" . $ts->($t->{endtime})), "\n";
      }
    } elsif ($mode eq "active") {
      my @b = grep { ($_->{type} // "") =~ /vzdump|backup/ } @$j;
      if (@b) {
        print "backup running now: yes\n";
        print "  type=", $v->($_, "type"), " id=", $v->($_, "id"), " start=", $ts->($_->{starttime}), "\n" for @b;
      } else {
        print "backup running now: no\n";
      }
    } elsif ($mode eq "tailscale") {
      my $self = ref $j->{Self} eq "HASH" ? $j->{Self} : {};
      my $tags = ref $self->{Tags} eq "ARRAY" ? join(",", @{$self->{Tags}}) : "-";
      my $peers = ref $j->{Peer} eq "HASH" ? scalar(keys %{$j->{Peer}}) : 0;
      print "tailscale: state=", $v->($j, "BackendState"), " peers=$peers tags=$tags\n";
    }
  ' "$1"
}

# qm config: keep only the allowlisted keys, and never a key that names a secret.
dp_vm_filter() {
  awk '/^\[unavailable/ || /^\(exit/ { print; next }
    { k = $0; sub(/:.*/, "", k) }
    tolower(k) ~ /pass|key|secret|token/ { next }
    k ~ /^(name|memory|balloon|cores|sockets|cpu|scsihw|agent|boot|ostype|(scsi|virtio|sata|ide|efidisk|tpmstate|net)[0-9]+)$/ { print }'
}

dp_conf_filter() {
  awk '/^[[:space:]]*(#|$)/ { next }
    { k = $0; sub(/[:=].*/, "", k) }
    tolower(k) ~ /pass|key|secret|token/ { next }
    { print }'
}

dp_identity() {
  dp_kv hostname /proc/sys/kernel/hostname
  dp_kv kernel /proc/sys/kernel/osrelease
  dp_kv debian /etc/debian_version
  if [[ -r "$DP_FS/proc/uptime" ]]; then
    awk '{ s = int($1); printf "uptime: %d days %d h %d min\n", s / 86400, (s % 86400) / 3600, (s % 3600) / 60 }' "$DP_FS/proc/uptime"
  else
    printf '[unavailable: uptime]\n'
  fi
  dp_kv load /proc/loadavg
  printf 'date: %s\n' "$(dp_cmd 1 date '+%F %T %Z (%z)')"
  dp_kv timezone /etc/timezone
  printf 'pveversion: %s\n' "$(dp_cmd 1 pveversion)"
}

dp_cpu() {
  local out f
  printf -- '-- lscpu\n'
  dp_cmd 0 lscpu | grep -E '^(Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|CPU\(s\)|CPU (max |min )?MHz|NUMA node\(s\)):|^\[unavailable'
  printf -- '-- pressure\n'
  for f in cpu io memory; do
    if [[ -r "$DP_FS/proc/pressure/$f" ]]; then
      awk -v f="$f" '{ print f ": " $0 }' "$DP_FS/proc/pressure/$f"
    else
      printf '[unavailable: pressure %s]\n' "$f"
    fi
  done
  # Command names only. Full command lines can hold secrets.
  out="$(dp_cmd 0 ps -eo pcpu=,pmem=,rss=,comm=)"
  if [[ "$out" == '['* ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf -- '-- top 8 by CPU (lifetime average): %%CPU %%MEM RSS_KB COMMAND\n'
  printf '%s\n' "$out" | sort -k1,1 -n -r | head -n 8
  printf -- '-- top 8 by RSS: %%CPU %%MEM RSS_KB COMMAND\n'
  printf '%s\n' "$out" | sort -k3,3 -n -r | head -n 8
}

dp_memory() {
  dp_cmd 0 free -m
  printf -- '-- swaps\n'
  dp_file 10 swaps /proc/swaps
  if [[ -r "$DP_FS/proc/spl/kstat/zfs/arcstats" ]]; then
    awk '$1 == "size" || $1 == "c" || $1 == "c_min" || $1 == "c_max" { printf "ZFS ARC %s: %d MiB\n", $1, $3 / 1048576 }' "$DP_FS/proc/spl/kstat/zfs/arcstats"
  else
    printf 'ZFS ARC: not present\n'
  fi
  dp_kv vm.swappiness /proc/sys/vm/swappiness
  dp_kv thp.enabled /sys/kernel/mm/transparent_hugepage/enabled
  dp_kv thp.defrag /sys/kernel/mm/transparent_hugepage/defrag
}

dp_storage() {
  local q n line=''
  printf -- '-- lsblk\n'
  dp_cmd 40 lsblk -d -o NAME,SIZE,ROTA,TYPE,TRAN,MODEL,SCHED,RQ-SIZE
  for q in "$DP_FS"/sys/block/*/device/queue_depth; do
    if [[ -r "$q" ]]; then
      n="${q%/device/queue_depth}"
      line+="${n##*/}=$(< "$q") "
    fi
  done
  printf 'queue_depth: %s\n' "${line:-none}"
  printf -- '-- df\n'
  dp_cmd 40 df -hT -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs
  printf -- '-- mdstat\n'
  dp_file 30 mdstat /proc/mdstat
  printf -- '-- /var/lib/vz\n'
  dp_cmd 2 findmnt -n -o TARGET,FSTYPE,SOURCE -T /var/lib/vz
  if command -v zpool > /dev/null 2>&1; then
    printf -- '-- zpool\n'
    dp_cmd 40 zpool status -x
    dp_cmd 20 zpool list
  fi
  if command -v lvs > /dev/null 2>&1; then
    # --readonly reads the metadata without taking LVM locks.
    printf -- '-- LVM\n'
    dp_cmd 20 vgs --readonly
    dp_cmd 40 lvs --readonly
  fi
  if command -v zfs > /dev/null 2>&1; then
    printf -- '-- ZFS datasets\n'
    dp_cmd 60 zfs get -H -o name,property,value -t filesystem,volume compression,recordsize,volblocksize,sync
  fi
}

# Two /proc/diskstats reads <sample> seconds apart. Whole devices from /sys/block only.
dp_io() {
  local sample="$1" a b d devs=' '
  if [[ ! -r "$DP_FS/proc/diskstats" ]]; then
    printf '[unavailable: diskstats]\n'
    return 0
  fi
  # The sample must also end before the deadline.
  if ((DP_DEADLINE - $(dp_elapsed) < sample)); then
    printf '[unavailable: I/O sample (time budget)]\n'
    return 0
  fi
  for d in "$DP_FS"/sys/block/*; do
    devs+="${d##*/} "
  done
  a="$(< "$DP_FS/proc/diskstats")"
  sleep "$sample"
  b="$(< "$DP_FS/proc/diskstats")"
  printf 'sample: %s s\n' "$sample"
  printf '%s\n--\n%s\n' "$a" "$b" | awk -v dt="$sample" -v devs="$devs" '
    $0 == "--" { second = 1; next }
    index(devs, " " $3 " ") == 0 { next }
    !second { r[$3] = $4; rs[$3] = $6; rt[$3] = $7; w[$3] = $8; ws[$3] = $10; wt[$3] = $11; io[$3] = $13; seen[$3] = 1; next }
    !($3 in seen) { next }
    {
      dr = $4 - r[$3]; dw = $8 - w[$3]; n = dr + dw
      if (dr < 0 || dw < 0 || n == 0) next
      if (!shown++) printf "%-14s %8s %8s %8s %9s %6s\n", "device", "rMB/s", "wMB/s", "IOPS", "await_ms", "util%"
      util = ($13 - io[$3]) / (dt * 10)
      if (100 < util) util = 100
      printf "%-14s %8.2f %8.2f %8.1f %9.2f %6.1f\n", $3, ($6 - rs[$3]) * 512 / 1000000 / dt, ($10 - ws[$3]) * 512 / 1000000 / dt, n / dt, (($7 - rt[$3]) + ($11 - wt[$3])) / n, util
    }
    END { if (!shown) print "no device did I/O during the sample" }'
}

dp_network() {
  local p name s v line quiet=0 link
  printf -- '-- addresses\n'
  dp_cmd 60 ip -br address
  dp_cmd 5 ip route show default
  printf -- '-- interfaces: mtu and error/drop counters\n'
  for p in "$DP_FS"/sys/class/net/*; do
    name="${p##*/}"
    [[ -d "$p" && "$name" != 'lo' ]] || continue
    line="$name mtu=$(< "$p/mtu")"
    v=0
    for s in rx_errors tx_errors rx_dropped tx_dropped; do
      if [[ -r "$p/statistics/$s" ]]; then
        line+=" $s=$(< "$p/statistics/$s")"
        [[ "$(< "$p/statistics/$s")" == 0 ]] || v=1
      fi
    done
    case "$name" in
      tap*|veth*|fwbr*|fwpr*|fwln*)
        if [[ "$v" -eq 0 ]]; then
          quiet=$((quiet + 1))
          continue
        fi
        ;;
    esac
    if [[ -e "$p/device" ]]; then
      link="$(dp_cmd 0 ethtool "$name" | grep -E 'Speed:|Duplex:|Link detected:|^\[unavailable' | tr -s ' \t\n' ' ')"
      link="${link# }"
      line+=" ${link% }"
    fi
    printf '%s\n' "$line"
  done
  printf '%s tap/veth/fw interfaces with zero errors and drops not listed\n' "$quiet"
  printf -- '-- sockets\n'
  dp_cmd 20 ss -s
  if command -v tailscale > /dev/null 2>&1; then
    dp_cmd 0 tailscale status --json | dp_json tailscale
  else
    printf 'tailscale: not installed\n'
  fi
}

dp_proxmox() {
  local list id node=''
  if ! command -v pveversion > /dev/null 2>&1; then
    printf 'skipped: pveversion not found, not a Proxmox VE host\n'
    return 0
  fi
  printf -- '-- storage\n'
  dp_cmd 30 pvesm status
  printf -- '-- guests\n'
  list="$(dp_cmd 0 qm list)"
  printf '%s\n' "$list" | dp_lines 60
  dp_cmd 60 pct list
  for id in $(printf '%s\n' "$list" | awk '$1 ~ /^[0-9]+$/ { print $1 }'); do
    printf -- '-- qm config %s\n' "$id"
    dp_cmd 0 qm config "$id" | dp_vm_filter
  done
  printf -- '-- backup jobs\n'
  dp_cmd 0 pvesh get /cluster/backup --output-format json | dp_json jobs
  printf -- '-- vzdump.conf\n'
  dp_file 0 vzdump.conf /etc/vzdump.conf | dp_conf_filter
  [[ -r "$DP_FS/proc/sys/kernel/hostname" ]] && IFS= read -r node < "$DP_FS/proc/sys/kernel/hostname"
  node="${node%%.*}"
  if [[ ! "$node" =~ ^[A-Za-z0-9-]+$ ]]; then
    printf '[unavailable: node name]\n'
    return 0
  fi
  printf -- '-- last 15 tasks\n'
  dp_cmd 0 pvesh get "/nodes/$node/tasks" --limit 15 --output-format json | dp_json tasks
  dp_cmd 0 pvesh get "/nodes/$node/tasks" --source active --output-format json | dp_json active
}

dp_agents() {
  local u
  for u in backup-tool cometd; do
    printf '%s: active=%s%s\n' "$u" "$(dp_cmd 1 systemctl is-active "$u" | tr '\n' ' ')" \
      "$(dp_cmd 0 systemctl show -p MemoryCurrent,NRestarts "$u" | tr '\n' ' ')"
  done
}

# dp_section <title> <byte cap> <function> [args...]
dp_section() {
  local title="$1" cap="$2" t0
  shift 2
  t0="$(dp_now_us)"
  printf '\n== %s ==\n' "$title"
  "$@" 2>/dev/null | awk -v cap="$cap" -v t="$title" '
    { n = length($0) + 1 }
    used + n <= cap { used += n; print; next }
    { d++ }
    END { if (d) print "[truncated: " t " section reached its " cap " byte cap, " d " lines dropped]" }'
  DP_SECTIONS+=("$title $((($(dp_now_us) - t0) / 1000))ms")
}

dp_report() {
  local sample
  sample="$(dp_sample "${Sample:-}")"
  printf 'diagnose-pve: read-only diagnostics, nothing on this host is changed\n'
  dp_section 'Identity' 1500 dp_identity
  dp_section 'CPU and pressure' 2500 dp_cpu
  dp_section 'Memory' 1800 dp_memory
  dp_section 'Storage' 4500 dp_storage
  dp_section 'I/O sample' 2000 dp_io "$sample"
  dp_section 'Network' 3500 dp_network
  dp_section 'Proxmox' 6500 dp_proxmox
  dp_section 'Backup agents' 600 dp_agents
  printf '\n== Summary ==\n'
  printf 'sections ran: %s\n' "$(IFS=,; printf '%s' "${DP_SECTIONS[*]}")"
  printf 'elapsed: %s s\n' "$(dp_elapsed)"
}

dp_main() {
  export LC_ALL=C
  DP_START="$(dp_now_us)"
  DP_NICE=()
  if command -v nice > /dev/null 2>&1; then
    DP_NICE+=(nice -n 19)
  fi
  if command -v ionice > /dev/null 2>&1 && ionice -c3 true > /dev/null 2>&1; then
    DP_NICE+=(ionice -c3)
  fi
  dp_report | dp_redact
  return 0
}

# Sourcing defines the functions and does nothing else.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

dp_main
exit 0
