#!/bin/bash
# Linux diagnose-pve package. Every machine command is a fake on a PATH that
# holds nothing else, and /proc, /sys and /etc are fixture files under DP_FS.
# Nothing runs against the real host.
# shellcheck disable=SC2016
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/linux/packages/diagnose-pve/diagnose-pve.sh"
RELEASE="$ROOT/linux/releases/diagnose-pve.json"

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

has() { [[ "$OUT" == *"$1"* ]] || fail "missing [$1]"; }
hasnt() { [[ "$OUT" != *"$1"* ]] || fail "unexpected [$1]"; }

# Every sensitive-looking fixture value is random per run, so none is committed.
rnd() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
TS_SECRET="ts""key-auth-$(rnd 8)"
PW_VALUE="$(rnd 6)"
PW_SECRET="pass""word=$PW_VALUE"
CI_SECRET="$(rnd 12)"
SSH_VALUE="$(rnd 16)"
SSH_SECRET="ssh-ed25519%20$SSH_VALUE"
MAC="$(rnd 6 | sed 's/../&:/g; s/:$//')"
VMGENID="$(rnd 16)"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
CALLS="$WORK/calls"
REAL_SLEEP="$(command -v sleep)"

# One fake for every machine command. It logs the call and prints the fixture
# named after the command line. No fixture: exit 1 with no output.
cat > "$WORK/fake" << 'FAKE'
#!/bin/bash
name="${0##*/}"
printf "%s\n" "$name${*:+ $*}" >> "$CALLS"
if [[ "$name" == sleep ]]; then
  if [[ -f "$FIX/proc/diskstats.2" ]]; then
    cat "$FIX/proc/diskstats.2" > "$FIX/proc/diskstats"
  fi
  exit 0
fi
key="$name${*:+ $*}"
f="$FIX/cmd/${key//[^A-Za-z0-9]/_}"
if [[ -f "$f.hang" ]]; then
  exec "$REAL_SLEEP" 30
fi
[[ -f "$f" ]] || exit 1
cat "$f"
code=0
[[ -f "$f.code" ]] && code="$(cat "$f.code")"
exit "$code"
FAKE
chmod +x "$WORK/fake"

REAL_TOOLS=(bash cat sort head tr awk grep sed perl date timeout nice ionice true)
ALL_FAKES=(sleep pveversion lscpu ps free lsblk df findmnt zpool zfs lvs vgs ip ethtool ss tailscale qm pct pvesm pvesh systemctl)
PVE_ONLY=(pveversion zpool zfs lvs vgs tailscale qm pct pvesm pvesh)

# make_bin <dir> <fake names...>
make_bin() {
  local dir="$1" t
  shift
  mkdir -p "$dir"
  for t in "${REAL_TOOLS[@]}"; do
    ln -s "$(command -v "$t")" "$dir/$t"
  done
  for t in "$@"; do
    ln -s "$WORK/fake" "$dir/$t"
  done
}

# fx <fs> <command line> reads the fixture from stdin.
fx() {
  local fs="$1" key="$2"
  mkdir -p "$fs/cmd"
  cat > "$fs/cmd/${key//[^A-Za-z0-9]/_}"
}
fx_code() {
  local key="$2"
  printf '%s' "$3" > "$1/cmd/${key//[^A-Za-z0-9]/_}.code"
}
put() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

