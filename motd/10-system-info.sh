#!/bin/bash
# =============================================================================
# motd — dynamic system-info MOTD (post-login)
# -----------------------------------------------------------------------------
# Project : motd
# Purpose : Replace the static /etc/motd with a single-screen dashboard:
#           branded header, system facts, service health, security state,
#           recent logins. Designed for the SSH hot path — every external
#           command is wrapped in `timeout`, every cache lives under
#           a root-owned dir, every section can be toggled at runtime.
# License : Apache-2.0
# Copyright: (c) 2026 EXT IT GmbH
# Homepage : https://github.com/EXT-IT/motd
# -----------------------------------------------------------------------------
# Distro assumptions:
#   - Ubuntu 24.04 LTS or any modern Debian-family distro with the
#     /etc/update-motd.d/ hook (i.e. pam_motd from libpam-modules).
#   - RHEL 9 / Rocky / Alma also work as long as pam_motd.so is wired
#     into /etc/pam.d/sshd. The installer warns when /etc/update-motd.d/
#     is absent and skips this script.
#
# Hot-path rules (see motd CLAUDE.md "Change-safety baseline"):
#   - NO `salt-call` anywhere — boot cost ~300–800 ms per call.
#   - Every external command that talks to a daemon socket has `timeout 2`.
#   - All caches under /var/cache/motd/ (root:root 0755). Never /tmp.
#   - Public IP cache is sanitised on read so a tampered file cannot
#     emit ANSI/OSC escapes if perms ever slip.
#   - `last` is scoped to the current user only. Listing every admin's
#     source IPs would leak cross-admin movement patterns across the
#     ops team.
#   - Verbose info (kernel version, public IP) is opt-in via
#     MOTD_VERBOSE=true to stay within CIS Ubuntu 24.04 L1 §1.7.x
#     (minimal post-auth recon surface).
#   - This script is intentionally NOT `set -e`. A failed `grep` inside
#     a pipeline (e.g. fail2ban-client absent) must not collapse the
#     entire MOTD into nothing.
#   - `set -u` IS enabled. Unbound-variable references are programming
#     errors (typos, dropped rename, missed default) and must fail
#     loudly at dev/test time, not silently render wrong data in
#     production. Every optional lookup in this file uses `${VAR:-default}`
#     explicitly, so `set -u` has no legitimate reason to fire.
# =============================================================================
set -u

# ── TTY gate ──
#
# Exit immediately when stdout is not a terminal. This covers two cases:
#
#   1. pam_motd (via run-parts /etc/update-motd.d/) — stdout is redirected
#      to /run/motd.dynamic (a regular file). Without this gate, the script
#      would run fully but emit colourless output into the cache file.
#      pam_motd would then display the colourless cached version at login,
#      and the profile.d wrapper (which runs with a real TTY) would show
#      the coloured version a second time — duplicate MOTD.
#
#   2. Scripted SSH consumers (ssh host command, scp, rsync, CI) — stdout
#      is a pipe. Exiting 0 ensures zero bytes leak into data streams.
#
# The profile.d wrapper (/etc/profile.d/zz-motd.sh, installed by
# install.sh) calls this script directly in an interactive login shell
# where stdout IS the terminal. That is the sole display path — colours
# work because [ -t 1 ] succeeds for both this gate and the colour gate
# below.
[ -t 1 ] || exit 0

# UTF-8 locale for the rounded-corner box characters and `${#var}` to
# count codepoints (not bytes) when COMPANY_NAME contains umlauts.
# Falls back to C if no UTF-8 locale is installed; the box will then
# render as garbage but the rest of the script keeps working.
if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qix 'en_US.utf-\?8'; then
  export LC_ALL=en_US.UTF-8
else
  export LC_ALL=C
fi
export LANG="$LC_ALL"

# ── Colours ──
#
# Gate ANSI escapes on interactive-TTY / $TERM / $NO_COLOR. pam_motd
# invokes this script on every SSH login, including scripted consumers
# (`ssh host true`, `scp user@host:foo /dst`, rsync-over-ssh, CI jobs
# that treat post-login output as data). Unconditional colour bytes
# leak into those consumers as raw escape sequences, corrupt tar/rsync
# streams when captured, and under unusual downstream handling
# (content piped into a pager, `less` via `cat`) are a minor escape-
# injection vector. The standard "only colourise when stdout is a tty
# and the user has not opted out" gate closes all of the above with
# zero cost on the interactive path.
#
# The gate respects:
#   * [ -t 1 ]          stdout is a terminal (pam_motd writes to the
#                        login TTY; scripted ssh has a pipe instead)
#   * $NO_COLOR         https://no-color.org de-facto standard
#   * $TERM != dumb     dumb terminals (emacs shell, CI logs) ask for no colour
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RST='\e[0m'; BLD='\e[1m'; DIM='\e[2m'
  RED='\e[31m'; GRN='\e[32m'; YLW='\e[33m'; CYN='\e[36m'
else
  RST=''; BLD=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''
fi