build_pve() {
  local fs="$1" n
  rm -rf -- "$fs"
  mkdir -p "$fs/cmd"
  printf 'pve1\n' | put "$fs/proc/sys/kernel/hostname"
  printf '6.8.12-4-pve\n' | put "$fs/proc/sys/kernel/osrelease"
  printf '12.8\n' | put "$fs/etc/debian_version"
  printf '1234567.89 2345678.00\n' | put "$fs/proc/uptime"
  printf '1.20 0.98 0.75 2/1234 56789\n' | put "$fs/proc/loadavg"
  printf 'America/Toronto\n' | put "$fs/etc/timezone"
  printf 'some avg10=0.50 avg60=0.40 avg300=0.30 total=123456\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' | put "$fs/proc/pressure/cpu"
  printf 'some avg10=12.10 avg60=9.40 avg300=7.30 total=98765432\nfull avg10=10.00 avg60=8.00 avg300=6.00 total=87654321\n' | put "$fs/proc/pressure/io"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=10\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=5\n' | put "$fs/proc/pressure/memory"
  printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zd16\tpartition\t8388604\t1024\t-2\n' | put "$fs/proc/swaps"
  put "$fs/proc/spl/kstat/zfs/arcstats" << 'EOF'
13 1 0x01 123 33456 1234567 7654321
name                            type data
hits                            4    123456789
c                               4    17179869184
c_min                           4    2147483648
c_max                           4    34359738368
size                            4    16106127360
EOF
  printf '60\n' | put "$fs/proc/sys/vm/swappiness"
  printf 'always [madvise] never\n' | put "$fs/sys/kernel/mm/transparent_hugepage/enabled"
  printf 'always defer defer+madvise [madvise] never\n' | put "$fs/sys/kernel/mm/transparent_hugepage/defrag"
  mkdir -p "$fs/sys/block/sdb" "$fs/sys/block/nvme0n1" "$fs/sys/block/zd0"
  printf '32\n' | put "$fs/sys/block/sda/device/queue_depth"
  printf 'Personalities : \nunused devices: <none>\n' | put "$fs/proc/mdstat"
  put "$fs/proc/diskstats.1" << 'EOF'
   7       0 loop0 10 0 80 1 0 0 0 0 0 4 1 0 0 0 0 0 0
   8       0 sda 1000 10 80000 500 2000 20 160000 1500 0 3000 2000 0 0 0 0 0 0
   8       1 sda1 900 10 70000 400 1900 20 150000 1400 0 2900 1800 0 0 0 0 0 0
   8      16 sdb 50 0 400 10 0 0 0 0 0 20 10 0 0 0 0 0 0
 259       0 nvme0n1 5000 0 400000 1000 9000 0 720000 3000 2 6000 4000 0 0 0 0 0 0
 230       0 zd0 100 0 800 50 200 0 1600 100 0 150 150 0 0 0 0 0 0
EOF
  put "$fs/proc/diskstats.2" << 'EOF'
   7       0 loop0 99 0 800 9 0 0 0 0 0 40 10 0 0 0 0 0 0
   8       0 sda 1500 10 120000 750 3000 20 240000 2250 0 5500 3000 0 0 0 0 0 0
   8       1 sda1 1400 10 110000 650 2900 20 230000 2150 0 5400 2800 0 0 0 0 0 0
   8      16 sdb 50 0 400 10 0 0 0 0 0 20 10 0 0 0 0 0 0
 259       0 nvme0n1 5100 0 401600 1010 9900 0 727200 3090 2 6600 4100 0 0 0 0 0 0
 230       0 zd0 100 0 800 50 200 0 1600 100 0 150 150 0 0 0 0 0 0
EOF
  cp "$fs/proc/diskstats.1" "$fs/proc/diskstats"
  for n in lo eno1 vmbr0 tap100i0 veth101i0; do
    mkdir -p "$fs/sys/class/net/$n/statistics"
    printf '1500\n' > "$fs/sys/class/net/$n/mtu"
    printf '0\n' | tee "$fs/sys/class/net/$n/statistics/"{rx_errors,tx_errors,rx_dropped,tx_dropped} > /dev/null
  done
  mkdir -p "$fs/sys/class/net/eno1/device"
  printf '12\n' > "$fs/sys/class/net/eno1/statistics/rx_dropped"
  printf '3\n' > "$fs/sys/class/net/veth101i0/statistics/tx_errors"
  put "$fs/etc/vzdump.conf" << EOF
# vzdump default settings
#tmpdir: DIR

bwlimit: 51200
ionice: 7
notes-template: {{guestname}} $PW_SECRET
fake-token: should-not-print
EOF

  printf 'pve-manager/8.2.7/3e0176e6bb2ade3b (running kernel: 6.8.12-4-pve)\n' | fx "$fs" 'pveversion'
  fx "$fs" 'lscpu' << 'EOF'
Architecture:                         x86_64
CPU op-mode(s):                       32-bit, 64-bit
CPU(s):                               32
On-line CPU(s) list:                  0-31
Vendor ID:                            AuthenticAMD
Model name:                           AMD EPYC 7302P 16-Core Processor
Thread(s) per core:                   2
Core(s) per socket:                   16
Socket(s):                            1
CPU(s) scaling MHz:                   62%
CPU max MHz:                          3000.0000
CPU min MHz:                          1500.0000
NUMA node(s):                         1
Vulnerability Spectre v2:             Mitigation; Retpolines
EOF
  fx "$fs" 'ps -eo pcpu=,pmem=,rss=,comm=' << EOF
 0.0  0.0     0 kthreadd
25.3 25.1 8421376 kvm
12.0 12.5 4210688 kvm
 0.4  0.6 154000 pvedaemon worke
 0.2  0.4 120000 pveproxy worker
 0.1  1.5 500000 backup-tool
 0.0  0.0  3000 $TS_SECRET
 3.1  0.1 40000 z_wr_iss
EOF
  fx "$fs" 'free -m' << 'EOF'
               total        used        free      shared  buff/cache   available
Mem:          128672       98123       20345         120       11203       30549
Swap:           8191          12        8179
EOF
  fx "$fs" 'lsblk -d -o NAME,SIZE,ROTA,TYPE,TRAN,MODEL,SCHED,RQ-SIZE' << 'EOF'
NAME     SIZE ROTA TYPE TRAN MODEL                      SCHED       RQ-SIZE
sda      3.6T    1 disk sata ST4000NM000A-2HZ100        mq-deadline      64
sdb      3.6T    1 disk sata ST4000NM000A-2HZ100        mq-deadline      64
nvme0n1  1.7T    0 disk nvme SAMSUNG MZQL21T9HCJR-00A07 none           1023
zd0       64G    0 disk                                 none            256
EOF
  fx "$fs" 'df -hT -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs' << 'EOF'
Filesystem       Type   Size  Used Avail Use% Mounted on
rpool/ROOT/pve-1 zfs    3.4T  9.0G  3.4T   1% /
rpool            zfs    3.4T  128K  3.4T   1% /rpool
/dev/fuse        fuse   128M   24K  128M   1% /etc/pve
EOF
  printf '/ zfs rpool/ROOT/pve-1\n' | fx "$fs" 'findmnt -n -o TARGET,FSTYPE,SOURCE -T /var/lib/vz'
  printf 'all pools are healthy\n' | fx "$fs" 'zpool status -x'
  fx "$fs" 'zpool list' << 'EOF'
NAME    SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
rpool  3.62T   812G  2.83T        -         -    23%    21%  1.00x    ONLINE  -
EOF
  fx "$fs" 'zfs get -H -o name,property,value -t filesystem,volume compression,recordsize,volblocksize,sync' << 'EOF'
rpool	compression	lz4
rpool	recordsize	128K
rpool	sync	standard
rpool/data/vm-100-disk-0	compression	lz4
rpool/data/vm-100-disk-0	volblocksize	16K
rpool/data/vm-100-disk-0	sync	standard
EOF
  printf '  VG  #PV #LV #SN Attr   VSize VFree\n  pve   1   3   0 wz--n- 1.74t 16.00g\n' | fx "$fs" 'vgs --readonly'
  printf '  LV   VG  Attr       LSize  Pool Origin Data%%\n  data pve twi-aotz-- 1.6t             12.50\n' | fx "$fs" 'lvs --readonly'
  fx "$fs" 'ip -br address' << 'EOF'
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno1             UP
vmbr0            UP             192.168.10.5/24 fe80::1/64
tap100i0         UNKNOWN
tailscale0       UNKNOWN        100.64.0.7/32
EOF
  printf 'default via 192.168.10.1 dev vmbr0 proto kernel onlink\n' | fx "$fs" 'ip route show default'
  fx "$fs" 'ethtool eno1' << 'EOF'
Settings for eno1:
	Supported ports: [ TP ]
	Speed: 10000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Link detected: yes
EOF
  fx "$fs" 'ss -s' << 'EOF'
Total: 512
TCP:   40 (estab 12, closed 3, orphaned 0, timewait 2)
EOF
  # Keys in the status must never be printed. Only state, peer count and tags.
  fx "$fs" 'tailscale status --json' << EOF
{"BackendState":"Running","AuthURL":"$TS_SECRET","Self":{"PublicKey":"nodekey:abc","Tags":["tag:client-example"]},"Peer":{"nodekey:p1":{"HostName":"a"},"nodekey:p2":{"HostName":"b"}}}
EOF
  fx "$fs" 'qm list' << 'EOF'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 web01                running    8192              64.00 2345
       101 db01                 running    16384            200.00 3456
       102 broken               stopped    2048              32.00 0
EOF
  fx "$fs" 'pct list' << 'EOF'
VMID       Status     Lock         Name
200        running                 dns01
EOF
  fx "$fs" 'pvesm status' << 'EOF'
Name             Type     Status           Total            Used       Available        %
local             dir     active      3600000000         9000000      3591000000    0.25%
local-zfs     zfspool     active      3700000000       812000000      2888000000   21.95%
pbs1              pbs     active     10000000000      4000000000      6000000000   40.00%
EOF
  fx "$fs" 'qm config 100' << EOF
agent: 1
balloon: 2048
boot: order=scsi0;ide2;net0
cipassword: $CI_SECRET
ciuser: admin
cores: 4
cpu: x86-64-v2-AES
description: admin $PW_SECRET
efidisk0: local-zfs:vm-100-disk-1,efitype=4m,pre-enrolled-keys=1,size=1M
hookscript: local:snippets/hook.pl
ide2: local:iso/debian-12.iso,media=cdrom,size=600M
ipconfig0: ip=dhcp
machine: q35
memory: 8192
name: web01
nameserver: 1.1.1.1
net0: virtio=$MAC,bridge=vmbr0,firewall=1
ostype: l26
scsi0: local-zfs:vm-100-disk-0,discard=on,iothread=1,size=64G
scsihw: virtio-scsi-single
sockets: 1
sshkeys: $SSH_SECRET
tpmstate0: local-zfs:vm-100-disk-2,size=4M,version=v2.0
vmgenid: $VMGENID
EOF
  fx "$fs" 'qm config 101' << 'EOF'
cores: 8
memory: 16384
name: db01
sata0: local-zfs:vm-101-disk-0,size=200G
virtio1: local-zfs:vm-101-disk-1,size=100G
EOF
  : | fx "$fs" "qm config 102"
  fx_code "$fs" "qm config 102" 2
  fx "$fs" 'pvesh get /cluster/backup --output-format json' << 'EOF'
[{"id":"backup-1a2b","enabled":1,"schedule":"sun 01:00","storage":"pbs1","mode":"snapshot","all":1,"compress":"zstd","mailto":"ops@example.invalid","type":"vzdump"},{"id":"backup-3c4d","schedule":"daily","storage":"local","mode":"stop","vmid":"100,101","bwlimit":51200,"ionice":7}]
EOF
  fx "$fs" 'pvesh get /nodes/pve1/tasks --limit 15 --output-format json' << 'EOF'
[{"upid":"UPID:pve1:1:2:3:vzdump::root@pam:","type":"vzdump","id":"","user":"root@pam","status":"OK","starttime":1761800000,"endtime":1761803600},{"type":"qmstart","id":"100","user":"root@pam","status":"OK","starttime":1761700000,"endtime":1761700005},{"type":"vncproxy","id":"101","user":"admin@pve","status":"connection timed out","starttime":1761600000,"endtime":1761600020}]
EOF
  fx "$fs" 'pvesh get /nodes/pve1/tasks --source active --output-format json' << 'EOF'
[{"type":"vzdump","id":"","user":"root@pam","starttime":1761850000}]
EOF
  printf 'active\n' | fx "$fs" 'systemctl is-active backup-tool'
  printf 'MemoryCurrent=412000256\nNRestarts=0\n' | fx "$fs" 'systemctl show -p MemoryCurrent,NRestarts backup-tool'
  printf 'inactive\n' | fx "$fs" 'systemctl is-active cometd'
  fx_code "$fs" 'systemctl is-active cometd' 3
  printf 'MemoryCurrent=[not set]\nNRestarts=0\n' | fx "$fs" 'systemctl show -p MemoryCurrent,NRestarts cometd'
}

PVE_BIN="$WORK/bin-pve"
DEB_BIN="$WORK/bin-debian"
make_bin "$PVE_BIN" "${ALL_FAKES[@]}"
deb_fakes=()
for t in "${ALL_FAKES[@]}"; do
  [[ " ${PVE_ONLY[*]} " == *" $t "* ]] || deb_fakes+=("$t")
done
make_bin "$DEB_BIN" "${deb_fakes[@]}"
FS="$WORK/fs"

# run <bin dir> [VAR=value...]: sources the package in a clean environment and runs dp_main.
# T, D and S set DP_TIMEOUT, DP_DEADLINE and the Sample package argument.
run() {
  local bin="$1"
  shift
  : > "$CALLS"
  [[ -f "$FS/proc/diskstats.1" ]] && cp "$FS/proc/diskstats.1" "$FS/proc/diskstats"
  CODE=0
  OUT="$(env -i PATH="$bin" FIX="$FS" CALLS="$CALLS" REAL_SLEEP="$REAL_SLEEP" "$@" bash -c '
    source "$1"
    DP_FS="$FIX"
    DP_TIMEOUT="${T:-10}"
    DP_DEADLINE="${D:-43}"
    dp_main --deployment-type Install --action Install --pin-version 1
  ' _ "$PACKAGE" 2>&1)" || CODE=$?
}