# ── Runtime config ──
#
# Loaded from /etc/motd.conf (written by the motd installer). All keys
# have safe defaults so a missing config file is never fatal — the
# script will simply render with neutral branding.
#
# The config file is parsed as plain text — NEVER sourced. A previous
# revision ran `. /etc/motd.conf` at root privilege on every SSH login
# (this script is called by pam_motd), which turned the file into a
# direct local-code-execution surface: any shell construct reaching
# /etc/motd.conf (tainted CLI arg round-tripping through the installer,
# world-writable misconfig, unrelated package writing to the path)
# would have executed as root at next login. The regex parser below
# accepts only literal KEY=VALUE lines with shell-active metacharacters
# excluded on every value shape, so the worst a malformed config can
# do is fail to load a field.
_motd_load_config() {
  local path="$1"
  [ -r "$path" ] || return 0
  # Trust-boundary belt-and-braces: only honour a root-owned config.
  # `stat -c %u` returns the numeric UID of the file owner — we compare
  # against 0 (root). The previous `[ -O "$path" ]` checked whether the
  # *current effective user* owned the file, which always failed for
  # non-root SSH logins and silently ignored all config settings.
  [ "$(stat -c %u "$path" 2>/dev/null)" = "0" ] || return 0

  local line key rest value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *)   continue ;;
    esac
    key="${line%%=*}"
    rest="${line#*=}"

    # Runtime-relevant whitelist. sshd / backup / install-time keys
    # are intentionally omitted — this script renders the MOTD, it
    # does not re-drive the installer.
    case "$key" in
      COMPANY_NAME|MOTD_SUBTITLE|MOTD_VERBOSE|MOTD_FOOTER|\
      MOTD_MIN_WIDTH|MOTD_PUBIP_URL|MOTD_CACHE_DIR|\
      MOTD_SHOW_SERVICES|MOTD_SHOW_UPDATES|MOTD_SHOW_RECENT_LOGINS|\
      MOTD_SECURITY_PRIV_ONLY) ;;
      *) continue ;;
    esac

    # Three mutually exclusive value shapes, selected by the first
    # byte of the RHS. Shell-active metacharacters ($ ` \ " ') are
    # excluded on every shape so no form can emit an expansion.
    if [ "${rest:0:1}" = '"' ]; then
      if [[ "$rest" =~ ^\"([^\"\$\`\\]*)\"[[:space:]]*(#.*)?$ ]]; then
        value="${BASH_REMATCH[1]}"
      else
        continue
      fi
    elif [ "${rest:0:1}" = "'" ]; then
      if [[ "$rest" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
        value="${BASH_REMATCH[1]}"
      else
        continue
      fi
    else
      if [[ "$rest" =~ ^([^[:space:]\$\`\\\"\']*)[[:space:]]*(#.*)?$ ]]; then
        value="${BASH_REMATCH[1]}"
      else
        continue
      fi
    fi
    printf -v "$key" '%s' "$value"
  done < "$path"
}
_motd_load_config /etc/motd.conf

COMPANY_NAME="${COMPANY_NAME:-Managed Server}"
MOTD_SUBTITLE="${MOTD_SUBTITLE:- · Managed Server}"
MOTD_VERBOSE="${MOTD_VERBOSE:-false}"
MOTD_FOOTER="${MOTD_FOOTER:-}"
MOTD_MIN_WIDTH="${MOTD_MIN_WIDTH:-54}"
MOTD_PUBIP_URL="${MOTD_PUBIP_URL:-https://ifconfig.me}"
MOTD_CACHE_DIR="${MOTD_CACHE_DIR:-/var/cache/motd}"
MOTD_SHOW_SERVICES="${MOTD_SHOW_SERVICES:-true}"
MOTD_SHOW_UPDATES="${MOTD_SHOW_UPDATES:-true}"
MOTD_SHOW_RECENT_LOGINS="${MOTD_SHOW_RECENT_LOGINS:-true}"
# MOTD_SECURITY_PRIV_ONLY — opt-in gate for the Security block. On a
# shared bastion or any multi-admin host the fail2ban blocklist,
# active-jail detail, and running-security-tool state are information
# every logged-in user can see by default. Setting this flag to `true`
# scopes the Security section to users with sudo/wheel/admin group
# membership only. The default stays `false` (unchanged behaviour)
# because the original deployment model was single-admin VMs where the
# security surface was useful post-auth information for everyone with
# a shell. Operators on shared hosts should set this in /etc/motd.conf
# (standalone) or `login_banner:motd:security_priv_only: true` in pillar.
MOTD_SECURITY_PRIV_ONLY="${MOTD_SECURITY_PRIV_ONLY:-false}"

# Numeric guard: a string in MOTD_MIN_WIDTH would crash the arithmetic
# below. Anything non-numeric falls back to the documented default.
case "$MOTD_MIN_WIDTH" in
  ''|*[!0-9]*) MOTD_MIN_WIDTH=54 ;;
esac

# ── Header box geometry ──
#
# MOTD_WIDTH = max(MOTD_MIN_WIDTH, len(text) + 4).
# Auto-grows so a long company name never overflows.
# `${#var}` counts codepoints under a UTF-8 locale, so "Müller" is 6.
_MOTD_TEXT="${COMPANY_NAME}${MOTD_SUBTITLE}"
_MOTD_TEXT_LEN=${#_MOTD_TEXT}
MOTD_WIDTH=$((_MOTD_TEXT_LEN + 4))
[ "$MOTD_WIDTH" -lt "$MOTD_MIN_WIDTH" ] && MOTD_WIDTH=$MOTD_MIN_WIDTH
MOTD_OUTER=$((MOTD_WIDTH + 2))

_fill=$((MOTD_WIDTH - _MOTD_TEXT_LEN))
[ "$_fill" -lt 0 ] && _fill=0
_left=$((_fill / 2))
_right=$((_fill - _left))
MOTD_HEADER_LEFT=$(printf '%*s' "$_left" '')
MOTD_HEADER_RIGHT=$(printf '%*s' "$_right" '')

# Pre-render the top/bottom borders so the printf cost is paid once.
_dash_run() {
  local n=$1 i out=""
  for ((i=0; i<n; i++)); do out+="─"; done
  printf '%s' "$out"
}
MOTD_BOX_TOP="╭$(_dash_run "$MOTD_WIDTH")╮"
MOTD_BOX_BOTTOM="╰$(_dash_run "$MOTD_WIDTH")╯"

# Section divider: "─── Title " padded with ─ out to MOTD_OUTER so every
# divider matches the outer width of the title box no matter how long
# the title is.
_section() {
  local title="$1"
  local prefix="─── ${title} "
  local trailing=$((MOTD_OUTER - ${#prefix}))
  [ "$trailing" -lt 0 ] && trailing=0
  printf '%s%s' "$prefix" "$(_dash_run "$trailing")"
}

# ── Helpers ──

# Progress bar: bar <used_kb> <total_kb> [width]
# Uses block characters (multi-byte safe, no tr).
bar() {
  local u=$1 t=$2 w=${3:-42} pct=0 f e clr i
  [ "$t" -gt 0 ] && pct=$((u * 100 / t))
  f=$((pct * w / 100)); e=$((w - f))
  clr="$GRN"; [ "$pct" -ge 70 ] && clr="$YLW"; [ "$pct" -ge 90 ] && clr="$RED"
  local fill="" rest=""
  for ((i=0; i<f; i++)); do fill+="█"; done
  for ((i=0; i<e; i++)); do rest+="░"; done
  # printf '%b' instead of `echo -ne`. echo -e is POSIX-undefined and,
  # more importantly, re-expands backslash sequences in the *value* of
  # any interpolated variable. If a future fail2ban-client output ever
  # leaked a raw ESC sequence into a color string, echo -e would render
  # it; printf '%b' only processes the format-string backslash escapes,
  # not the variable payloads.
  printf '%b' "${clr}${fill}${DIM}${rest}${RST}"
}

# Human-readable KiB
h() {
  local k=$1
  if [ "$k" -ge 1048576 ]; then
    printf "%d.%dG" "$((k / 1048576))" "$(((k % 1048576) * 10 / 1048576))"
  elif [ "$k" -ge 1024 ]; then
    printf "%dM" "$((k / 1024))"
  else
    printf "%dK" "$k"
  fi
}

# ── Gather system info ──
FQDN=$(hostname -f 2>/dev/null || hostname)
# Parse /etc/os-release with awk instead of sourcing it. install.sh
# refuses to `source /etc/motd.conf` for exactly the same reason: a
# sourced file runs every command substitution, backtick, and shell
# statement with the privileges of the caller. This script runs as
# root on every SSH login via pam_motd, so a compromised os-release
# (a broken package vendor, a build-chroot surprise, or an appliance
# distro with inline bash in PRETTY_NAME) would be post-auth RCE as
# root on every login. The awk parser only reads the line as data,
# ignores quoting oddities, and cannot execute anything.
OS=$(awk -F= '/^PRETTY_NAME=/ { gsub(/^"|"$/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null)
[ -z "$OS" ] && OS="unknown"
UP=$(uptime -p 2>/dev/null || echo "unknown")
if [ -r /proc/loadavg ]; then
  read -r L1 L5 L15 _ _ < /proc/loadavg
else
  L1="?"; L5="?"; L15="?"
fi
CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
KERN=""
if [ "$MOTD_VERBOSE" = "true" ]; then
  KERN=$(uname -r 2>/dev/null)
fi

# Logged-in user (MOTD runs as root via PAM, $USER would be wrong)
LUSER=$(logname 2>/dev/null)
[ -z "$LUSER" ] && LUSER=$(who -m 2>/dev/null | awk '{print $1}')
[ -z "$LUSER" ] && LUSER="${USER:-root}"

# Sudo privileges + IS_PRIV gate.
#
# `id -nG` used to run twice (once per grep). Collapsed into a single
# call captured into $_groups, re-used for the $PRIV display string AND
# the $IS_PRIV gate below. One less fork, same semantics.
#
# IS_PRIV is consumed by MOTD_SECURITY_PRIV_ONLY to decide whether the
# current user may see the Security section. Membership in sudo / wheel
# / admin is the same trust boundary sshd and sudoers use for "this
# user is allowed to make changes that affect the host". Operators
# logging in as a non-sudo service account will get a slimmed MOTD
# without the fail2ban blocklist, Wazuh state, etc.
_groups=$(id -nG "$LUSER" 2>/dev/null || true)
IS_PRIV=false
case " $_groups " in
  *' sudo '*)  PRIV="${GRN}sudo${RST}";    IS_PRIV=true ;;
  *' wheel '*) PRIV="${GRN}wheel${RST}";   IS_PRIV=true ;;
  *' admin '*) PRIV="${GRN}admin${RST}";   IS_PRIV=true ;;
  *)           PRIV="${DIM}standard${RST}" ;;
esac
unset _groups

# Active sessions.
#
# A previous revision called `who` twice — once for the session count
# and once to build the per-user breakdown. `who` doesn't change state
# between calls but does open /var/run/utmp and do an alloc/stat pass
# every time; collapsing into one `who` + one awk saves ~2-4 ms on the
# hot path on LXC. The awk handles both counting and formatting in a
# single stream.
_who_snapshot=$(who 2>/dev/null || true)
SESS=$(printf '%s\n' "$_who_snapshot" | awk 'NF>0' | wc -l | tr -d ' ')
SESS_USERS=$(printf '%s\n' "$_who_snapshot" | awk 'NF>0 {print $1}' | sort | uniq -c | sort -rn | awk '{u=u s $2"("$1")"; s=", "} END{print u}')
unset _who_snapshot

# IPs — exclude loopback, container bridges, CNI/overlay pseudo-ifaces,
# and VPN mesh interfaces. Without the filter, Kubernetes nodes (`cni*`,
# `kube*`, `flannel*`, `calico*`, `weave*`) or mesh-VPN hosts (where every
# minion carries a tailscale/netbird/wireguard interface — `tailscale*`,
# `nb-*`, `wg*`) would display 15+ IP addresses and push the rest of the
# dashboard off-screen.
IPS=$(ip -o -4 addr show 2>/dev/null \
  | awk '$2 !~ /^(lo|docker|br-|veth|cni|kube|flannel|calico|weave|tailscale|nb-|wg)/' \
  | awk '{print $4}' | cut -d/ -f1 | head -5 | tr '\n' ',' | sed 's/,$//;s/,/, /g')
[ -z "$IPS" ] && IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -5 | tr '\n' ',' | sed 's/,$//;s/,/, /g')
[ -z "$IPS" ] && IPS="(none)"

# Public IP — verbose-only, 1-hour cache, length-capped, charset-whitelisted.
# Cache lives in a root-owned dir so a local user cannot pre-plant ANSI/OSC
# escape sequences and have the next admin's terminal interpret them.
# Proxmox hosts are skipped entirely: they typically run with no public
# default route, so the curl call would always hit `--max-time 2`.
# Setting MOTD_PUBIP_URL="" disables the probe outright while still
# allowing MOTD_VERBOSE=true to render the kernel version — useful in
# air-gapped, KRITIS, or privacy-regulated environments where the
# default `ifconfig.me` round-trip is unacceptable.
PUBIP=""
if [ "$MOTD_VERBOSE" = "true" ] && [ -n "$MOTD_PUBIP_URL" ] && ! command -v pveversion &>/dev/null; then
  PUBIP_CACHE="${MOTD_CACHE_DIR}/pubip"
  sanitize_ip() { tr -dc '0-9a-fA-F:.' | head -c 64; }
  if [ -f "$PUBIP_CACHE" ] && find "$PUBIP_CACHE" -mmin -60 2>/dev/null | grep -q .; then
    PUBIP=$(sanitize_ip < "$PUBIP_CACHE" 2>/dev/null)
  else
    PUBIP=$(curl -sf --max-time 2 "$MOTD_PUBIP_URL" 2>/dev/null | sanitize_ip)
    if [ -n "$PUBIP" ] && [ -d "$MOTD_CACHE_DIR" ]; then
      printf '%s' "$PUBIP" > "$PUBIP_CACHE" 2>/dev/null
    fi
  fi
fi

# System type detection
VTYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
case "$VTYPE" in
  lxc)       STYPE="LXC Container" ;;
  kvm|qemu)  STYPE="KVM Virtual Machine" ;;
  none)
    if command -v pveversion &>/dev/null; then
      STYPE="Proxmox Host"
    else
      STYPE="Bare Metal"
    fi ;;
  *)         STYPE="Virtual ($VTYPE)" ;;
esac

# Memory (direct from /proc — no subprocess)
MT=0; MA=0
if [ -r /proc/meminfo ]; then
  while IFS=': ' read -r key val _; do
    case $key in MemTotal) MT=$val;; MemAvailable) MA=$val;; esac
  done < /proc/meminfo
fi
MU=$((MT - MA))

# Disk — show `/` always, plus the highest-usage non-root local mount.
# Most LXC containers only have /; Proxmox hosts add /var/lib/vz, KVMs
# might have /var or /home on a separate LV. Use Total - Used for the
# free figure (df Available is unreliable on ZFS and fuse.lxcfs).
DT=0; DU=0; DF=0
if read -r _ DT DU _ _ <<< "$(df -Pk / 2>/dev/null | awk 'NR==2')"; then
  DF=$((DT - DU))
fi

EXTRA_MOUNT="" EXTRA_DT=0 EXTRA_DU=0 EXTRA_PCT=0
while IFS= read -r mt; do
  [ -z "$mt" ] && continue
  [ "$mt" = "/" ] && continue
  read -r _ edt edu _ _ <<< "$(df -Pk "$mt" 2>/dev/null | awk 'NR==2')"
  [ -z "$edt" ] && continue
  [ "$edt" -eq 0 ] && continue
  pct=$((edu * 100 / edt))
  if [ "$pct" -gt "$EXTRA_PCT" ]; then
    EXTRA_MOUNT="$mt"
    EXTRA_DT="$edt"
    EXTRA_DU="$edu"
    EXTRA_PCT="$pct"
  fi
done < <(df -Pk -l -x tmpfs -x devtmpfs -x squashfs -x overlay -x fuse.lxcfs 2>/dev/null | awk 'NR>1 {print $NF}')
EXTRA_DF=$((EXTRA_DT - EXTRA_DU))

# Updates — gated behind MOTD_SHOW_UPDATES so paranoid sites can
# suppress the package count entirely. The parser is locale-neutral
# AND position-neutral: it scans every line for one that BEGINS with
# an integer and takes the first two such numbers as (total, security).
#
# A previous revision keyed the extraction to NR==1 / NR==2, which
# broke on Ubuntu 24.04+ESM because that layout prepends a
# pro/apt-esm preamble before the counts:
#
#     Expanded Security Maintenance for Applications is not enabled.
#     [blank]
#     14 updates can be applied immediately.
#     3 of these updates are standard security updates.
#     [blank]
#     Enable ESM Apps to receive additional future security updates.
#
# The positional parser found no integer on lines 1 and 2, reported
# "Up to date", and fell through to the expensive `apt list --upgradable`
# fallback on every single login — the hot-path cost of the MOTD ballooned
# to ~1 s. The "scan all lines, take first two leading integers" shape
# is immune to both the preamble and to locale translation of the
# surrounding prose (which only touches non-leading fields).
UPD_STR=""
if [ "$MOTD_SHOW_UPDATES" = "true" ]; then
  UPD_ALL="" UPD_SEC=""
  UPD_FILE=/var/lib/update-notifier/updates-available
  if [ -r "$UPD_FILE" ] && [ -s "$UPD_FILE" ]; then
    # awk emits:
    #   "<total> <sec>"  on successful parse (sec may be 0)
    #   ""               when no integer-leading line was found at all
    # This distinction matters: a genuine "0 updates" result is a
    # definitive answer from the cache and MUST NOT trigger the
    # expensive `apt list --upgradable` fallback — only a parse
    # failure should. The shell-level `[ -z "$UPD_ALL" ] = 0` check
    # used to conflate the two and burn ~300-500 ms on every login on
    # up-to-date hosts.
    read -r UPD_ALL UPD_SEC <<< "$(LC_ALL=C awk '
      /^[[:space:]]*[0-9]+/ {
        sub(/^[[:space:]]+/, "")
        n = $1 + 0
        if (!have_total)    { total = n; have_total = 1; next }
        if (!have_sec)      { sec   = n; have_sec   = 1; exit }
      }
      END {
        if (have_total) printf "%d %d", total, (have_sec ? sec : 0)
        # else print nothing — empty output signals parse failure
      }
    ' "$UPD_FILE")"
  fi
  if [ -z "$UPD_ALL" ]; then
    # Fallback: apt list. Runs only when the cache file was missing,
    # empty, or had no integer-leading line at all. The `-security`
    # pocket name is upstream Ubuntu nomenclature and not translated,
    # so this stays locale-neutral regardless of the host's LC_MESSAGES.
    #
    # Single awk pass replaces the old echo|wc + echo|grep pair: two
    # forks become one (~2-4 ms saved). The `NF>0` guard drops the
    # blank trailing line that `tail -n +2` leaves on empty APT output.
    if command -v apt &>/dev/null; then
      APT_LIST=$(LC_ALL=C timeout 5 apt list --upgradable 2>/dev/null | tail -n +2)
      if [ -n "$APT_LIST" ]; then
        read -r UPD_ALL UPD_SEC <<< "$(
          printf '%s\n' "$APT_LIST" | awk '
            NF>0 { t++; if (/-security/) s++ }
            END  { printf "%d %d", t+0, s+0 }
          ')"
      fi
    fi
  fi
  if [ "${UPD_ALL:-0}" -eq 0 ] 2>/dev/null; then
    UPD_STR="Up to date"
  elif [ -n "$UPD_SEC" ] && [ "$UPD_SEC" -gt 0 ] 2>/dev/null; then
    UPD_STR="${UPD_ALL} package(s) available (${UPD_SEC} security)"
  else
    UPD_STR="${UPD_ALL} package(s) available"
  fi
fi

# Reboot required
REBOOT=""
[ -f /var/run/reboot-required ] && REBOOT=1

# Recent logins of the current user only. Listing every admin's source
# IPs would leak cross-admin movement patterns across the ops team.
# -w: wide format so IPv6 and long IPs are not truncated. -n 20 buffer
# feeds the grep filter enough input that the head -3 still has three
# real entries to pick after pseudo-users are stripped.
#
# LUSER-empty guard: all three fallbacks above (logname, who -m, $USER)
# can return empty in a chroot or no-utmp environment. `last -w -n 20 ""`
# degenerates to an unfiltered `last -w -n 20` that prints fleet-wide
# login history — exactly the cross-admin leak the scope-to-user policy
# exists to prevent. `--` guards against usernames starting with `-`.
#
# `timeout 2` caps the wtmp read at 2s. Every other
# external command in this hot path is already timeout-wrapped (see the
# fail2ban / docker / curl probes below). `last -w` reads /var/log/wtmp
# directly; on a host where /var/log lives on slow NFS, a stuck mount
# would block SSH login behind the MOTD render. Same posture as the
# rest of the script.
RLOGINS=""
if [ "$MOTD_SHOW_RECENT_LOGINS" = "true" ] && [ -n "$LUSER" ]; then
  RLOGINS=$(timeout 2 last -w -n 20 -- "$LUSER" 2>/dev/null | grep -Ev '^$|^wtmp|^(reboot|shutdown|runlevel) |still logged in' | head -3)
fi

# ── Service checks ──
SVC="" SEC=""

if [ "$MOTD_SHOW_SERVICES" = "true" ]; then

# Hotpath binary availability probes.
#
# `hash NAME` is a bash builtin — no fork, no exec. On success it walks
# PATH once and stores the resolved path in bash's internal hash table,
# so every later `NAME arg…` invocation in this script skips the PATH
# walk entirely (glibc's execvp(3) otherwise calls execve on every PATH
# entry until one succeeds — typically 3-5 failed execves per binary
# before the real one hits, all visible in strace).
#
# A previous revision of this block used `FOO_BIN=$(command -v foo)`
# which was worse on both axes: command substitution always opens a
# subshell (10 extra forks per login), and `command -v` does NOT
# populate the hash table, so every later invocation still paid the
# PATH-walk cost. `hash` is the correct idiom — this note exists to
# prevent a re-regression.
#
# Gates downstream use `(( HAS_FOO ))` — arithmetic evaluation is also
# a builtin, so the whole probe+gate path through this script is
# fork-free.
HAS_FAIL2BAN=0;  hash fail2ban-client 2>/dev/null && HAS_FAIL2BAN=1
HAS_IPSET=0;     hash ipset           2>/dev/null && HAS_IPSET=1
HAS_AUREPORT=0;  hash aureport        2>/dev/null && HAS_AUREPORT=1
HAS_DOCKER=0;    hash docker          2>/dev/null && HAS_DOCKER=1
HAS_NETBIRD=0;   hash netbird         2>/dev/null && HAS_NETBIRD=1
HAS_WG=0;        hash wg              2>/dev/null && HAS_WG=1
HAS_OPENVPN=0;   hash openvpn         2>/dev/null && HAS_OPENVPN=1
HAS_RESTIC=0;    hash restic          2>/dev/null && HAS_RESTIC=1
HAS_BORG=0;      hash borg            2>/dev/null && HAS_BORG=1
HAS_SYSTEMCTL=0; hash systemctl       2>/dev/null && HAS_SYSTEMCTL=1

# _service_active — is the systemd unit named $1 currently active?
# Used by fail2ban and docker to distinguish "CLI installed" (hash)
# from "daemon actually running". Without this check a stopped
# fail2ban renders in the MOTD as a healthy green bullet + "no banned
# IPs", which is the exact opposite of what an operator needs to see.
# Capped at 2 s — a stuck systemd bus must never block SSH login.
# Returns 1 (absent/stopped) on hosts without systemctl, which is the
# safe default: we fall back to the binary-present-only gating.
_service_active() {
  (( HAS_SYSTEMCTL )) || return 1
  timeout 2 systemctl is-active --quiet "$1" 2>/dev/null
}

# fail2ban — bounded-cost per-IP detail.
# Per-IP times come from the in-memory state via
# `fail2ban-client get <jail> banip --with-time` (fail2ban 0.11+) — no
# log file scans. MAX_DETAIL caps the detail block so a brute-force
# avalanche cannot balloon the MOTD.
#
# Service-state split: `hash fail2ban-client` only tells us the CLI is
# installed, not that the daemon is answering. When the service is
# stopped, `fail2ban-client status` prints a socket error to stderr
# and exits non-zero — the original code swallowed it with 2>/dev/null
# and fell through to "no banned IPs" (green), which presented a
# DISABLED brute-force defence as HEALTHY. The explicit _service_active
# gate below renders a red "service stopped" line instead.
BANNED_DETAIL=""
if (( HAS_FAIL2BAN )) && ! _service_active fail2ban; then
  SVC+=" ${RED}●${RST} fail2ban"
  SEC+="\n    ${DIM}fail2ban:${RST}     ${RED}service stopped${RST}"
elif (( HAS_FAIL2BAN )); then
  # Parse the jail list into an array so a jail name containing a space
  # (rare but legal in fail2ban's configuration) does not split mid-word
  # across the loop iterations below. `read -a` handles this correctly;
  # `for j in $JAILS` would not. Numeric guard with regex catches a
  # non-numeric result from the fail2ban-client parser and coerces to 0.
  JAILS_RAW=$(timeout 2 fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://;s/,/ /g')
  read -ra JAIL_ARR <<<"$JAILS_RAW"
  TB=0
  for j in "${JAIL_ARR[@]}"; do
    [ -n "$j" ] || continue
    n=$(timeout 2 fail2ban-client status "$j" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    TB=$((TB + n))
  done
  if [ "$TB" -gt 0 ]; then
    SVC+=" ${YLW}●${RST} fail2ban"
    SEC+="\n    ${DIM}fail2ban:${RST}     ${YLW}${TB} IP(s) banned${RST}"
    MAX_DETAIL=10
    if [ "$TB" -le "$MAX_DETAIL" ]; then
      NOW_TS=$(date +%s)
      for j in "${JAIL_ARR[@]}"; do
        [ -n "$j" ] || continue
        while IFS=$'\t' read -r ip rest; do
          [ -z "$ip" ] && continue
          # Defence in depth: strip C0 control bytes (0x01-0x1F) + DEL
          # (0x7F) from fail2ban-client output before it reaches the
          # MOTD printf. The CLI output is well-formed today, but a
          # compromised fail2ban binary, a future format change, or a
          # jail name carrying an escape byte would otherwise emit raw
          # ESC sequences onto every admin's terminal. Bash parameter
          # expansion is fork-free — important because this sits inside
          # the per-ban loop (capped at MAX_DETAIL=10, still hot).
          ip=${ip//[$'\001'-$'\037\177']/}
          rest=${rest//[$'\001'-$'\037\177']/}
          REL="recently"
          # One fewer fork than `$(echo "$rest" | awk '{print $1" "$2}')`.
          # `read` splits on IFS and `_` discards any remaining fields.
          # The explicit default covers fail2ban output that carries
          # only an IP with no timestamp trailer (rare but not impossible
          # on a jail that still uses the legacy `banip` without `--with-time`).
          read -r _bts_date _bts_time _ <<<"${rest:-}"
          BTS="${_bts_date:-} ${_bts_time:-}"
          BEP=$(date -d "$BTS" +%s 2>/dev/null || echo 0)
          if [ "$BEP" -gt 0 ]; then
            D=$((NOW_TS - BEP))
            if   [ "$D" -lt 60 ];    then REL="${D}s ago"
            elif [ "$D" -lt 3600 ];  then REL="$((D/60)) min ago"
            elif [ "$D" -lt 86400 ]; then REL="$((D/3600)) hours ago"
            else                          REL="$((D/86400)) days ago"
            fi
          fi
          # Route the colour literals through the gated ${RED}/${DIM}/${RST}
          # vars so a non-TTY consumer (`ssh host true`, scp capture, rsync
          # over ssh, CI log scrape) receives a clean tab-separated row
          # instead of raw ANSI escape bytes. Double quotes so bash
          # interpolates the gated vars into the printf format string;
          # when the gate is off (non-TTY), all four expand to "" and
          # the escape literals simply vanish.
          BANNED_DETAIL+=$(printf "\n    ${RED}%-16s${RST} ${DIM}%-17s %-13s${RST}" "$ip" "$j" "$REL")
        done < <(timeout 2 fail2ban-client get "$j" banip --with-time 2>/dev/null)
      done
    else
      BANNED_DETAIL+=$(printf "\n    ${DIM}(%d bans across %d jail(s) — run 'fail2ban-client status' for detail)${RST}" "$TB" "${#JAIL_ARR[@]}")
    fi
  else
    SVC+=" ${GRN}●${RST} fail2ban"
    SEC+="\n    ${DIM}fail2ban:${RST}     ${GRN}no banned IPs${RST}"
  fi
fi

# Static IP reputation blocklist (ipset). `-t list` prints only the
# header — no member enumeration of tens of thousands of entries.
# Every external call is `timeout 2`-wrapped: a hung netlink socket on
# ipset or a stuck systemd bus must never stall the SSH login path.
if (( HAS_IPSET )) && timeout 2 ipset -t list blocklist-v4 &>/dev/null; then
  BL_COUNT=$(timeout 2 ipset -t list blocklist-v4 2>/dev/null | awk -F': ' '/Number of entries/ {print $2}')
  BL_COUNT=${BL_COUNT:-0}
  BL_LAST=$(timeout 2 systemctl show blocklist-update.timer -p LastTriggerUSec --value 2>/dev/null)
  BL_REL="unknown"
  if [ -n "$BL_LAST" ] && [ "$BL_LAST" != "0" ] && [ "$BL_LAST" != "n/a" ]; then
    BL_EP=$(date -d "$BL_LAST" +%s 2>/dev/null || echo 0)
    if [ "$BL_EP" -gt 0 ]; then
      D=$(( $(date +%s) - BL_EP ))
      if   [ "$D" -lt 60 ];    then BL_REL="${D}s ago"
      elif [ "$D" -lt 3600 ];  then BL_REL="$((D/60)) min ago"
      elif [ "$D" -lt 86400 ]; then BL_REL="$((D/3600))h ago"
      else                          BL_REL="$((D/86400))d ago"
      fi
    fi
  fi
  if [ "$BL_COUNT" -gt 0 ]; then
    SVC+=" ${GRN}●${RST} Blocklist"
    SEC+="\n    ${DIM}Blocklist:${RST}    ${GRN}${BL_COUNT} IPs${RST} ${DIM}(updated ${BL_REL})${RST}"
  else
    SVC+=" ${YLW}●${RST} Blocklist"
    SEC+="\n    ${DIM}Blocklist:${RST}    ${YLW}empty${RST} ${DIM}(update pending or failed)${RST}"
  fi
fi

# Wazuh — filter optional daemons that exit cleanly when their feature
# is not configured (clusterd: only multi-node; agentlessd: only with
# <agentless>; integratord: only with remote integrations; dbd: legacy;
# csyslogd: only with <csyslog_output>).
if [ -x /var/ossec/bin/wazuh-control ]; then
  WZ=$(timeout 2 /var/ossec/bin/wazuh-control status 2>/dev/null)
  if [ -n "$WZ" ]; then
    WZ=$(echo "$WZ" | grep -Ev '^wazuh-(clusterd|agentlessd|integratord|dbd|csyslogd) not running')
    WR=$(echo "$WZ" | grep -c 'is running')
    WT=$(echo "$WZ" | wc -l | tr -d ' ')
    if [ "${WR:-0}" -eq "${WT:-0}" ] && [ "${WT:-0}" -gt 0 ]; then
      SVC+=" ${GRN}●${RST} Wazuh"
      SEC+="\n    ${DIM}Wazuh:${RST}        ${GRN}running (${WR}/${WT} services)${RST}"
    else
      SVC+=" ${RED}●${RST} Wazuh"
      SEC+="\n    ${DIM}Wazuh:${RST}        ${YLW}${WR}/${WT} services running${RST}"
    fi
  fi
fi

# auditd — skip the aureport fork entirely when audit.log is empty.
# aureport otherwise walks the whole log even when there is nothing to
# report, which is needlessly expensive on the SSH login path.
if (( HAS_AUREPORT )) && timeout 2 systemctl is-active auditd &>/dev/null \
   && [ -s /var/log/audit/audit.log ]; then
  AA=$(timeout 2 aureport --anomaly 2>/dev/null | grep -c '^[0-9]' || true)
  if [ "${AA:-0}" -gt 0 ]; then
    SVC+=" ${YLW}●${RST} auditd"
    SEC+="\n    ${DIM}auditd:${RST}       ${YLW}${AA} anomaly event(s)${RST}"
  else
    SVC+=" ${GRN}●${RST} auditd"
    SEC+="\n    ${DIM}auditd:${RST}       ${GRN}no anomalies${RST}"
  fi
fi

# Salt Minion — master from on-disk config, last-apply timestamp from
# the mtime of a marker file touched by the motd installer (or by a
# downstream provisioning system) at every state.apply.
#
# The previous Salt-only path called `salt-call --local` twice on every
# SSH login — each call boots the Salt Python interpreter (~300–800 ms
# on LXC). Two disk reads replace the two interpreter boots:
#   1. awk over /etc/salt/minion.d/*.conf for the master scalar
#   2. `date -r` on the marker file for last-apply mtime
# See the motd docs for the marker-file convention.
if timeout 2 systemctl is-enabled salt-minion &>/dev/null; then
  if timeout 2 systemctl is-active salt-minion &>/dev/null; then
    SM=$(awk '/^master:/ {print $2; exit}' /etc/salt/minion.d/*.conf /etc/salt/minion 2>/dev/null)
    LRF=""
    [ -f "${MOTD_CACHE_DIR}/salt-status" ] && \
      LRF=$(date -r "${MOTD_CACHE_DIR}/salt-status" '+%Y-%m-%d %H:%M' 2>/dev/null)
    SVC+=" ${GRN}●${RST} Salt"
    if [ -n "$LRF" ]; then
      SEC+="\n    ${DIM}Salt:${RST}         ${GRN}running${RST} (master: ${SM:-unknown}, last: ${LRF})"
    else
      SEC+="\n    ${DIM}Salt:${RST}         ${GRN}running${RST} (master: ${SM:-unknown})"
    fi
  else
    SVC+=" ${RED}●${RST} Salt"
    SEC+="\n    ${DIM}Salt:${RST}         ${RED}not running${RST}"
  fi
fi

# NetBird VPN — `netbird status -d` can block for 5–10 s when the
# management connection is reconnecting. Hard cap at 2s.
if (( HAS_NETBIRD )); then
  NB=$(timeout 2 netbird status -d 2>/dev/null)
  if [ -n "$NB" ] && echo "$NB" | grep -q 'Management: Connected'; then
    # Parse "Peers count: N/M Connected" without PCRE so the script
    # also runs on stripped-down BSD/busybox grep — sed extracts the
    # two integers from the first match cleanly.
    NC=$(echo "$NB" | sed -n 's/.*Peers count:[[:space:]]*\([0-9]\{1,\}\)\/[0-9]\{1,\}.*/\1/p' | head -1)
    NT=$(echo "$NB" | sed -n 's/.*Peers count:[[:space:]]*[0-9]\{1,\}\/\([0-9]\{1,\}\).*/\1/p' | head -1)
    NP=$(echo "$NB" | grep -c 'Connection type: P2P')
    NR=$(echo "$NB" | grep -c 'Connection type: Relayed')
    SVC+=" ${GRN}●${RST} Netbird"
    SEC+="\n    ${DIM}Netbird:${RST}      ${GRN}connected${RST} (${NC}/${NT} peers: ${NP} P2P, ${NR} relayed)"
  else
    SVC+=" ${RED}●${RST} Netbird"
    SEC+="\n    ${DIM}Netbird:${RST}      ${RED}disconnected${RST}"
  fi
fi

# Docker — `docker ps` blocks on the dockerd unix socket which can
# itself be blocked when the daemon is under load. Hard cap at 2 s.
# Previously we called `docker ps` twice (once for running IDs, once
# for all IDs) which doubled the socket-roundtrip cost. One call with
# `-a --format '{{.State}}'` streams the state of every container and
# we count running vs. total in-shell. Measured win: ~100-150 ms on a
# host with a few containers, and exactly one timeout ceiling instead
# of two.
#
# Service-state split (mirrors the fail2ban fix above): a plain
# `hash docker` only confirms the CLI binary is on PATH. With dockerd
# stopped, `docker ps` silently fails and the counters render as
# "0 running, 0 stopped" under a dim bullet — easily misread as "no
# containers on this host". Check the daemon state explicitly and
# render a red "service stopped" line when applicable so operators
# can tell "nothing scheduled" apart from "dockerd is down".
if (( HAS_DOCKER )) && ! _service_active docker; then
  SVC+=" ${RED}●${RST} Docker"
  SEC+="\n    ${DIM}Docker:${RST}       ${RED}service stopped${RST}"
elif (( HAS_DOCKER )); then
  DOCKER_STATES=$(timeout 2 docker ps -a --format '{{.State}}' 2>/dev/null)
  DR=0 DA=0
  if [ -n "$DOCKER_STATES" ]; then
    while IFS= read -r _state; do
      [ -z "$_state" ] && continue
      DA=$((DA + 1))
      [ "$_state" = "running" ] && DR=$((DR + 1))
    done <<< "$DOCKER_STATES"
  fi
  DS=$((DA - DR))
  if [ "$DR" -gt 0 ]; then
    SVC+=" ${GRN}●${RST} Docker"
  elif [ "$DA" -gt 0 ]; then
    SVC+=" ${YLW}●${RST} Docker"
  else
    SVC+=" ${DIM}●${RST} Docker"
  fi
  SEC+="\n    ${DIM}Docker:${RST}       ${DR} running, ${DS} stopped"
fi

# ── Dynamic service discovery ──
#
# Beyond the explicitly-handled services above, surface any of a
# curated list of common infrastructure daemons that happen to be
# installed on this host. Zero per-host config — if the package is
# installed, a status line appears.
#
# Hot-path cost is capped at ONE systemctl fork regardless of
# candidate-list length:
#   1. Per-candidate "is this unit installed?" check is a pure stat()
#      against the four systemd unit-file search paths — no fork, no
#      D-Bus round-trip. Previously this used `systemctl list-unit-files`
#      which added ~450 ms to the SSH login path even when every
#      candidate was absent on Ubuntu 24.04 LXC. `list-unit-files` reads
#      the same directories we now stat.
#   2. One batched `is-active "${units[@]}"` resolves the state of
#      every surviving candidate at once.
#
# _have_unit: return 0 if a unit file for $1 is installed in any of
# the standard systemd unit-file search paths. This mirrors what
# `systemctl list-unit-files` enumerates, minus the D-Bus round-trip.
#
# Search order matches systemd's own precedence — a unit file present
# in /etc overrides one in /usr, but for presence detection any hit
# is enough.
_have_unit() {
  local u="$1"
  [ -f "/etc/systemd/system/$u" ]      || \
  [ -f "/run/systemd/system/$u" ]      || \
  [ -f "/lib/systemd/system/$u" ]      || \
  [ -f "/usr/lib/systemd/system/$u" ]
}

if (( HAS_SYSTEMCTL )); then

  # "Display label|unit.file" pairs. Multiple candidate units can share
  # a label (Zabbix agent2 vs legacy agent, Sophos SPL vs SAV) — the
  # dedup loop keeps the first hit so the same label never renders twice.
  CAND=(
    # Core system services — always present on a Debian/Ubuntu minion,
    # surfaced deliberately so the Services line carries a "we're
    # watching" signal for the two daemons every operator cares about.
    # On Debian/Ubuntu the unit file is `ssh.service`; on
    # RHEL/Fedora/SUSE it is `sshd.service`. Both candidates carry the
    # "SSH" label and the dedup loop below keeps the first hit, so
    # exactly one entry renders regardless of distro.
    "SSH|ssh.service"
    "SSH|sshd.service"
    "UFW|ufw.service"
    # Databases
    "PostgreSQL|postgresql.service"
    "MariaDB|mariadb.service"
    "MySQL|mysql.service"
    "Redis|redis-server.service"
    "MongoDB|mongod.service"
    "InfluxDB|influxdb.service"
    # Web servers & reverse proxies
    "Nginx|nginx.service"
    "Apache|apache2.service"
    "Caddy|caddy.service"
    "Traefik|traefik.service"
    "HAProxy|haproxy.service"
    # Container runtimes (Docker handled above with rich status)
    "Containerd|containerd.service"
    "Podman|podman.socket"
    # Security / EDR
    "CrowdSec|crowdsec.service"
    "ClamAV|clamav-daemon.service"
    "Sophos|sophos-spl.service"
    "Sophos|sav-protect.service"
    # Monitoring
    "Prometheus|prometheus.service"
    "Grafana|grafana-server.service"
    "Zabbix Agent|zabbix-agent2.service"
    "Zabbix Agent|zabbix-agent.service"
    "SNMP|snmpd.service"
    # Network / HA
    "Keepalived|keepalived.service"
    # Mail
    "Postfix|postfix.service"
    "Dovecot|dovecot.service"
    # Directory services
    "Samba|smbd.service"
    "SSSD|sssd.service"
    # Backup agents
    "Veeam|veeamservice.service"
    # Infrastructure agents
    "NinjaOne|ninjarmm-agent.service"
    # Proxmox: pve-cluster provides the cluster filesystem and is
    # required for every other pve-* daemon — the most reliable
    # "this host really is running PVE" marker.
    "Proxmox|pve-cluster.service"
  )

  DYN_LABELS=()
  DYN_UNITS=()
  # Pipe-wrapped dedup marker. Using '|' as the separator (instead of a
  # plain space) prevents false prefix matches between labels that share
  # a prefix.
  SEEN="|"
  for entry in "${CAND[@]}"; do
    lbl=${entry%%|*}
    u=${entry##*|}
    _have_unit "$u" || continue
    case "$SEEN" in *"|$lbl|"*) continue ;; esac
    SEEN+="$lbl|"
    DYN_LABELS+=("$lbl")
    DYN_UNITS+=("$u")
  done

  # Count the populated array via the length intrinsic — `${arr[*]}`
  # on an empty array under `set -u` fires "unbound variable" on older
  # bash (3.2 / 4.0); `${#arr[@]}` is safe on every bash.
  if (( ${#DYN_UNITS[@]} > 0 )); then
    # Single batched systemctl fork. is-active emits one line per
    # argument in input order with a fixed English-only vocabulary.
    mapfile -t DYN_STATES < <(timeout 2 systemctl is-active "${DYN_UNITS[@]}" 2>/dev/null)
    for i in "${!DYN_LABELS[@]}"; do
      case "${DYN_STATES[i]:-unknown}" in
        active) SVC+=" ${GRN}●${RST} ${DYN_LABELS[i]}" ;;
        failed) SVC+=" ${RED}●${RST} ${DYN_LABELS[i]}" ;;
        *)      SVC+=" ${YLW}●${RST} ${DYN_LABELS[i]}" ;;
      esac
    done
  fi
fi

# WireGuard — almost always started via the wg-quick@<iface> template,
# so list-unit-files only matches the (abstract) template entry. Read
# the live state from the kernel module via `wg show` BUT also require
# at least one /etc/wireguard/*.conf so we don't claim WireGuard on
# every NetBird host (NetBird uses the same kernel module).
if (( HAS_WG )) && compgen -G "/etc/wireguard/*.conf" >/dev/null 2>&1; then
  if [ -n "$(timeout 2 wg show interfaces 2>/dev/null)" ]; then
    SVC+=" ${GRN}●${RST} WireGuard"
  else
    SVC+=" ${YLW}●${RST} WireGuard"
  fi
fi

# OpenVPN — same template-unit problem. Binary detection + bounded
# pgrep is cheaper than enumerating every openvpn@*.service instance.
if (( HAS_OPENVPN )); then
  if pgrep -x openvpn >/dev/null 2>&1; then
    SVC+=" ${GRN}●${RST} OpenVPN"
  else
    SVC+=" ${YLW}●${RST} OpenVPN"
  fi
fi

# Restic / BorgBackup are CLI tools, not daemons. Surface them if the
# binary exists; upgrade to green if at least one loaded timer has a
# matching name. One list-timers fork covers both tools.
if (( HAS_RESTIC )) || (( HAS_BORG )); then
  SYSD_TIMERS=$(timeout 2 systemctl list-timers --all --no-legend --no-pager 2>/dev/null)
  if (( HAS_RESTIC )); then
    if grep -qi restic <<<"$SYSD_TIMERS"; then
      SVC+=" ${GRN}●${RST} Restic"
    else
      SVC+=" ${DIM}●${RST} Restic"
    fi
  fi
  if (( HAS_BORG )); then
    if grep -qi borg <<<"$SYSD_TIMERS"; then
      SVC+=" ${GRN}●${RST} BorgBackup"
    else
      SVC+=" ${DIM}●${RST} BorgBackup"
    fi
  fi
fi

fi  # MOTD_SHOW_SERVICES

# ── Output ──
P=16  # label pad width

echo ""
# printf '%b\n' in place of `echo -e` throughout the output section:
# echo -e is POSIX-undefined and re-expands backslash sequences in
# every interpolated variable value. Switching to %b processes only
# format-string backslashes, not interpolated payloads, which matters
# for blocks like BANNED_DETAIL / SEC / $RLOGINS that carry text from
# external daemons (fail2ban-client, last).
#
# Colour routing note: every printf format string below interpolates
# the gated ${DIM}/${RST}/... vars rather than hardcoded `\e[2m` /
# `\e[0m` literals. Under the TTY gate (first colour block at the top
# of this file) those vars are empty when stdout is not a terminal,
# so a scripted SSH consumer receives plain text. Hardcoded escape
# literals in the format string would survive the gate and leak raw
# ANSI bytes into rsync/scp/CI-captured streams — the exact problem
# the gate exists to solve.
printf '%b\n' "  ${CYN}${MOTD_BOX_TOP}${RST}"
printf '%b\n' "  ${CYN}│${RST}${BLD}${MOTD_HEADER_LEFT}${CYN}${COMPANY_NAME}${RST}${BLD}${MOTD_SUBTITLE}${MOTD_HEADER_RIGHT}${CYN}│${RST}"
printf '%b\n' "  ${CYN}${MOTD_BOX_BOTTOM}${RST}"
echo ""
printf "  ${DIM}%-${P}s${RST} %s${DIM}@${RST}%s\n" "Logged as:" "$LUSER" "$FQDN"
printf "  ${DIM}%-${P}s${RST} " "Privileges:"; printf '%b\n' "$PRIV"
printf "  ${DIM}%-${P}s${RST} %s active" "Sessions:" "$SESS"
[ -n "$SESS_USERS" ] && printf " (%s)" "$SESS_USERS"
echo ""
echo ""
printf "  ${DIM}%-${P}s${RST} %s\n" "OS:" "$OS"
printf "  ${DIM}%-${P}s${RST} %s\n" "Type:" "$STYPE"
if [ "$MOTD_VERBOSE" = "true" ] && [ -n "$KERN" ]; then
  printf "  ${DIM}%-${P}s${RST} %s\n" "Kernel:" "$KERN"
fi
printf "  ${DIM}%-${P}s${RST} %s\n" "IP addresses:" "$IPS"
[ -n "$PUBIP" ] && printf "  ${DIM}%-${P}s${RST} %s\n" "Public IP:" "$PUBIP"
printf "  ${DIM}%-${P}s${RST} %s\n" "Uptime:" "$UP"
printf "  ${DIM}%-${P}s${RST} %s, %s, %s (%s cores)\n" "Load average:" "$L1" "$L5" "$L15" "$CORES"
echo ""
printf "  ${DIM}%-${P}s${RST} RAM — %s used, %s available    / %s\n" "Memory:" "$(h "$MU")" "$(h "$MA")" "$(h "$MT")"
printf "  %${P}s " ""; bar "$MU" "$MT"; echo ""
printf "  ${DIM}%-${P}s${RST} %s used, %s free               / %s\n" "Disk (/):" "$(h "$DU")" "$(h "$DF")" "$(h "$DT")"
printf "  %${P}s " ""; bar "$DU" "$DT"; echo ""
if [ -n "$EXTRA_MOUNT" ]; then
  printf "  ${DIM}%-${P}s${RST} %s used, %s free               / %s\n" "Disk ($EXTRA_MOUNT):" "$(h "$EXTRA_DU")" "$(h "$EXTRA_DF")" "$(h "$EXTRA_DT")"
  printf "  %${P}s " ""; bar "$EXTRA_DU" "$EXTRA_DT"; echo ""
fi
echo ""
if [ "$MOTD_SHOW_SERVICES" = "true" ] && [ -n "$SVC" ]; then
  printf "  ${DIM}%-${P}s${RST}" "Services:"
  printf '%b\n' "$SVC"
fi
if [ "$MOTD_SHOW_UPDATES" = "true" ] && [ -n "$UPD_STR" ]; then
  printf "  ${DIM}%-${P}s${RST} %s\n" "Updates:" "$UPD_STR"
fi
[ -n "$REBOOT" ] && printf '%b\n' "  ${YLW}⚠ System reboot required${RST}"

# Security / "Currently banned" gating:
#
# When MOTD_SECURITY_PRIV_ONLY=true, suppress the Security and Currently-
# banned sections for non-privileged users. The full fail2ban blocklist,
# running-security-tool state, and Wazuh health are information a
# standard shell user on a shared bastion should not see by default.
# When MOTD_SECURITY_PRIV_ONLY=false (the legacy default) every user
# keeps the current view — backwards compatible for single-admin VMs.
_show_security=true
if [ "$MOTD_SECURITY_PRIV_ONLY" = "true" ] && [ "$IS_PRIV" != "true" ]; then
  _show_security=false
fi
if [ "$MOTD_SHOW_SERVICES" = "true" ] && [ "$_show_security" = "true" ] && [ -n "$SEC" ]; then
  echo ""
  printf '%b\n' "  ${CYN}$(_section 'Security')${RST}"
  printf '%b\n' "${SEC:2}"
fi
if [ "$MOTD_SHOW_SERVICES" = "true" ] && [ "$_show_security" = "true" ] && [ -n "$BANNED_DETAIL" ]; then
  echo ""
  printf '%b\n' "  ${CYN}$(_section 'Currently banned')${RST}"
  printf '%b\n' "${BANNED_DETAIL:2}"
fi
if [ "$MOTD_SHOW_RECENT_LOGINS" = "true" ] && [ -n "$RLOGINS" ]; then
  echo ""
  printf '%b\n' "  ${CYN}$(_section 'Recent Logins')${RST}"
  echo "$RLOGINS" | while IFS= read -r line; do
    printf '%b\n' "    ${DIM}${line}${RST}"
  done
fi
echo ""
if [ -n "$MOTD_FOOTER" ]; then
  printf '%b\n' "  ${DIM}${MOTD_FOOTER}${RST}"
fi