section() {
  # Prints one section's body from $OUT.
  printf '%s\n' "$OUT" | awk -v s="== $1 ==" '$0 == s { on = 1; next } /^== / { on = 0 } on'
}

SECTIONS=('Identity' 'CPU and pressure' 'Memory' 'Storage' 'I/O sample' 'Network' 'Proxmox' 'Backup agents' 'Summary')

begin "Proxmox host: every section, exit 0, under 24 KB"
build_pve "$FS"
run "$PVE_BIN"
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
for s in "${SECTIONS[@]}"; do has "== $s =="; done
[[ "${#OUT}" -lt 24576 ]] || fail "output is ${#OUT} bytes"
has 'hostname: pve1'
has 'kernel: 6.8.12-4-pve'
has 'pveversion: pve-manager/8.2.7'
has 'timezone: America/Toronto'
has 'Model name:                           AMD EPYC 7302P'
has 'Socket(s):'
hasnt 'Vulnerability'
has 'io: some avg10=12.10'
has 'ZFS ARC size: 15360 MiB'
has 'ZFS ARC c_max: 32768 MiB'
has 'vm.swappiness: 60'
has 'thp.enabled: always [madvise] never'
has 'queue_depth: sda=32'
has 'all pools are healthy'
has 'rpool/data/vm-100-disk-0	volblocksize	16K'
has '/ zfs rpool/ROOT/pve-1'
has 'pve   1   3   0 wz--n-'
has 'sections ran: Identity '
has 'elapsed: '
grep -qE '^sections ran: Identity [0-9]+ms,CPU and pressure [0-9]+ms,.*,Backup agents [0-9]+ms$' <<< "$OUT" || fail "sections line"
ok

begin "top processes come from comm only and are sorted"
cpu="$(section 'CPU and pressure')"
first="$(printf '%s\n' "$cpu" | grep -A1 'top 8 by CPU' | tail -n 1)"
[[ "$first" == *'25.3'*'kvm' ]] || fail "first by CPU [$first]"
first="$(printf '%s\n' "$cpu" | grep -A1 'top 8 by RSS' | tail -n 1)"
[[ "$first" == *'8421376 kvm' ]] || fail "first by RSS [$first]"
ok

begin "I/O sample: per-device rates for whole devices that did I/O"
io="$(section 'I/O sample')"
grep -q '^sample: 5 s$' <<< "$io" || fail "sample line [$io]"
got="$(awk '$1 == "sda" { print $2, $3, $4, $5, $6 }' <<< "$io")"
# 40000 sectors read and 80000 written in 5 s, 1500 I/Os, 1000 ms of waits, 2500 ms busy.
[[ "$got" == '4.10 8.19 300.0 0.67 50.0' ]] || fail "sda [$got]"
got="$(awk '$1 == "nvme0n1" { print $2, $3, $4, $5, $6 }' <<< "$io")"
[[ "$got" == '0.16 0.74 200.0 0.10 12.0' ]] || fail "nvme0n1 [$got]"
for d in sda1 sdb loop0 zd0; do
  if grep -q "^$d " <<< "$io"; then fail "$d listed"; fi
done
grep -qx 'sleep 5' "$CALLS" || fail "default sample not 5: $(grep sleep "$CALLS")"
ok

begin "Sample is clamped to 1..10 and bad values fall back to 5"
run "$PVE_BIN" Sample=0
grep -qx 'sleep 1' "$CALLS" || fail "0 -> $(grep sleep "$CALLS")"
run "$PVE_BIN" Sample=99999999999999999999
grep -qx 'sleep 10' "$CALLS" || fail "huge -> $(grep sleep "$CALLS")"
run "$PVE_BIN" Sample=3
grep -qx 'sleep 3' "$CALLS" || fail "3 -> $(grep sleep "$CALLS")"
grep -q '^sample: 3 s$' <<< "$OUT" || fail "sample line for 3"
(
  # shellcheck disable=SC1090
  source "$PACKAGE"
  for pair in ':5' '0:1' '1:1' '07:7' '10:10' '11:10' 'abc:5' '-3:5' '2.5:5' ' 4 :4' '100:10'; do
    got="$(dp_sample "${pair%:*}")"
    [[ "$got" == "${pair##*:}" ]] || { printf 'dp_sample [%s] gave %s\n' "${pair%:*}" "$got"; exit 1; }
  done
) || fail "dp_sample"
ok

begin "network: link, counters, quiet virtual interfaces, tailscale summary"
build_pve "$FS"
run "$PVE_BIN"
net="$(section 'Network')"
grep -qE '^eno1 mtu=1500 .*rx_dropped=12.*Speed: 10000Mb/s Duplex: Full Link detected: yes' <<< "$net" || fail "eno1 line [$net]"
grep -q '^veth101i0 mtu=1500 .*tx_errors=3' <<< "$net" || fail "veth with errors not listed"
if grep -q "^tap100i0 mtu=" <<< "$net"; then fail "quiet tap listed"; fi
if grep -q "^lo mtu=" <<< "$net"; then fail "lo listed"; fi
grep -q '^1 tap/veth/fw interfaces' <<< "$net" || fail "quiet count"
grep -qx 'tailscale: state=Running peers=2 tags=tag:client-example' <<< "$net" || fail "tailscale summary"
hasnt 'nodekey'
has 'default via 192.168.10.1'
ok

begin "VM config keeps only allowlisted keys and drops secrets"
pve="$(section 'Proxmox')"
for want in 'name: web01' 'memory: 8192' 'balloon: 2048' 'cores: 4' 'sockets: 1' 'cpu: x86-64-v2-AES' \
  'scsihw: virtio-scsi-single' 'scsi0: local-zfs:vm-100-disk-0' 'efidisk0:' 'tpmstate0:' 'ide2:' "net0: virtio=$MAC" \
  'agent: 1' 'boot: order=' 'ostype: l26' 'sata0: local-zfs:vm-101' 'virtio1: local-zfs:vm-101'; do
  grep -qF -- "$want" <<< "$pve" || fail "missing $want"
done
for bad in cipassword sshkeys ciuser description hookscript nameserver ipconfig0 vmgenid machine; do
  if grep -qE "^$bad:" <<< "$pve"; then fail "$bad printed"; fi
done
hasnt "$CI_SECRET"
hasnt "$SSH_SECRET"
hasnt "$SSH_VALUE"
hasnt "$VMGENID"
has '[unavailable: qm config 102 (exit 2)]'
ok

begin "the final pass redacts auth keys and password= anywhere"
hasnt "$TS_SECRET"
hasnt "$PW_SECRET"
hasnt "$PW_VALUE"
has '<redacted>'
(
  # shellcheck disable=SC1090
  source "$PACKAGE"
  got="$(printf 'a %s b PASSWORD=x1 c\n' "$TS_SECRET" | dp_redact)"
  [[ "$got" == 'a <redacted> b <redacted> c' ]] || { printf 'redact gave [%s]\n' "$got"; exit 1; }
) || fail "dp_redact"
ok

begin "Proxmox: storage, guests, backup jobs, vzdump.conf, tasks, running backup"
for want in 'pbs1              pbs     active' '100 web01' '200        running' \
  'id=backup-1a2b enabled=1 schedule=sun 01:00 storage=pbs1 mode=snapshot compress=zstd bwlimit=- ionice=- vmid=all' \
  'id=backup-3c4d enabled=- schedule=daily storage=local mode=stop compress=- bwlimit=51200 ionice=7 vmid=100,101' \
  'bwlimit: 51200' 'ionice: 7' 'type=vzdump id=- user=root@pam status=OK start=' \
  'type=vncproxy id=101 user=admin@pve status=connection timed out' 'backup running now: yes' '  type=vzdump id=-'; do
  grep -qF -- "$want" <<< "$pve" || fail "missing $want"
done
hasnt 'ops@example.invalid'
hasnt 'should-not-print'
hasnt 'tmpdir'
[[ "$(grep -c '^type=' <<< "$pve")" -eq 3 ]] || fail "task count"
ok

begin "backup agents: is-active and two properties only"
ag="$(section 'Backup agents')"
grep -qx 'backup-tool: active=active MemoryCurrent=412000256 NRestarts=0 ' <<< "$ag" || fail "backup-tool [$ag]"
grep -q '^cometd: active=inactive' <<< "$ag" || fail "cometd [$ag]"
ok

# Every command the package ran, checked against the read-only allowlist.
ALLOWED_CALL='^(sleep [0-9]+|pveversion|lscpu|ps -eo pcpu=,pmem=,rss=,comm=|free -m'
ALLOWED_CALL+='|lsblk -d -o NAME,SIZE,ROTA,TYPE,TRAN,MODEL,SCHED,RQ-SIZE|df -hT( -x [a-z]+)+|findmnt -n -o TARGET,FSTYPE,SOURCE -T /var/lib/vz'
ALLOWED_CALL+='|zpool status -x|zpool list|zfs get -H -o name,property,value -t filesystem,volume compression,recordsize,volblocksize,sync'
ALLOWED_CALL+='|vgs --readonly|lvs --readonly|ip -br address|ip route show default|ethtool [A-Za-z0-9_.-]+|ss -s|tailscale status --json'
ALLOWED_CALL+='|qm list|qm config [0-9]+|pct list|pvesm status|pvesh get /cluster/backup --output-format json'
ALLOWED_CALL+='|pvesh get /nodes/[A-Za-z0-9-]+/tasks (--limit 15|--source active) --output-format json'
ALLOWED_CALL+='|systemctl is-active (backup-tool|cometd)|systemctl show -p MemoryCurrent,NRestarts (backup-tool|cometd))$'

begin "every command run is on the read-only allowlist"
build_pve "$FS"
run "$PVE_BIN"
[[ -s "$CALLS" ]] || fail "no calls logged"
bad="$(grep -vE "$ALLOWED_CALL" "$CALLS")"
[[ -z "$bad" ]] || fail "not allowlisted: $bad"
grep -qx 'qm config 101' "$CALLS" || fail "qm config not run"
ok

begin "plain Debian host: Proxmox, ZFS, LVM and tailscale are skipped"
rm -rf -- "$FS/proc/spl" "$FS/cmd"
mkdir -p "$FS/cmd"
run "$DEB_BIN"
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
for s in "${SECTIONS[@]}"; do has "== $s =="; done
has 'skipped: pveversion not found, not a Proxmox VE host'
has 'tailscale: not installed'
has 'ZFS ARC: not present'
has 'pveversion: [unavailable: pveversion (not found)]'
if grep -qE '^(qm|pct|pvesh|pvesm|zpool|zfs|lvs|vgs|tailscale) ' "$CALLS"; then fail "PVE command ran: $(cat "$CALLS")"; fi
ok

begin "every command failing and no /proc still prints every section and exits 0"
rm -rf -- "$FS"
mkdir -p "$FS/cmd"
run "$PVE_BIN"
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
for s in "${SECTIONS[@]}"; do has "== $s =="; done
has '[unavailable: lscpu (exit 1)]'
has '[unavailable: diskstats]'
has '[unavailable: hostname]'
has '[unavailable: qm list (exit 1)]'
has '[unavailable: node name]'
has '[unavailable: pvesh get /cluster/backup --output-format json (exit 1)]'
ok

begin "a hung command times out and the rest still runs"
build_pve "$FS"
: > "$FS/cmd/pvesm_status.hang"
started=$SECONDS
run "$PVE_BIN" T=1
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
has '[unavailable: pvesm status (timed out)]'
has 'name: web01'
[[ $((SECONDS - started)) -lt 15 ]] || fail "took $((SECONDS - started)) s"
ok

begin "past the deadline no command starts"
build_pve "$FS"
run "$PVE_BIN" D=0
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
has '[unavailable: lscpu (time budget)]'
has '[unavailable: qm list (time budget)]'
has '[unavailable: I/O sample (time budget)]'
[[ ! -s "$CALLS" ]] || fail "ran after the deadline: $(cat "$CALLS")"
# A sample that would end past the deadline is skipped too.
run "$PVE_BIN" D=6 Sample=10
has '[unavailable: I/O sample (time budget)]'
if grep -q '^sleep ' "$CALLS"; then fail "slept past the deadline"; fi
run "$PVE_BIN" D=20 Sample=10
grep -qx 'sleep 10' "$CALLS" || fail "a sample that fits was skipped"
ok

begin "a large host stays under 24 KB and says what it cut"
build_pve "$FS"
{
  printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
  for i in $(seq 1000 1400); do printf '      %s vm-%s running 4096 32.00 %s\n' "$i" "$i" "$i"; done
} | fx "$FS" 'qm list'
for i in $(seq 1 400); do printf 'rpool/data/vm-%s-disk-0\tvolblocksize\t16K\n' "$i"; done | fx "$FS" 'zfs get -H -o name,property,value -t filesystem,volume compression,recordsize,volblocksize,sync'
for i in $(seq 1 300); do printf '%s\n' "  1.0  1.0  1000 proc$i"; done | fx "$FS" 'ps -eo pcpu=,pmem=,rss=,comm='
run "$PVE_BIN"
[[ "$CODE" -eq 0 ]] || fail "exit $CODE"
[[ "${#OUT}" -lt 24576 ]] || fail "output is ${#OUT} bytes"
has '[truncated: Proxmox section reached its 6500 byte cap'
has '[truncated: 342 more lines]'
has '== Summary =='
ok

begin "runs as a file with the runner's arguments"
build_pve "$FS"
: > "$CALLS"
code=0
# DP_FS is fixed in the script, so this run reads this machine's /proc read-only; every command is a fake.
out="$(env -i PATH="$PVE_BIN" FIX="$FS" CALLS="$CALLS" REAL_SLEEP="$REAL_SLEEP" Sample=1 \
  bash "$PACKAGE" --deployment-type Install --action Install --pin-version 1 2>&1)" || code=$?
[[ "$code" -eq 0 ]] || fail "exit $code"
[[ "$out" == *'== Summary =='* ]] || fail "no summary"
bad="$(grep -vE "$ALLOWED_CALL" "$CALLS")"
[[ -z "$bad" ]] || fail "not allowlisted: $bad"
ok

# Prints "<line>: <problems>: <text>" for each line of the file in $1 that could write,
# reach the network, change state, or call a subcommand outside the allowlist.
SCAN_PL='
  next if /^\s*#/;
  my $l = $_; chomp $l;
  my @e;
  (my $r = $l) =~ s/<redacted>//g;
  $r =~ s{->|=>|[0-9&]?>\s*/dev/null|[0-9]?>&[12]}{}g;
  push @e, "redirect" if $r =~ />/;
  push @e, "forbidden $1" while $l =~ /\b(mktemp|tee|apt|apt-get|aptitude|dpkg|yum|dnf|pip3?|modprobe|insmod|rmmod|sysctl|smartctl|hdparm|sdparm|fio|dd|badblocks|fstrim|blkdiscard|wipefs|mkfs|fdisk|sfdisk|sgdisk|parted|rm|mv|cp|touch|chmod|chown|chattr|ln|mkdir|rmdir|truncate|install|shred|mknod|mkfifo|kill|pkill|killall|renice|reboot|shutdown|poweroff|halt|mount|umount|swapon|swapoff|curl|wget|nc|ncat|socat|ssh|scp|rsync|telnet|sudo|su|crontab|systemd-run|nsenter|chroot|iptables|nft|ebtables|pve-firewall|exec|iostat)\b/g;
  push @e, "sed in place" if $l =~ /\bsed\s+(-[a-zA-Z]*i|--in-place)/;
  push @e, "shell eval" if $l =~ /\beval\s+[^\s{]/;
  push @e, "/dev/tcp" if $l =~ m{/dev/(tcp|udp)};
  push @e, "vzdump run" if $l =~ /\bvzdump\s+\S/;
  push @e, "ethtool flag" if $l =~ /\bethtool\s+-/;
  my %ok = map { $_ => 1 } qw(lvs vgs pve pveversion pvesm pvesh qm pct zpool zfs);
  while ($l =~ /\b((?:lv|vg|pv|qm|pct|zpool|zfs)[a-z-]*)\b/g) { push @e, "tool $1" unless $ok{$1} }
  my %sub = (qm => "list config", pct => "list", pvesm => "status", pvesh => "get", zpool => "status list",
    zfs => "get", tailscale => "status", systemctl => "is-active show");
  while ($l =~ /\b(qm|pct|pvesm|pvesh|zpool|zfs|tailscale|systemctl)\s+([a-z][a-z-]*)\b/g) {
    my ($t, $s) = ($1, $2);
    push @e, "$t $s" unless grep { $_ eq $s } split / /, $sub{$t};
  }
  while ($l =~ /\bip\s+(-?[a-z]+\s+[a-z]+)/g) { push @e, "ip $1" unless $1 eq "-br address" || $1 eq "route show" }
  print "$.: @e: $l\n" if @e;
'

begin "static scan: no writes, no network, no state changes, allowlisted subcommands only"
scan="$(perl -ne "$SCAN_PL" "$PACKAGE")"
[[ -z "$scan" ]] || fail "$scan"
# The scan must catch each kind of change. These lines go to a scratch file, never the package.
for probe in 'printf x > /etc/x' 'echo 1 >> /proc/sys/vm/drop_caches' 'sed -i s/a/b/ f' 'tmp="$(mktemp)"' 'systemctl restart cometd' \
  'qm stop 100' 'pvesh set /nodes/x' 'pvesh create /x' 'zpool scrub rpool' 'zfs set sync=disabled rpool' 'ethtool -s eno1 speed 100' \
  'curl https://x' 'smartctl -a /dev/sda' 'lvchange -an x' 'ip link set eno1 down' 'sysctl -w vm.swappiness=1' 'a | tee f' \
  'apt-get update' 'pct start 200' 'pvenode config set' 'print > "/tmp/x"' 'vzdump 100' 'exec 3>/tmp/x' 'qmrestore a 1'; do
  printf '%s\n' "$probe" > "$WORK/probe"
  [[ -n "$(perl -ne "$SCAN_PL" "$WORK/probe")" ]] || fail "scan missed [$probe]"
done
ok

begin "release record matches the package"
sha="$(sha256sum -- "$PACKAGE" | cut -d ' ' -f 1)"
RELEASE="$RELEASE" SHA="$sha" node -e '
const r = JSON.parse(require("fs").readFileSync(process.env.RELEASE, "utf8"))
const e = []
if (r.name !== "diagnose-pve") e.push("name")
if (r.installsSoftware !== false) e.push("installsSoftware")
if (r.file !== "diagnose-pve.sh") e.push("file")
if (r.sha256 !== process.env.SHA) e.push("sha256 " + r.sha256 + " != " + process.env.SHA)
if (e.length) { console.error(e.join("; ")); process.exit(1) }
' || fail "release record"
[[ "$(head -n 1 "$PACKAGE")" == '#!/bin/bash' ]] || fail "shebang"
ok

printf 'SUMMARY passed=%s failed=%s\n' "$PASSES" "$FAILURES"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
exit 0
