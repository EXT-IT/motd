#!/usr/bin/env bash
# =============================================================================
# motd — standalone installer
# -----------------------------------------------------------------------------
# Project : motd
# Purpose : Install three pieces of host UX in one pass:
#             1. Pre-login banner    — /etc/issue (ASCII) + /etc/issue.net
#                                       (Unicode), with a legally-enforceable
#                                       warning box.
#             2. Post-login MOTD     — /etc/update-motd.d/10-system-info,
#                                       a single-screen system dashboard.
#             3. sshd integration    — /etc/ssh/sshd_config.d/99-motd-banner.conf
#                                       wiring /etc/issue.net into Banner.
#           Each piece can be installed independently. Backups, atomic
#           writes, dry-run, and self-checks apply to all of them.
# License : Apache-2.0
# Copyright: (c) 2026 EXT IT GmbH
# Homepage : https://github.com/EXT-IT/motd
# -----------------------------------------------------------------------------
# Design notes:
#   - Every banner-box width is derived from ONE constant (BOX_WIDTH) +
#     one helper (_boxline). Hand-counted padding is structurally
#     impossible.
#   - BOX_WIDTH = max(MIN_WIDTH, longest_text_line + 4), capped at 120.
#   - Atomic writes only: tempfile next to target, chmod/chown, mv -f.
#   - Backups are timestamped, 0600 root, with a .latest.bak symlink.
#   - Dry-run never touches disk and renders all three sections.
#   - Self-check after every banner write: re-render and byte-compare.
#   - sshd phase validates with `sshd -t` before reload; on failure the
#     drop-in is reverted to its previous state immediately.
#
# Exit codes:
#   0 success          1 usage error         2 permission/root error
#   3 validation error 4 write error
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ERR trap: when `set -e` kills the script, print the exact location so the
# silent-exit pattern ("banner phase: starting" then nothing) becomes debuggable.
# The trap fires BEFORE the shell exits, giving file + line + failed command.
# It does NOT fire inside `if`, `while`, `&&`, `||` conditions — only on
# genuinely unexpected failures. Output goes to stderr to stay visible even
# when stdout is redirected (e.g. inside a pipeline / process substitution).
trap '_rc=$?; printf "[ERR] %s:%s: command \"%s\" exited with %d\n" \
    "${BASH_SOURCE[0]}" "${LINENO}" "${BASH_COMMAND}" "$_rc" >&2' ERR

# -----------------------------------------------------------------------------
# Locale: ensure UTF-8 for Unicode box drawing. Fall back to C if C.UTF-8 is
# unavailable — in that case STYLE=double/single will still write the bytes,
# they just won't render correctly in a plain C console. Parsing never
# depends on locale.
#
# Gotcha: bash 3.2 (macOS) + `set -o pipefail` + a short pipeline like
# `locale -a | grep -q X` propagates SIGPIPE (exit 141) from the upstream
# command when grep closes stdin on first match, marking the pipeline as
# failed and flipping the if-branch. We capture the list into a variable
# first so the grep runs on an in-memory string, side-stepping the issue.
# -----------------------------------------------------------------------------
_available_locales="$(locale -a 2>/dev/null || true)"
if printf '%s\n' "$_available_locales" | grep -qx 'C.UTF-8'; then
    export LC_ALL=C.UTF-8
elif printf '%s\n' "$_available_locales" | grep -qix 'en_US.utf-\?8'; then
    export LC_ALL=en_US.UTF-8
else
    export LC_ALL=C
fi
unset _available_locales
export LANG="$LC_ALL"

# IMPORTANT: this constant is NOT named `VERSION` because every modern
# Linux distro's /etc/os-release defines a `VERSION=` line (e.g.
# VERSION="24.04.3 LTS (Noble Numbat)"). When detect_distro sources
# /etc/os-release in a subshell, a readonly VERSION in the parent
# would propagate into the subshell and the assignment inside
# /etc/os-release would fail with "VERSION: readonly variable". With
# `set -e` active, the failing subshell kills the whole installer
# silently — the single worst failure mode for a first-impression
# public release. Use MOTD_VERSION throughout.
readonly MOTD_VERSION="1.0.0"
readonly PROG_NAME="motd"
readonly PROJECT_URL="https://github.com/EXT-IT/motd"

# -----------------------------------------------------------------------------
# Defaults + env import. Precedence is: CLI flags > env vars > config file
# > built-in defaults. To honour that, we record which variables were set
# by the environment at script start (env_set_<KEY>=1) so the config
# loader knows not to clobber them.
#
# IMPORTANT: `LANGUAGE` is deliberately NOT in this list. It is a GNU
# locale-system env var (on Debian/Ubuntu typically `en_US:en`), which
# would clash with our `en`/`de` language toggle on every modern Linux
# login shell. We ignore any inherited value and reset it explicitly
# below; config file and CLI flags still set it normally.
# -----------------------------------------------------------------------------
for _k in COMPANY_NAME CONTACT STYLE MIN_WIDTH STATUTE STATUTE_ASCII \
          WARNING_LINES_OVERRIDE \
          ISSUE_FILE ISSUE_NET_FILE CLEAR_MOTD BACKUP BACKUP_DIR SSHD_RELOAD \
          CONFIG_FILE BANNER_ENABLED \
          MOTD_ENABLED MOTD_SUBTITLE MOTD_MIN_WIDTH MOTD_VERBOSE MOTD_FOOTER \
          MOTD_SHOW_SERVICES MOTD_SHOW_UPDATES MOTD_SHOW_RECENT_LOGINS \
          MOTD_SECURITY_PRIV_ONLY \
          MOTD_PUBIP_URL MOTD_SCRIPT_PATH MOTD_CONFIG_PATH MOTD_CACHE_DIR \
          SSHD_BANNER_MANAGE SSHD_BANNER_DROPIN; do
    if [[ -n "${!_k+set}" ]]; then
        printf -v "env_set_${_k}" '1'
    fi
done
unset _k

# Reset LANGUAGE unconditionally — see the "IMPORTANT" note above.
# The config file and --language flag still control it; only the
# env-inherited value (usually `en_US:en` on Linux) is ignored.
LANGUAGE="en"

# -- Banner defaults --
COMPANY_NAME="${COMPANY_NAME:-Managed Server}"
CONTACT="${CONTACT:-}"
STYLE="${STYLE:-double}"
MIN_WIDTH="${MIN_WIDTH:-56}"
STATUTE="${STATUTE:-§202a StGB}"
STATUTE_ASCII="${STATUTE_ASCII:-section 202a StGB}"
# WARNING_LINES_OVERRIDE — optional custom legal text that replaces the
# language preset in /etc/issue.net. Two input layers:
#   CLI:        repeatable `--warning-lines "Line 1" --warning-lines "Line 2"`
#               appends directly to WARNING_LINES_OVERRIDE_ARR.
#   Config:     WARNING_LINES_OVERRIDE="Line 1\nLine 2" in /etc/motd.conf.
#               The literal \n (backslash + n) is the line separator; we
#               split on it after load_config + parse_args so CLI still
#               wins over config. Real newlines are rejected by the
#               regex parser in load_config, so there is no ambiguity.
# The salt variant (banner.sls warning_lines_override) is a true YAML list;
# we stay 1:1 by feeding CLI straight into the array and treating the
# scalar as the persistence / round-trip form only.
WARNING_LINES_OVERRIDE="${WARNING_LINES_OVERRIDE:-}"
WARNING_LINES_OVERRIDE_ARR=()
ISSUE_FILE="${ISSUE_FILE:-/etc/issue}"
ISSUE_NET_FILE="${ISSUE_NET_FILE:-/etc/issue.net}"
CLEAR_MOTD="${CLEAR_MOTD:-true}"
BACKUP="${BACKUP:-true}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/motd}"
SSHD_RELOAD="${SSHD_RELOAD:-true}"
CONFIG_FILE="${CONFIG_FILE:-}"
BANNER_ENABLED="${BANNER_ENABLED:-true}"

# -- MOTD defaults --
MOTD_ENABLED="${MOTD_ENABLED:-true}"
MOTD_SUBTITLE="${MOTD_SUBTITLE:- · Managed Server}"
MOTD_MIN_WIDTH="${MOTD_MIN_WIDTH:-54}"
MOTD_VERBOSE="${MOTD_VERBOSE:-false}"
MOTD_FOOTER="${MOTD_FOOTER:-}"
MOTD_SHOW_SERVICES="${MOTD_SHOW_SERVICES:-true}"
MOTD_SHOW_UPDATES="${MOTD_SHOW_UPDATES:-true}"
MOTD_SHOW_RECENT_LOGINS="${MOTD_SHOW_RECENT_LOGINS:-true}"
# MOTD_SECURITY_PRIV_ONLY — when true, the runtime MOTD script only
# renders the post-login Security / Currently-banned blocks for users
# that are members of sudo / wheel / admin. Relevant on shared bastion
# / jump hosts where the fail2ban blocklist and Wazuh health should
# not be visible to every SSH session. Default false (unchanged
# legacy behaviour). Mirrored by the Salt pillar
# `login_banner:motd:security_priv_only`.
MOTD_SECURITY_PRIV_ONLY="${MOTD_SECURITY_PRIV_ONLY:-false}"
MOTD_PUBIP_URL="${MOTD_PUBIP_URL:-https://ifconfig.me}"
MOTD_SCRIPT_PATH="${MOTD_SCRIPT_PATH:-/etc/update-motd.d/10-system-info}"
MOTD_CONFIG_PATH="${MOTD_CONFIG_PATH:-/etc/motd.conf}"
MOTD_CACHE_DIR="${MOTD_CACHE_DIR:-/var/cache/motd}"

# -- sshd integration defaults --
SSHD_BANNER_MANAGE="${SSHD_BANNER_MANAGE:-true}"
SSHD_BANNER_DROPIN="${SSHD_BANNER_DROPIN:-/etc/ssh/sshd_config.d/99-motd-banner.conf}"

DRY_RUN=false
FORCE=false
UNINSTALL=false

# Hard caps — see §15 in the spec.
readonly MAX_WIDTH=120
readonly MAX_COMPANY_LEN=64
readonly MAX_CONTACT_LEN=128
readonly MAX_FOOTER_LEN=128
readonly MAX_SUBTITLE_LEN=64
# Per-line cap for --warning-lines entries. Same ceiling as FOOTER/CONTACT
# because the rendered box auto-grows and a single legal line rarely needs
# more headroom. Salt's _KEY_LIMITS does not cap the list elements — we
# cap here because /etc/motd.conf values are hard-limited by the regex
# parser anyway and a sane per-line bound gives a better diagnostic than
# a parser reject on the joined form.
readonly MAX_WARNING_LINE_LEN=128

# =============================================================================
# Logging
# =============================================================================
_use_color() {
    [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]
}

log_info() {
    printf '[info] %s\n' "$*" >&2
}

log_warn() {
    if _use_color; then
        printf '\033[33m[warn]\033[0m %s\n' "$*" >&2
    else
        printf '[warn] %s\n' "$*" >&2
    fi
}

log_error() {
    if _use_color; then
        printf '\033[31m[error]\033[0m %s\n' "$*" >&2
    else
        printf '[error] %s\n' "$*" >&2
    fi
}

log_hint() {
    if _use_color; then
        printf '\033[36m[hint]\033[0m %s\n' "$*" >&2
    else
        printf '[hint] %s\n' "$*" >&2
    fi
}

# -----------------------------------------------------------------------------
# Top-level signal handling.
#
# A Ctrl-C between phase_banner and phase_sshd leaves /etc/issue{,.net}
# written atomically on their own (thanks to atomic_write) but sshd
# not yet reloaded, and the drop-in not yet in place. The state is
# internally consistent — no half-written files, every artefact was
# mv'd atomically — but it does NOT match the operator's intent, and
# a silent exit under set -e can look identical to a successful one.
#
# The handler below logs a loud diagnostic on INT/TERM/HUP and exits
# with the conventional 128+signo code (130 for INT). We deliberately
# do NOT attempt auto-rollback: rolling back a half-applied install
# in a signal handler is the kind of dangerous reverse side-effect
# that causes worse outages than the interrupt itself. The phases
# already take pristine backups on first install, so a clean rollback
# is `uninstall.sh` one command later.
#
# Per-tempfile EXIT traps inside atomic_write / _sshd_install_dropin /
# the MOTD source-rendering block run BEFORE this handler (EXIT is
# different from INT/TERM/HUP), so their cleanup is unaffected. We
# test that by running the installer under `kill -INT <pid>` between
# phase_banner and phase_motd — the tempfiles are reaped cleanly and
# this handler prints the diagnostic without a lingering .motd.XXXXXXXX.
# -----------------------------------------------------------------------------
_on_signal() {
    local _sig="$1"
    log_error "aborted by signal ${_sig} — partial state may remain in /etc"
    log_hint  "re-run install.sh with the same flags to finish, or uninstall.sh to roll back"
    case "$_sig" in
        INT)  exit 130 ;;
        TERM) exit 143 ;;
        HUP)  exit 129 ;;
        *)    exit 1   ;;
    esac
}
trap '_on_signal INT'  INT
trap '_on_signal TERM' TERM
trap '_on_signal HUP'  HUP

# =============================================================================
# Usage / help
# =============================================================================
usage() {
    cat <<'EOF'
motd — pre-login banner + dynamic post-login MOTD installer

Usage:
  install.sh [OPTIONS]

Banner options:
  --company-name NAME        Company/owner shown in the banner
                             (default: "Managed Server", max 64 chars)
  --contact EMAIL            Optional contact line (default: none)
  --language LANG            Warning text language: en | de (default: en)
  --style STYLE              Box style for /etc/issue.net:
                               double (╔═╗║╚═╝) | single (┌─┐│└─┘) | ascii (+=|)
                             (default: double)
  --min-width N              Minimum banner box width; auto-grows
                             (default: 56, max 120)
  --statute TEXT             Legal citation, Unicode form
                             (default: "§202a StGB")
  --statute-ascii TEXT       Legal citation, ASCII form
                             (default: "section 202a StGB")
  --warning-lines TEXT       Override the language preset with custom
                             legal text. REPEATABLE — pass once per
                             line:
                               --warning-lines "Line 1"
                               --warning-lines "Line 2"
                             1:1 parity with salt pillar
                             'login_banner:warning_lines_override'.
                             Config-file form uses single-quoted
                             literal with \n separator:
                               WARNING_LINES_OVERRIDE='Line 1\nLine 2'
                             (max 128 chars per line, no single quote,
                              no shell metacharacters)
  --issue-file PATH          Local-console banner path  (default: /etc/issue)
  --issue-net-file PATH      SSH banner path            (default: /etc/issue.net)
  --no-clear-motd            Do NOT blank /etc/motd before MOTD install runs

MOTD options:
  --motd-subtitle TEXT       Subtitle after company name in the MOTD header
                             box (default: " · Managed Server")
  --motd-min-width N         Minimum MOTD header box width (default: 54)
  --motd-verbose             Show kernel version + public IP in the MOTD
                             (default: off — CIS L1 §1.7.x recon-surface
                             reduction)
  --motd-footer TEXT         Optional dim footer line in the MOTD
                             (default: empty)
  --no-motd-services         Hide the Services / Security blocks
  --no-motd-updates          Hide the Updates line
  --no-motd-logins           Hide the Recent Logins block
  --motd-security-priv-only  Only render the Security / Currently-banned
                             blocks for sudo/wheel/admin users (shared
                             bastion / jump host safety; default: off)
  --motd-script-path PATH    Where to install the MOTD script
                             (default: /etc/update-motd.d/10-system-info)
  --motd-config-path PATH    Where to write the unified config file
                             (default: /etc/motd.conf)
  --motd-cache-dir DIR       Runtime cache directory for the MOTD script
                             (default: /var/cache/motd). Must NOT live
                             under /tmp, /var/tmp, or /dev/shm.
  --sshd-dropin PATH         sshd_config.d drop-in path
                             (default: /etc/ssh/sshd_config.d/99-motd-banner.conf)

Scope:
  --banner-only              Install banner + sshd drop-in (skip MOTD).
                             The sshd drop-in is kept so SSH logins
                             actually SEE the banner — otherwise
                             --banner-only silently leaves the banner
                             invisible over SSH.
  --motd-only                Install MOTD only  (skip banner, skip sshd banner)
  --no-banner                Skip the pre-login banner phase
  --no-motd                  Skip the dynamic MOTD phase
  --no-sshd-banner           Do not write the sshd_config.d drop-in
  --no-sshd-reload           Do not reload sshd after writing the SSH banner

Common:
  --backup-dir DIR           Backup directory (default: /var/backups/motd)
  --no-backup                Skip backing up existing files before overwrite
  --config PATH              Load settings from a shell-style config file
                             (default: /etc/motd.conf if present)
  -n, --dry-run              Render to stdout only; make no changes
  -f, --force                Overwrite without prompting even if no backup
      --uninstall            Run uninstall.sh in the same directory
  -h, --help                 Show this help and exit
      --version              Print version and exit

Precedence (highest wins): CLI flags > env vars > config file > defaults.

Examples:
  sudo ./install.sh --company-name "Acme Corp" --contact "ops@acme.example"
  sudo ./install.sh --config /etc/motd.conf
  sudo ./install.sh --motd-only --motd-footer "Managed by Ansible"
  sudo ./install.sh --banner-only --language de --style single
  sudo ./install.sh --dry-run --motd-verbose
  sudo ./install.sh --uninstall

Exit codes:
  0  success
  1  usage error (bad flag, missing value)
  2  permission/root error
  3  validation error (bad characters, overlong input, unknown option value)
  4  write error
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================
_require_value() {
    # $1 = flag name, $2 = value
    if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]] || [[ "${2:-}" == -?* ]]; then
        log_error "missing value for $1"
        exit 1
    fi
}

parse_args() {
    # Normalise `--foo=bar` to `--foo bar` so the rest of the parser can
    # stay a simple case-statement on one token at a time. GNU-style
    # `--opt=value` and POSIX-style `--opt value` are both expected on a
    # user-facing CLI. Short opts (-n, -h) are left alone because none
    # of them take a value.
    local _expanded=() _arg
    for _arg in "$@"; do
        case "$_arg" in
            --*=*) _expanded+=( "${_arg%%=*}" "${_arg#*=}" ) ;;
            *)     _expanded+=( "$_arg" ) ;;
        esac
    done
    set -- "${_expanded[@]}"
    unset _expanded _arg

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # -- Banner --
            --company-name)
                _require_value "$1" "${2:-}"
                COMPANY_NAME="$2"; shift 2 ;;
            --contact)
                _require_value "$1" "${2:-}"
                CONTACT="$2"; shift 2 ;;
            --language)
                _require_value "$1" "${2:-}"
                LANGUAGE="$2"; shift 2 ;;
            --style)
                _require_value "$1" "${2:-}"
                STYLE="$2"; shift 2 ;;
            --min-width)
                _require_value "$1" "${2:-}"
                MIN_WIDTH="$2"; shift 2 ;;
            --statute)
                _require_value "$1" "${2:-}"
                STATUTE="$2"; shift 2 ;;
            --statute-ascii)
                _require_value "$1" "${2:-}"
                STATUTE_ASCII="$2"; shift 2 ;;
            --warning-lines)
                # Repeatable: each occurrence appends one line to the
                # override array. 1:1 symmetry with Salt's
                # warning_lines_override (true YAML list). Validation
                # happens later in validate_config, one element at a
                # time, so shell-meta / control-char rejects are
                # reported per line rather than on a joined blob.
                _require_value "$1" "${2:-}"
                WARNING_LINES_OVERRIDE_ARR+=( "$2" )
                shift 2 ;;
            --issue-file)
                _require_value "$1" "${2:-}"
                ISSUE_FILE="$2"; shift 2 ;;
            --issue-net-file)
                _require_value "$1" "${2:-}"
                ISSUE_NET_FILE="$2"; shift 2 ;;
            --no-clear-motd)
                CLEAR_MOTD=false; shift ;;
            --no-backup)
                BACKUP=false; shift ;;
            --backup-dir)
                _require_value "$1" "${2:-}"
                BACKUP_DIR="$2"; shift 2 ;;
            --no-sshd-reload)
                SSHD_RELOAD=false; shift ;;

            # -- MOTD --
            --motd-subtitle)
                _require_value "$1" "${2:-}"
                MOTD_SUBTITLE="$2"; shift 2 ;;
            --motd-min-width)
                _require_value "$1" "${2:-}"
                MOTD_MIN_WIDTH="$2"; shift 2 ;;
            --motd-verbose)
                MOTD_VERBOSE=true; shift ;;
            --motd-footer)
                _require_value "$1" "${2:-}"
                MOTD_FOOTER="$2"; shift 2 ;;
            --no-motd-services)
                MOTD_SHOW_SERVICES=false; shift ;;
            --no-motd-updates)
                MOTD_SHOW_UPDATES=false; shift ;;
            --no-motd-logins)
                MOTD_SHOW_RECENT_LOGINS=false; shift ;;
            --motd-security-priv-only)
                MOTD_SECURITY_PRIV_ONLY=true; shift ;;
            --motd-script-path)
                _require_value "$1" "${2:-}"
                MOTD_SCRIPT_PATH="$2"; shift 2 ;;
            --motd-config-path)
                _require_value "$1" "${2:-}"
                MOTD_CONFIG_PATH="$2"; shift 2 ;;
            --motd-cache-dir)
                _require_value "$1" "${2:-}"
                MOTD_CACHE_DIR="$2"; shift 2 ;;
            --sshd-dropin)
                _require_value "$1" "${2:-}"
                SSHD_BANNER_DROPIN="$2"; shift 2 ;;

            # -- Scope --
            --banner-only)
                # Keep SSHD_BANNER_MANAGE=true so SSH actually displays
                # the banner. Without the explicit set, --banner-only
                # would leave /etc/issue.net on disk but sshd would
                # never point at it — and an operator who exports
                # SSHD_BANNER_MANAGE=false from a previous automated
                # --motd-only run would see the env var win. The
                # --no-sshd-banner flag still exists for the rare
                # "stage banner file only" use case.
                MOTD_ENABLED=false
                BANNER_ENABLED=true
                SSHD_BANNER_MANAGE=true
                shift ;;
            --motd-only)
                BANNER_ENABLED=false
                SSHD_BANNER_MANAGE=false
                MOTD_ENABLED=true
                shift ;;
            --no-banner)
                BANNER_ENABLED=false; shift ;;
            --no-motd)
                MOTD_ENABLED=false; shift ;;
            --no-sshd-banner)
                SSHD_BANNER_MANAGE=false; shift ;;

            # -- Common --
            --config)
                _require_value "$1" "${2:-}"
                CONFIG_FILE="$2"; shift 2 ;;
            -n|--dry-run)
                DRY_RUN=true; shift ;;
            -f|--force)
                FORCE=true; shift ;;
            --uninstall)
                UNINSTALL=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            --version)
                printf '%s %s\n' "$PROG_NAME" "$MOTD_VERSION"; exit 0 ;;
            --)
                shift; break ;;
            -*)
                log_error "unknown option: $1"
                log_hint "run '$0 --help' for usage"
                exit 1 ;;
            *)
                log_error "unexpected positional argument: $1"
                exit 1 ;;
        esac
    done
}

# =============================================================================
# Config file loading
#
# The config file is a shell-style KEY=VALUE text file. It is parsed as
# plain text — NEVER sourced. A previous revision called `source "$path"`
# inside a subshell under the misconception that the subshell isolates
# side effects. A subshell isolates *variables*; every `$(cmd)`, backtick,
# and top-level shell statement still executes with the privileges of the
# parent. For a file living at /etc/motd.conf, read on every install run
# as root, that was a latent local-code-execution vector (a caller who
# passed a tainted --company-name='$(…)' would round-trip through
# build_unified_config into motd.conf and fire on the next install).
#
# Three accepted value shapes per line:
#
#   KEY="double-quoted"    # no unescaped " $ ` \ allowed inside
#   KEY='single-quoted'    # no ' allowed inside
#   KEY=bare_token         # no whitespace or shell metacharacters
#
# Blank lines and `# …` comments are ignored. Anything else is logged
# and skipped — no fallback to a shell source, ever.
# =============================================================================
load_config() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 0
    fi
    if [[ ! -r "$path" ]]; then
        log_error "config file not readable: $path"
        exit 3
    fi
    log_info "loading config from $path"

    local line key rest value env_marker lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        # Strip trailing \r (Windows line endings) and surrounding whitespace.
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        if [[ "$line" != *=* ]]; then
            log_warn "config $path:$lineno: malformed line (no '='), skipping"
            continue
        fi
        key="${line%%=*}"
        rest="${line#*=}"

        # Key must be a shell-safe identifier.
        if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            log_warn "config $path:$lineno: invalid key '$key', skipping"
            continue
        fi

        # Whitelist — anything outside our known keys is silently ignored
        # (preserves forward-compat for future keys without aborting).
        #
        # Scope toggles (BANNER_ENABLED / MOTD_ENABLED /
        # SSHD_BANNER_MANAGE) are deliberately ABSENT from this list.
        # Persisting them in /etc/motd.conf would mean a one-off
        # `--motd-only` test silently disables the banner for every
        # subsequent install — the operator would never see the
        # defaults resurface. Scope flags are CLI-only (with env var
        # fallback for scripted invocations), never written to disk.
        # Any pre-existing line in /etc/motd.conf falls through to
        # the default `continue` branch below and is silently
        # ignored.
        case "$key" in
            COMPANY_NAME|CONTACT|LANGUAGE|STYLE|MIN_WIDTH|STATUTE|\
            STATUTE_ASCII|WARNING_LINES_OVERRIDE|\
            ISSUE_FILE|ISSUE_NET_FILE|CLEAR_MOTD|\
            BACKUP|BACKUP_DIR|SSHD_RELOAD|\
            MOTD_SUBTITLE|MOTD_MIN_WIDTH|MOTD_VERBOSE|\
            MOTD_FOOTER|MOTD_SHOW_SERVICES|MOTD_SHOW_UPDATES|\
            MOTD_SHOW_RECENT_LOGINS|MOTD_SECURITY_PRIV_ONLY|\
            MOTD_PUBIP_URL|MOTD_SCRIPT_PATH|\
            MOTD_CONFIG_PATH|MOTD_CACHE_DIR|\
            SSHD_BANNER_DROPIN)
                ;;
            *)
                continue ;;
        esac

        # env > config: if the caller already set this key via the
        # environment, config cannot override. parse_args runs *after*
        # load_config and will happily overwrite, so the effective
        # precedence is CLI > env > config > defaults.
        env_marker="env_set_${key}"
        if [[ -n "${!env_marker:-}" ]]; then
            continue
        fi

        # Value parsing — three mutually exclusive shapes, selected by
        # the first byte of the RHS. A trailing `# comment` is allowed
        # on every shape.
        #
        # Malformed values are a HARD ERROR (exit 3), not a silent
        # skip. A silent-skip path would turn an operator typo like
        # `COMPANY_NAME="$HOME/logo"` into a silent fallback to the
        # default "Managed Server" because the `$` fails the
        # double-quoted regex — the install would proceed with the
        # wrong company name. Rejecting loudly forces the operator to
        # notice and either single-quote the value (the parser never
        # expands variables) or drop the shell metacharacter.
        if [[ "${rest:0:1}" == '"' ]]; then
            if ! [[ "$rest" =~ ^\"([^\"\$\`\\]*)\"[[:space:]]*(#.*)?$ ]]; then
                log_error "config $path:$lineno: malformed double-quoted value for $key"
                log_hint  "the parser rejects \\ \` \$ and un-escaped \" inside double quotes"
                log_hint  "use single quotes for literal values: $key='...'"
                exit 3
            fi
            value="${BASH_REMATCH[1]}"
        elif [[ "${rest:0:1}" == "'" ]]; then
            if ! [[ "$rest" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
                log_error "config $path:$lineno: malformed single-quoted value for $key"
                log_hint  "single-quoted values must not contain an embedded '"
                exit 3
            fi
            value="${BASH_REMATCH[1]}"
        else
            if ! [[ "$rest" =~ ^([^[:space:]\$\`\\\"\']*)[[:space:]]*(#.*)?$ ]]; then
                log_error "config $path:$lineno: malformed unquoted value for $key"
                log_hint  "unquoted values may not contain whitespace or shell metacharacters"
                log_hint  "wrap the value in single quotes: $key='...'"
                exit 3
            fi
            value="${BASH_REMATCH[1]}"
        fi

        # Defensive belt-and-braces: reject control characters in the
        # parsed value. _sanitise_text would strip them, but their
        # presence in a config file signals tampering and deserves a
        # hard failure rather than a silent clean — same reason as
        # the malformed-value branches above.
        if ! _is_printable_safe "$value"; then
            log_error "config $path:$lineno: $key contains control characters or ANSI escapes"
            exit 3
        fi

        printf -v "$key" '%s' "$value"
    done < "$path"
}

# =============================================================================
# Validation
# =============================================================================
_sanitise_text() {
    # Strip C0 control bytes (0x00–0x1F) and DEL (0x7F). Keep printable
    # ASCII + multi-byte UTF-8 (§ = 0xC2 0xA7, ä = 0xC3 0xA4, …).
    #
    # We do NOT strip C1 bytes (0x80–0x9F) here because they appear
    # legitimately as continuation bytes inside multi-byte UTF-8 sequences,
    # and `tr -d '\200-\237'` would mangle a real character (e.g. ä = 0xC3
    # 0xA4 — the 0xA4 trailing byte falls in the C1 range when read as a
    # single byte). Standalone C1 bytes (a 0x80–0x9F byte that is NOT part
    # of a valid UTF-8 sequence — including the 8-bit CSI starter 0x9B,
    # which xterm interprets as `ESC [` when allowC1Printable is set) are
    # caught by _is_printable_safe via a UTF-8 round-trip below.
    local in="$1"
    LC_ALL=C printf '%s' "$in" | LC_ALL=C tr -d '\000-\037\177'
}

_is_printable_safe() {
    # Accept printable characters only — reject:
    #   * C0 control bytes (0x00–0x1F) and DEL (0x7F)
    #   * Invalid UTF-8 sequences, including standalone C1 control bytes
    #     (0x80–0x9F) that are NOT part of a valid multi-byte sequence
    #
    # The C1 check is necessary because bytes in 0x80–0x9F have two
    # legitimate meanings on a *nix host:
    #   1. UTF-8 continuation bytes inside a multi-byte sequence (legit)
    #   2. 8-bit C1 control codes left over from ISO-8859-* (NOT legit
    #      on a UTF-8 system, AND interpreted by xterm as escape codes
    #      when `allowC1Printable: true` is set — 0x9B is the single-byte
    #      CSI starter, equivalent to `ESC [`)
    #
    # Strategy: round-trip the input through `iconv -c -f UTF-8 -t UTF-8`.
    # The `-c` flag tells iconv to silently DROP invalid byte sequences
    # instead of aborting, so a standalone 0x9B disappears from the
    # output while a legitimate ä (0xC3 0xA4) round-trips byte-identical.
    # Comparing input vs roundtrip catches any drop. iconv ships with
    # both glibc and musl, and busybox v1.30+ includes an iconv applet,
    # so this works on every distro this installer targets.
    local s="$1"
    [[ -z "$s" ]] && return 0
    # Cheap pure-bash C0/DEL filter — runs even when iconv is
    # unavailable.
    local stripped
    stripped="$(LC_ALL=C printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177')"
    [[ "$stripped" == "$s" ]] || return 1
    # iconv round-trip — primary defence against standalone C1 bytes and
    # any other malformed UTF-8 sequence.
    if command -v iconv >/dev/null 2>&1; then
        local roundtrip
        roundtrip="$(LC_ALL=C.UTF-8 printf '%s' "$s" | LC_ALL=C.UTF-8 iconv -c -f UTF-8 -t UTF-8 2>/dev/null)" || return 1
        [[ "$roundtrip" == "$s" ]] || return 1
    else
        # iconv missing (exotic minimal container) — degrade to a strict
        # ASCII-only check. UTF-8 is not safely parseable in pure bash
        # without significant work, and the alternative (silently
        # allowing 0x80–0xFF) would let standalone C1 bytes through.
        # ASCII-only is a functional regression for German/French
        # operators on such hosts, but the failure mode is "install
        # refuses with a clear error", not "banner emits an
        # attacker-controlled escape sequence". The operator can
        # install gnu-libiconv / busybox-iconv to restore full UTF-8
        # support.
        local ascii_only
        ascii_only="$(LC_ALL=C printf '%s' "$s" | LC_ALL=C tr -d '\200-\377')"
        if [[ "$ascii_only" != "$s" ]]; then
            log_hint "iconv binary not found — UTF-8 validation unavailable on this host"
            log_hint "install gnu-libiconv or busybox-iconv, or use ASCII-only field values"
            return 1
        fi
    fi
    return 0
}

# Reject codepoints whose terminal display width differs from their
# bash `${#var}` codepoint count. `_strlen_display` returns the
# codepoint count, which is correct for every character in the Basic
# Multilingual Plane that is not explicitly wide and wrong for every
# emoji — they render as 2 columns while counting as 1 codepoint.
# Without this guard a COMPANY_NAME like "Acme 🚀" produces a banner
# box whose right border is one column too far left.
#
# Pragmatic rule: reject any 4-byte UTF-8 sequence (leading byte
# 0xF0–0xF4). This covers:
#   * every emoji in the Supplementary Multilingual Plane (U+1Fxxx)
#   * every Miscellaneous Symbol / Dingbat in the same plane
#   * CJK Unified Ideographs Extension B-F
#   * Historic scripts (Linear A/B, cuneiform, …)
#
# What stays allowed:
#   * ASCII (1-byte)
#   * Latin-1 Supplement, Latin Extended, Greek, Cyrillic, Hebrew,
#     Arabic, IPA — everything in the 2-byte range (§, ä, ö, ü, é, …)
#   * General Punctuation (em-dash —, en-dash, curly quotes),
#     Mathematical Operators, Box Drawing, Arrows — 3-byte range
#   * CJK Unified Ideographs U+4E00–U+9FFF — 3-byte range
#
# CJK Unified is a documented edge case: those codepoints ARE
# display-wide and would misalign the box. We accept the risk because
# the alternative (banning every 3-byte sequence) would reject the
# em-dash in company names like "Müller — Bühne". Operators who need a
# CJK company name should contribute a wcwidth-based _strlen_display
# implementation instead.
_reject_wide_chars() {
    local var="$1" v
    v="${!var}"
    # tr keeps bytes ≤ 0xEF; anything in 0xF0–0xFF is a 4-byte UTF-8
    # leading byte or an invalid byte. `_is_printable_safe` already
    # rejected invalid + control bytes, so whatever survives here is
    # genuine 4-byte UTF-8.
    local has
    has="$(LC_ALL=C printf '%s' "$v" | LC_ALL=C tr -d '\000-\357')"
    if [[ -n "$has" ]]; then
        log_error "$var must not contain emoji or other supplementary-plane characters"
        log_hint "allowed: ASCII, Latin-1 Supplement, punctuation, box drawing"
        log_hint "rejected: 🚀 (emoji), CJK Extension B-F, historic scripts"
        log_hint "reason: box rendering uses codepoint count for padding; these chars render double-width"
        exit 3
    fi
}

# Reject shell-active metacharacters in a text value. build_unified_config
# writes every text field into /etc/motd.conf inside a double-quoted literal.
# Characters that would break out of that literal ($ ` " \) must never reach
# the output file — the runtime loader's regex parser refuses to parse any
# such value anyway (defense in depth), but surfacing the error at install
# time gives the operator a clear diagnostic instead of a silent no-op at
# next SSH login.
_reject_shell_meta() {
    local var="$1" v
    v="${!var}"
    case "$v" in
        *\$*|*\`*|*\"*|*\\*)
            log_error "$var must not contain shell metacharacters (\$ \` \" \\)"
            log_hint "these are rejected to keep /etc/motd.conf unambiguously parseable"
            exit 3 ;;
    esac
}

# Reusable text-field validator: $1 = var name, $2 = max length, $3 =
# allow-empty (true|false). On success, the variable is reassigned to
# its sanitised form. On failure, exits with the appropriate code.
_validate_text_field() {
    local var="$1" max_len="$2" allow_empty="${3:-false}" v s
    v="${!var}"
    if [[ -z "$v" ]]; then
        if [[ "$allow_empty" == "true" ]]; then
            return 0
        fi
        log_error "$var must not be empty"
        exit 3
    fi
    s="$(_sanitise_text "$v")"
    if [[ "$s" != "$v" ]]; then
        log_error "$var contains control characters or ANSI escapes"
        exit 3
    fi
    if (( ${#s} > max_len )); then
        log_error "$var too long (${#s} > $max_len chars)"
        exit 3
    fi
    if ! _is_printable_safe "$s"; then
        log_error "$var contains non-printable characters"
        exit 3
    fi
    printf -v "$var" '%s' "$s"
    _reject_shell_meta "$var"
    _reject_wide_chars "$var"
}

_validate_bool() {
    local var="$1" v
    v="${!var}"
    case "$v" in
        true|false) ;;
        1)  printf -v "$var" 'true'  ;;
        0)  printf -v "$var" 'false' ;;
        yes|YES|Yes) printf -v "$var" 'true'  ;;
        no|NO|No)    printf -v "$var" 'false' ;;
        *)
            log_error "$var must be true/false, got: $v"
            exit 3 ;;
    esac
}

_validate_abs_path() {
    local var="$1" v
    v="${!var}"
    if [[ -z "$v" ]]; then
        log_error "$var must not be empty"
        exit 3
    fi
    if [[ "$v" != /* ]]; then
        log_error "$var must be an absolute path, got: $v"
        exit 3
    fi
    # Reject newlines, CR, and other C0 control bytes BEFORE the path hits
    # /etc/motd.conf or — worse — sshd_config.d. The sshd drop-in is parsed
    # line-by-line, so a stray \n turns "Banner /etc/issue.net" into two
    # directives and injects whatever followed the newline as a second,
    # syntactically-valid sshd directive. That bypass made a path like
    # $'/etc/issue.net\nPermitRootLogin yes' pass validation pre-fix.
    if ! _is_printable_safe "$v"; then
        log_error "$var contains control characters (newline/CR/etc.) — rejected"
        exit 3
    fi
    # Whitespace is not a control char but is still unsafe: a path with a
    # space survives Bash quoting in atomic_write but breaks sshd_config,
    # which treats whitespace as a token separator. Reject up front so the
    # failure mode is "install refuses", not "sshd silently ignores line".
    if [[ "$v" == *[[:space:]]* ]]; then
        log_error "$var must not contain whitespace, got: $v"
        exit 3
    fi
    # Paths also land in /etc/motd.conf as double-quoted literals.
    _reject_shell_meta "$var"
    # The MOTD source-rendering step substitutes MOTD_CONFIG_PATH into
    # the runtime script via `sed "s|A|$path|"`, using pipe as the sed
    # delimiter. A path containing a literal `|` would close the
    # substitution prematurely and either crash sed or — worse —
    # silently re-interpret part of the path as a sed flag.
    # _reject_shell_meta does NOT cover pipe (pipe is a legitimate
    # shell metacharacter for TEXT fields like CONTACT where "Tel |
    # Mail" is a reasonable layout, so we can't reject it globally),
    # so we reject it here, scoped to absolute paths. Pipe has no
    # legitimate place in a filesystem path anyway — POSIX permits it
    # on ext4/xfs but no real workflow uses it.
    #
    # Same rationale for `&`: sed treats `&` in the *replacement
    # string* as a backreference to the entire matched text. A path
    # like `/var/cache/motd/bad&path` rendered via
    # `sed "s|^...|_motd_load_config ${MOTD_CONFIG_PATH}|"` silently
    # expands `&` to the matched LHS, producing a garbled runtime
    # script that still passes `bash -n`. `&` has no legitimate use
    # in a managed path, so reject symmetrically with `|`.
    case "${!var}" in
        *\|*)
            log_error "$var must not contain a pipe character ('|')"
            log_hint "pipe breaks the sed delimiter used during MOTD source rendering"
            exit 3 ;;
        *\&*)
            log_error "$var must not contain an ampersand ('&')"
            log_hint "'&' is a sed replacement-string backreference and would corrupt MOTD_CONFIG_PATH rendering"
            exit 3 ;;
    esac
}

# -----------------------------------------------------------------------------
# _validate_managed_prefix — prefix allowlist mirroring uninstall.sh.
#
# Without this check, a typo in --motd-config-path / --motd-script-path /
# --backup-dir / --sshd-dropin / --motd-cache-dir / --issue-file /
# --issue-net-file would silently let the installer clobber arbitrary
# system files. Concrete failure mode: passing `--motd-config-path
# /etc/passwd` would overwrite /etc/passwd with the unified KEY=VALUE
# config and break sudo/su across the host.
#
# The allowlist is intentionally short and symmetric with uninstall.sh
# (_validate_managed_prefix there): both scripts must agree on WHICH
# paths they may touch. Operators who need an additional location should
# add it HERE and mirror the entry in uninstall.sh — never loosen to a
# permissive pattern.
# -----------------------------------------------------------------------------
_validate_managed_prefix() {
    local var="$1" v
    v="${!var}"
    # Reject path-traversal segments and relative prefixes BEFORE the
    # allowlist check. The allowlist uses glob patterns like
    # /var/cache/motd* which happily match
    # /var/cache/motd/../../etc/shadow, so a lexical reject is the only
    # reliable defence. We deliberately do NOT call realpath
    # --no-symlinks here: (1) GNU coreutils dependency (missing on
    # Alpine/busybox), (2) would need a two-pass raw/canonical
    # comparison for a usable error message. A pure lexical reject
    # closes the hole without either downside. Operators do not
    # legitimately use `..` or `./` in managed paths.
    case "$v" in
        */..|*/../*|*/./*|*/.|../*|./*)
            log_error "$var=$v contains a path-traversal segment (../ or ./)"
            log_hint "managed paths must be absolute and fully normalised"
            exit 3 ;;
    esac
    # A naive trailing wildcard like `/var/cache/motd*` would silently
    # match sibling basenames like `/var/cache/motdbackdoor` or
    # `/var/cache/motd_evil`. The explicit `<dir>|<dir>/*` pair anchors
    # the wildcard at a path separator: only the literal managed
    # directory itself, or paths *under* it, pass. Mirrored verbatim in
    # uninstall.sh's _validate_managed_prefix.
    case "$v" in
        /etc/ssh/sshd_config.d/*|\
        /etc/update-motd.d/*|\
        /etc/motd|/etc/motd.conf|\
        /etc/issue|/etc/issue.net|\
        /var/cache/motd|/var/cache/motd/*|\
        /var/backups/motd|/var/backups/motd/*|\
        /srv/backups/motd|/srv/backups/motd/*)
            return 0 ;;
        *)
            log_error "$var=$v is outside the managed directory allowlist"
            log_hint "allowed prefixes: /etc/ssh/sshd_config.d/, /etc/update-motd.d/,"
            log_hint "  /etc/motd, /etc/motd.conf, /etc/issue, /etc/issue.net,"
            log_hint "  /var/cache/motd[/*], /var/backups/motd[/*], /srv/backups/motd[/*]"
            exit 3 ;;
    esac
}

validate_config() {
    # -- Banner fields --
    _validate_text_field COMPANY_NAME "$MAX_COMPANY_LEN" false
    _validate_text_field CONTACT      "$MAX_CONTACT_LEN" true

    case "$LANGUAGE" in
        en|de) ;;
        *)
            log_error "LANGUAGE must be 'en' or 'de', got: $LANGUAGE"
            exit 3 ;;
    esac

    case "$STYLE" in
        double|single|ascii) ;;
        *)
            log_error "STYLE must be 'double', 'single', or 'ascii', got: $STYLE"
            exit 3 ;;
    esac

    if ! [[ "$MIN_WIDTH" =~ ^[0-9]+$ ]]; then
        log_error "MIN_WIDTH must be a positive integer, got: $MIN_WIDTH"
        exit 3
    fi
    if (( MIN_WIDTH < 20 )); then
        log_error "MIN_WIDTH must be at least 20"
        exit 3
    fi
    if (( MIN_WIDTH > MAX_WIDTH )); then
        log_error "MIN_WIDTH must not exceed $MAX_WIDTH"
        exit 3
    fi

    # STATUTE / STATUTE_ASCII — allow empty.
    _validate_text_field STATUTE       128 true
    _validate_text_field STATUTE_ASCII 128 true

    # WARNING_LINES_OVERRIDE (array) — validate each line individually.
    # See _split_warning_lines_override for the split timing; by the
    # time we get here, either CLI populated the array directly or the
    # split function translated the persisted scalar into elements.
    _validate_warning_lines

    _validate_abs_path ISSUE_FILE
    _validate_abs_path ISSUE_NET_FILE
    _validate_abs_path BACKUP_DIR
    _validate_managed_prefix ISSUE_FILE
    _validate_managed_prefix ISSUE_NET_FILE
    _validate_managed_prefix BACKUP_DIR

    _validate_bool CLEAR_MOTD
    _validate_bool BACKUP
    _validate_bool SSHD_RELOAD
    _validate_bool BANNER_ENABLED

    # -- MOTD fields --
    _validate_bool MOTD_ENABLED
    _validate_bool MOTD_VERBOSE
    _validate_bool MOTD_SHOW_SERVICES
    _validate_bool MOTD_SHOW_UPDATES
    _validate_bool MOTD_SHOW_RECENT_LOGINS
    _validate_bool MOTD_SECURITY_PRIV_ONLY

    _validate_text_field MOTD_SUBTITLE "$MAX_SUBTITLE_LEN" true
    _validate_text_field MOTD_FOOTER   "$MAX_FOOTER_LEN"   true

    if ! [[ "$MOTD_MIN_WIDTH" =~ ^[0-9]+$ ]]; then
        log_error "MOTD_MIN_WIDTH must be a positive integer, got: $MOTD_MIN_WIDTH"
        exit 3
    fi
    if (( MOTD_MIN_WIDTH < 20 )); then
        log_error "MOTD_MIN_WIDTH must be at least 20"
        exit 3
    fi
    if (( MOTD_MIN_WIDTH > MAX_WIDTH )); then
        log_error "MOTD_MIN_WIDTH must not exceed $MAX_WIDTH"
        exit 3
    fi

    # MOTD_PUBIP_URL — must be http(s), no shell metacharacters.
    # Query strings are allowed (e.g. https://api.example.com/ip?format=raw)
    # because `?`, `=`, `&`, and `%` are safe in a double-quoted curl
    # argument. The endpoint is `curl --max-time 2`'d at MOTD render
    # time and the response goes through `sanitize_ip` (whitelist of
    # [0-9a-fA-F:.]), so the only sanity check this regex needs to
    # enforce is "no shell metacharacters that would break out of the
    # curl arg".
    if [[ -n "$MOTD_PUBIP_URL" ]]; then
        if ! [[ "$MOTD_PUBIP_URL" =~ ^https?://[A-Za-z0-9./_:?=\&%-]+$ ]]; then
            log_error "MOTD_PUBIP_URL must be a plain http(s) URL, got: $MOTD_PUBIP_URL"
            log_hint  "allowed characters: A-Z a-z 0-9 . / _ : ? = & % -"
            exit 3
        fi
    fi

    _validate_abs_path MOTD_SCRIPT_PATH
    _validate_abs_path MOTD_CONFIG_PATH
    _validate_abs_path MOTD_CACHE_DIR
    _validate_managed_prefix MOTD_SCRIPT_PATH
    _validate_managed_prefix MOTD_CONFIG_PATH
    _validate_managed_prefix MOTD_CACHE_DIR

    # -- sshd integration fields --
    _validate_bool SSHD_BANNER_MANAGE
    _validate_abs_path SSHD_BANNER_DROPIN
    _validate_managed_prefix SSHD_BANNER_DROPIN

    # At least one phase must run — silently doing nothing is unhelpful.
    if [[ "$BANNER_ENABLED" != "true" ]] \
       && [[ "$MOTD_ENABLED" != "true" ]] \
       && [[ "$SSHD_BANNER_MANAGE" != "true" ]]; then
        log_error "all phases disabled — nothing to do"
        log_hint "drop one of --no-banner / --no-motd / --no-sshd-banner"
        exit 1
    fi
}

# =============================================================================
# Distro detection (advisory only — we never abort on unknown)
#
# We deliberately do NOT source /etc/os-release. Every line in that file
# is a shell-style `KEY="value"` assignment, and sourcing it would run
# them in whichever shell we happen to be in. Two problems with that:
#
#   1. /etc/os-release defines `VERSION="24.04.3 LTS (Noble Numbat)"` on
#      Ubuntu (and similar on every other modern distro). Any readonly
#      `VERSION` in the parent shell would make the assignment in the
#      subshell fail with "VERSION: readonly variable", and under
#      `set -e` the failing subshell would kill the entire installer
#      silently. We ran into this exact failure mode in the v1 test run,
#      which is why our own version constant is named MOTD_VERSION.
#
#   2. Any future variable added to /etc/os-release could collide with
#      any shell variable we happen to use. Sourcing is a landmine.
#
# Instead: parse the two keys we care about with a deterministic awk
# pattern. The format is stable across every distro that ships an
# /etc/os-release (systemd mandates it). No subshell, no `set -e`
# surprise, and any parse failure surfaces in the log.
# =============================================================================
_read_os_release_field() {
    # $1 = field name (e.g. ID, ID_LIKE). Echoes the value with
    # surrounding quotes stripped. Returns 0 if found, 1 otherwise.
    local field="$1"
    [[ -r /etc/os-release ]] || return 1
    awk -F= -v f="$field" '
        $1 == f {
            v = $2
            gsub(/^["'\'']/, "", v)
            gsub(/["'\'']$/, "", v)
            print v
            found = 1
            exit
        }
        END { exit !found }
    ' /etc/os-release
}

detect_distro() {
    local id="" id_like="" all
    if [[ -r /etc/os-release ]]; then
        id="$(_read_os_release_field ID || true)"
        id_like="$(_read_os_release_field ID_LIKE || true)"
    else
        log_warn "/etc/os-release not present; continuing — /etc/issue* is universal"
        return 0
    fi
    all="$id $id_like"
    case "$all" in
        *debian*|*ubuntu*|*rhel*|*centos*|*rocky*|*almalinux*|*fedora*)
            log_info "detected distro: ${id:-unknown}"
            ;;
        *)
            log_warn "unrecognised distro (ID=${id:-?}, ID_LIKE=${id_like:-?}); continuing — /etc/issue* is universal"
            ;;
    esac
}

# =============================================================================
# Banner: text rendering
# =============================================================================
render_warning_lines_en() {
    # Populates global array _LINES_UNICODE and _LINES_ASCII
    _LINES_UNICODE=(
        "WARNING: Authorized access only."
        "This system is property of ${COMPANY_NAME}."
        "Unauthorized access is strictly prohibited."
        "All connections are monitored and logged."
    )
    _LINES_ASCII=("${_LINES_UNICODE[@]}")
}

render_warning_lines_de() {
    _LINES_UNICODE=(
        "WARNUNG: Nur autorisierter Zugriff."
        "Dieses System ist Eigentum von ${COMPANY_NAME}."
        "Unbefugter Zugriff ist strikt untersagt."
        "Alle Verbindungen werden überwacht und protokolliert."
    )
    # ASCII variant for /etc/issue — strip non-ASCII (ü, §, etc.).
    _LINES_ASCII=(
        "WARNUNG: Nur autorisierter Zugriff."
        "Dieses System ist Eigentum von ${COMPANY_NAME}."
        "Unbefugter Zugriff ist strikt untersagt."
        "Alle Verbindungen werden ueberwacht und protokolliert."
    )
}

# -----------------------------------------------------------------------------
# Warning-lines override helpers
# -----------------------------------------------------------------------------
# Motivation: salt/banner.sls exposes a `warning_lines_override` pillar key
# that replaces the language preset with a verbatim list. The standalone
# installer matched only the EN/DE presets, forcing operators with custom
# legal text to either patch install.sh or overwrite /etc/issue.net after
# the fact. Parity drift = gone: --warning-lines is a repeatable CLI flag
# (true list, 1:1 to the Salt pillar), and the config-file persistence
# form is a single-quoted scalar with literal \n separators.
#
# Why single-quoted in the config file: the double-quoted parser branch
# in load_config rejects backslash (see the regex at :534), which is
# exactly the character we need for the \n separator. Single-quoted
# literals pass backslash through untouched — at the cost of not being
# able to carry a single quote inside a warning line, which we enforce
# at validation time.
# -----------------------------------------------------------------------------

# Split the persistence scalar into the array, but only when the array
# is still empty. Running AFTER parse_args preserves the precedence
# "CLI appends > env-or-config scalar": any --warning-lines flag leaves
# the array non-empty and this function becomes a no-op.
_split_warning_lines_override() {
    if (( ${#WARNING_LINES_OVERRIDE_ARR[@]} > 0 )); then
        return 0
    fi
    if [[ -z "$WARNING_LINES_OVERRIDE" ]]; then
        return 0
    fi
    # Replace literal \n (backslash + n, two bytes) with a real newline,
    # then read into the array. We deliberately do NOT use `mapfile -t`
    # here: macOS ships bash 3.2 as /bin/bash and mapfile is a bash 4+
    # builtin, which breaks the installer on any darwin host the user
    # runs it from (the runtime target is always Linux with bash ≥ 5,
    # but the CLI must stay portable for developer dry-runs). The
    # while-read loop below is a drop-in replacement that works on
    # bash ≥ 3.2: IFS= preserves leading/trailing whitespace, -r stops
    # backslash-in-content from being interpreted, and the `|| [[ -n
    # "$_line" ]]` tail catches a final line with no trailing newline.
    # shellcheck disable=SC2178  # _expanded is a scalar, not an array —
    # the // pattern replacement ShellCheck mistook for array semantics.
    local _expanded="${WARNING_LINES_OVERRIDE//\\n/$'\n'}"
    WARNING_LINES_OVERRIDE_ARR=()
    local _line
    # shellcheck disable=SC2128  # _expanded is scalar; the herestring below
    # feeds the while body, not an array expansion. Directive MUST sit in
    # front of the compound command, not mid-body (SC1123 halts analysis of
    # every line that follows otherwise).
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        WARNING_LINES_OVERRIDE_ARR+=( "$_line" )
    done <<< "$_expanded"
}

# Join the array back into the persistence scalar — called from
# build_unified_config right before the heredoc emits
# WARNING_LINES_OVERRIDE='...'. Separator is literal \n (backslash + n).
_join_warning_lines_override() {
    # Guard the array expansion: under `set -u`, "${arr[@]}" on an
    # empty array is treated as an unbound variable. The empty-array
    # short-circuit below is both a micro-optimisation and the fix.
    if (( ${#WARNING_LINES_OVERRIDE_ARR[@]} == 0 )); then
        WARNING_LINES_OVERRIDE=""
        return 0
    fi
    local _out="" _first=true _l
    for _l in "${WARNING_LINES_OVERRIDE_ARR[@]}"; do
        if $_first; then
            _out="$_l"
            _first=false
        else
            # The \\n below expands to a literal backslash + n in the
            # resulting string — exactly the separator load_config sees
            # on the next install run.
            _out="${_out}\\n${_l}"
        fi
    done
    WARNING_LINES_OVERRIDE="$_out"
}

# Validate each element of WARNING_LINES_OVERRIDE_ARR in turn. Reuses
# _validate_text_field via a scratch scalar binding so the existing
# control-char / shell-meta / length / wide-char checks apply per line.
# Adds one extra reject: single quote. Motivation — the persistence
# form is a single-quoted literal in /etc/motd.conf, so a content-side
# single quote would break the shell quoting with no clean escape.
_validate_warning_lines() {
    local _i _WARNING_LINE
    for _i in "${!WARNING_LINES_OVERRIDE_ARR[@]}"; do
        _WARNING_LINE="${WARNING_LINES_OVERRIDE_ARR[$_i]}"
        # Bind to a scratch name so error messages say _WARNING_LINE;
        # we then reassign the array element to the sanitised form.
        _validate_text_field _WARNING_LINE "$MAX_WARNING_LINE_LEN" false
        case "$_WARNING_LINE" in
            *\'*)
                log_error "warning line $((_i + 1)) must not contain a single quote"
                log_hint "/etc/motd.conf persists warning lines as single-quoted literals"
                log_hint "so the \\\\n separator survives the config parser"
                exit 3 ;;
        esac
        # shellcheck disable=SC2004  # $_i inside array index is kept
        # for readability — ShellCheck's auto-strip hint would obscure
        # that _i is the loop index, not a constant.
        WARNING_LINES_OVERRIDE_ARR[$_i]="$_WARNING_LINE"
    done
    unset _WARNING_LINE
}

render_warning_lines() {
    if (( ${#WARNING_LINES_OVERRIDE_ARR[@]} > 0 )); then
        # Override mode — replace the language preset verbatim.
        # Mirrors salt/banner.sls:178-184: both unicode and ASCII
        # variants receive the same override lines. Operators who need
        # distinct ASCII fall-backs must pre-fold their text to ASCII-
        # safe characters before passing it in.
        _LINES_UNICODE=( "${WARNING_LINES_OVERRIDE_ARR[@]}" )
        _LINES_ASCII=(   "${WARNING_LINES_OVERRIDE_ARR[@]}" )
    else
        case "$LANGUAGE" in
            en) render_warning_lines_en ;;
            de) render_warning_lines_de ;;
        esac
    fi

    # Optional contact line. Label is localised — "Kontakt" on a German
    # banner, "Contact" everywhere else. ASCII variant mirrors the
    # Unicode label because the label itself is 7-bit safe in both
    # languages (no umlaut / diacritic).
    if [[ -n "$CONTACT" ]]; then
        local _contact_label
        case "$LANGUAGE" in
            de) _contact_label="Kontakt" ;;
            *)  _contact_label="Contact" ;;
        esac
        _LINES_UNICODE+=("${_contact_label}: ${CONTACT}")
        _LINES_ASCII+=("${_contact_label}: ${CONTACT}")
    fi

    # Statute line — always last. The Unicode prefix is language-localised
    # to mirror salt/banner.sls (so a Salt-managed host and a hand-installed
    # VM render byte-identical output). The ASCII prefix always stays
    # English because /etc/issue is rendered on a boot console that may not
    # have a UTF-8 font loaded — "Verstöße" would look worse than English.
    local _prose_prefix_u
    case "$LANGUAGE" in
        de) _prose_prefix_u="Verstöße werden verfolgt nach " ;;
        *)  _prose_prefix_u="Violations prosecuted under " ;;
    esac
    if [[ -n "$STATUTE" ]]; then
        _LINES_UNICODE+=("${_prose_prefix_u}${STATUTE}.")
    fi
    if [[ -n "$STATUTE_ASCII" ]]; then
        _LINES_ASCII+=("Violations prosecuted under ${STATUTE_ASCII}.")
    fi
}

# -----------------------------------------------------------------------------
# _strlen_display: how wide is this string on a fixed-width terminal?
#
# Under a UTF-8 locale, bash's `${#var}` counts *codepoints*, not bytes —
# which is exactly what fixed-width terminal width means for our content
# (no CJK, no combining marks, no emoji). Under C locale it counts bytes,
# which is still correct because the content is then pure ASCII.
# -----------------------------------------------------------------------------
_strlen_display() {
    local s="$1"
    printf '%s' "${#s}"
}

# -----------------------------------------------------------------------------
# _compute_box_width: max(MIN_WIDTH, longest_display_line + 4), capped at
# MAX_WIDTH. If the cap clips any line, truncate it with "..." and warn.
# Operates on _LINES_UNICODE and _LINES_ASCII (both by display width).
# -----------------------------------------------------------------------------
_compute_box_width() {
    local longest=0 len i line
    local all=("${_LINES_UNICODE[@]}" "${_LINES_ASCII[@]}")
    for line in "${all[@]}"; do
        len="$(_strlen_display "$line")"
        (( len > longest )) && longest=$len
    done

    local want=$(( longest + 4 ))
    if (( want < MIN_WIDTH )); then
        BOX_WIDTH=$MIN_WIDTH
    else
        BOX_WIDTH=$want
    fi

    if (( BOX_WIDTH > MAX_WIDTH )); then
        log_warn "content exceeds cap (${BOX_WIDTH} > ${MAX_WIDTH}); truncating long lines"
        BOX_WIDTH=$MAX_WIDTH
        local max_line=$(( MAX_WIDTH - 4 ))
        for i in "${!_LINES_UNICODE[@]}"; do
            len="$(_strlen_display "${_LINES_UNICODE[i]}")"
            if (( len > max_line )); then
                _LINES_UNICODE[i]="$(_truncate_ellipsis "${_LINES_UNICODE[i]}" "$max_line")"
            fi
        done
        for i in "${!_LINES_ASCII[@]}"; do
            len="$(_strlen_display "${_LINES_ASCII[i]}")"
            if (( len > max_line )); then
                _LINES_ASCII[i]="$(_truncate_ellipsis "${_LINES_ASCII[i]}" "$max_line")"
            fi
        done
    fi
}

_truncate_ellipsis() {
    # Truncate to (cap-3) display chars and append "...". Uses bash's
    # locale-aware substring expansion under LC_ALL=C.UTF-8 so that a
    # multi-byte codepoint is never split in the middle.
    local s="$1" cap="$2" keep
    keep=$(( cap - 3 ))
    (( keep < 1 )) && keep=1
    printf '%s...' "${s:0:$keep}"
}

# -----------------------------------------------------------------------------
# _boxline: the ONE helper that pads a text line to BOX_WIDTH between two
# border chars. All padding flows through here — no hand-counted spaces
# anywhere else.
#
# BOX_WIDTH is the *inner* width — the number of horizontal border
# characters between the two corners. The padded line layout is:
#     [SIDE] [2-space indent + text + pad spaces] [SIDE]
# with (2 + text_len + pad) == BOX_WIDTH.  So:  pad = BOX_WIDTH - 2 - len.
# -----------------------------------------------------------------------------
_boxline() {
    local text="$1" side="$2" len pad
    len="$(_strlen_display "$text")"
    pad=$(( BOX_WIDTH - 2 - len ))
    (( pad < 0 )) && pad=0
    printf '%s  %s%*s%s\n' "$side" "$text" "$pad" '' "$side"
}

# -----------------------------------------------------------------------------
# render_issue: flat ASCII variant for /etc/issue.
# -----------------------------------------------------------------------------
render_issue() {
    local ruler line
    ruler="$(printf '%*s' "$BOX_WIDTH" '' | tr ' ' '=')"
    printf '%s\n' "$ruler"
    for line in "${_LINES_ASCII[@]}"; do
        printf '  %s\n' "$line"
    done
    printf '%s\n' "$ruler"
}

# -----------------------------------------------------------------------------
# render_issue_net: boxed variant for /etc/issue.net.
# -----------------------------------------------------------------------------
render_issue_net() {
    local tl tr bl br horiz vert
    case "$STYLE" in
        double)
            tl='╔'; tr='╗'; bl='╚'; br='╝'
            horiz='═'; vert='║' ;;
        single)
            tl='┌'; tr='┐'; bl='└'; br='┘'
            horiz='─'; vert='│' ;;
        ascii)
            tl='+'; tr='+'; bl='+'; br='+'
            horiz='='; vert='|' ;;
    esac

    local inner_horiz line i
    inner_horiz=""
    for (( i=0; i<BOX_WIDTH; i++ )); do
        inner_horiz+="$horiz"
    done

    printf '%s%s%s\n' "$tl" "$inner_horiz" "$tr"
    for line in "${_LINES_UNICODE[@]}"; do
        _boxline "$line" "$vert"
    done
    printf '%s%s%s\n' "$bl" "$inner_horiz" "$br"
}

# =============================================================================
# File I/O
# =============================================================================
atomic_write() {
    # $1 = target path, [$2 = mode override, default 0644]
    # Content via stdin.
    #
    # IMPORTANT — pipeline semantics. Callers typically use this as the
    # right-hand side of a pipe: `printf '%s\n' "$x" | atomic_write X`.
    # Every `exit 4` below therefore executes inside the pipeline's
    # right-hand subshell. Bash propagates that non-zero exit to the
    # parent shell ONLY because `set -o pipefail` is active at the top
    # of this file. Removing or disabling pipefail would make every
    # failure here silent — the parent would see exit 0 and log "wrote
    # X" over a target that was never actually written. If you ever
    # refactor the shell boilerplate, grep for `pipefail` first.
    local target="$1"
    local mode="${2:-0644}"
    local dir tmp
    dir="$(dirname "$target")"

    if [[ ! -d "$dir" ]]; then
        log_error "target directory does not exist: $dir"
        exit 4
    fi

    tmp="$(mktemp "${dir}/.${PROG_NAME}.XXXXXXXX")" || {
        log_error "failed to create tempfile in $dir"
        exit 4
    }

    # Ensure tempfile is removed on any failure.
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    cat > "$tmp" || {
        log_error "failed to write tempfile"
        exit 4
    }

    chmod "$mode" "$tmp" || { log_error "chmod failed on $tmp"; exit 4; }
    chown root:root "$tmp" 2>/dev/null || true  # chown may fail harmlessly
                                                 # on non-root dry/test runs

    mv -f "$tmp" "$target" || {
        log_error "failed to move $tmp to $target"
        exit 4
    }

    trap - EXIT
}

backup_file() {
    # $1 = path.
    #
    # Pristine semantics: the FIRST backup of a managed file is the
    # authoritative "pre-install state" — nothing is ever allowed to
    # overwrite it. A second install with a different --company-name
    # must NOT produce a new backup, because the file on disk at that
    # point is already a motd-managed artefact, not the operator's
    # original. A timestamped-per-run scheme would happily shadow the
    # real original with the previous install's output and leave
    # uninstall unable to reach the true pre-motd state.
    #
    # Artefact naming is `<base>.pristine.bak`, not `<base>.<ts>.bak`:
    # the uninstaller's fallback glob `<base>.[0-9]*.bak` never
    # matches the "pristine" suffix (first char after the dot is 'p',
    # not a digit), so we cannot accidentally collide with a legacy
    # timestamped backup left by a pre-pristine install.
    #
    # Symlink-safe: on Debian/Ubuntu /etc/motd is usually a symlink to
    # /run/motd.dynamic (pam_motd dynamic MOTD). Plain `cp -p` follows
    # symlinks and would back up the *content* of the link target under
    # the link's basename — wrong artefact, wrong mtime, and on a later
    # restore the wrong thing gets restored to disk. Detect the link
    # up front and preserve the link itself with `cp -P`.
    local path="$1"
    [[ "$BACKUP" == "true" ]] || return 0

    # Defensive: only chmod/chown the backup dir on creation. The
    # allowlist already confines BACKUP_DIR to /var/backups/motd* and
    # /srv/backups/motd*, but this belt-and-braces guard also prevents
    # mode changes on a pre-existing backup dir an operator may have
    # hardened further (0600, ACLs, immutable bit).
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 0700 "$BACKUP_DIR"
        chown root:root "$BACKUP_DIR" 2>/dev/null || true
    fi

    # Serialise concurrent installers through a lock file under
    # BACKUP_DIR so two racing `install.sh` calls cannot each pass the
    # `[[ -e "$dst" ]]` existence check and then both write the
    # pristine backup. Without the lock the second writer silently
    # clobbers the first's snapshot, and the operator has no way to
    # tell which of the two files is the real authoritative pre-install
    # state.
    #
    # flock(1) degrades gracefully: if the binary is missing (minimal
    # container, Alpine without util-linux), we fall through WITHOUT
    # the lock and log a warning. The TOCTOU window is small (< 1s),
    # and a single operator running install.sh once per host is the
    # common case — the lock is a defence-in-depth for automated
    # config-management tools that might fire two parallel installs.
    #
    # FD 200 is the convention from the flock(1) manpage: a numeric FD
    # the shell is guaranteed not to use for any builtin redirection,
    # stable across bash versions, and easy to close via `exec 200>&-`.
    # Bash's named-FD syntax `{var}` would be more elegant but the
    # RETURN trap below needs a fixed FD number to close after the
    # local variable scope has unwound.
    #
    # Lock file lives in BACKUP_DIR (0600 root:root), next to the
    # pristine backups themselves. Using a sibling `.lock` file instead
    # of /run/ means the lock survives a /run remount and is easy for
    # an operator to inspect (`lsof /var/backups/motd/.lock`).
    local _lockfile="${BACKUP_DIR}/.lock"
    local _locked=0
    if command -v flock >/dev/null 2>&1; then
        : >>"$_lockfile" 2>/dev/null || true
        chmod 0600 "$_lockfile" 2>/dev/null || true
        # IMPORTANT: the 2>/dev/null MUST be on the group command, NOT
        # on the exec. `exec 200>file 2>/dev/null` applies BOTH redirections
        # permanently (exec without a command modifies the current shell),
        # which silently kills stderr for the rest of the script. Wrapping
        # in { ...; } scopes the stderr suppression to the group only.
        if { exec 200>"$_lockfile"; } 2>/dev/null; then
            if flock -x 200 2>/dev/null; then
                _locked=1
            else
                log_warn "flock on $_lockfile failed — proceeding without lock"
                { exec 200>&-; } 2>/dev/null || true
            fi
        fi
    fi
    # Release on function return. The lock is held for the entire
    # backup capture section including the cp / chmod / symlink refresh
    # below, which closes the TOCTOU window completely. Once the
    # function returns, atomic_write on the target path runs under its
    # own EXIT trap and does not need the backup lock.
    if (( _locked )); then
        # shellcheck disable=SC2064
        trap '{ exec 200>&-; } 2>/dev/null || true' RETURN
    fi

    # Distinguish "pre-existing operator file we backed up" from "file
    # we created from nothing". On first install of /etc/motd.conf (or
    # the MOTD script, or the sshd drop-in) there is literally nothing
    # to back up, but uninstall.sh must still know that the file needs
    # to be REMOVED — not restored from a non-existent "pristine"
    # snapshot. Without this marker a second install with different
    # --company-name would see an existing motd.conf and back it up as
    # "pristine", silently capturing the previous install's output as
    # the "original" and leaving uninstall unable to reach the true
    # pre-motd state.
    #
    # The marker's own presence is the signal — content is ignored. We
    # drop it BEFORE the existence check so first-install targets get a
    # marker even though there is nothing to copy.
    local _base_marker
    _base_marker="${BACKUP_DIR}/$(basename "$path").created"
    if [[ ! -e "$path" ]] && [[ ! -L "$path" ]]; then
        # Only create the marker if no pristine backup already exists —
        # otherwise a delete-and-reinstall would clobber a legitimate
        # pristine snapshot with a misleading "we created this" hint.
        if [[ ! -e "${BACKUP_DIR}/$(basename "$path").pristine.bak" ]] \
           && [[ ! -L "${BACKUP_DIR}/$(basename "$path").pristine.bak" ]]; then
            : >"$_base_marker"
            chmod 0600 "$_base_marker" 2>/dev/null || true
            chown root:root "$_base_marker" 2>/dev/null || true
        fi
        return 0
    fi

    local base dst latest
    base="$(basename "$path")"
    dst="${BACKUP_DIR}/${base}.pristine.bak"
    latest="${BACKUP_DIR}/${base}.latest.bak"

    # motd-created file on a re-run: the `.created` marker from a
    # previous install run survives on disk, and the file we are about
    # to overwrite is our own output from the last run, not an operator
    # artefact. Do NOT capture it as "pristine" — that would lock in a
    # mis-labelled snapshot. Leave the marker in place so uninstall
    # still knows to REMOVE the file rather than restore it.
    if [[ -e "$_base_marker" ]]; then
        log_info "re-install of motd-created $path — no pristine backup captured"
        return 0
    fi

    # Already captured? Refresh the latest.bak pointer (it may be
    # stale from a legacy timestamped install) and return. The
    # pristine backup itself is NEVER overwritten on a re-run.
    if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then
        # Re-enforce 0600 on the existing pristine backup. A legacy
        # install written by an earlier revision of this script may
        # have used looser perms; the parent dir is 0700 root:root so
        # the only attacker would be root, but the symmetric guarantee
        # "every backup file under BACKUP_DIR is 0600" closes the
        # surprise class. Skip the chmod when the backup itself is a
        # symlink-typed artefact (preserved via cp -P), since chmod
        # follows symlinks on Linux.
        if [[ ! -L "$dst" ]]; then
            chmod 0600 "$dst" 2>/dev/null || true
        fi
        ln -sfn "${base}.pristine.bak" "$latest"
        log_info "pristine backup already captured for $path — no re-backup"
        return 0
    fi

    if [[ -L "$path" ]]; then
        log_warn "$path is a symlink -> $(readlink "$path" 2>/dev/null || echo '?'); backing up link itself (cp -P)"
        cp -P "$path" "$dst"
    else
        cp -p "$path" "$dst"
    fi
    # chmod/chown on a symlink-typed backup only affects the target on
    # Linux (-h variants aren't portable everywhere); skip when the
    # backup artefact itself is a symlink.
    if [[ ! -L "$dst" ]]; then
        chmod 0600 "$dst"
        chown root:root "$dst" 2>/dev/null || true
    fi

    ln -sfn "${base}.pristine.bak" "$latest"
    log_info "captured pristine backup of $path -> $dst"
}

# =============================================================================
# sshd helpers
# =============================================================================
reload_sshd() {
    [[ "$SSHD_RELOAD" == "true" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || {
        log_warn "systemctl not available; skipping sshd reload"
        return 0
    }

    local unit=""
    if systemctl is-active --quiet sshd 2>/dev/null; then
        unit=sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        unit=ssh
    fi

    if [[ -z "$unit" ]]; then
        log_info "sshd not active; skipping reload"
        return 0
    fi

    # Non-zero on reload failure — previously this function log_warned
    # and returned 0, which let the caller report "done." while the
    # new banner was not yet live. With a validated drop-in already on
    # disk the reload is the last load-bearing step, and a silent
    # failure there is exactly the class of regression that shows up
    # only when an operator SSHes in hours later and sees the old
    # banner. Surface loudly and exit non-zero.
    if systemctl reload "$unit" 2>/dev/null; then
        log_info "reloaded ${unit}.service (existing sessions unaffected)"
        return 0
    fi
    log_error "failed to reload ${unit}.service — NEW BANNER IS NOT YET LIVE"
    log_hint  "run manually: systemctl reload $unit"
    return 1
}

# =============================================================================
# Self-check
# =============================================================================
self_check() {
    # Re-render in memory and diff against the file on disk. Fails loud if
    # anything drifted — guards against accidental post-write edits, FS bugs,
    # or quoting mistakes in the render path.
    #
    # Trailing-newline preservation: bash command substitution `$(…)`
    # strips all trailing newlines, so a file ending in "X\n" and an
    # in-memory render of "X\n" both collapse to "X" and compare equal
    # even if one of them is actually missing its final newline. The
    # `$(…; printf x)` idiom appends a sentinel byte that is then
    # stripped with `${var%x}`, which preserves every trailing newline
    # byte for the comparison. Same trick is documented in the bash
    # manual for exactly this case.
    #
    # Supported kinds:
    #   issue             re-runs render_issue and compares $2 byte-for-byte
    #   issue_net         re-runs render_issue_net and compares $2
    #   motd_config       compares pre-rendered string in $3 against $2
    #   motd_script       compares file-content of $3 against $2 (diff -q)
    #   sshd_dropin       compares pre-rendered string in $3 against $2
    # For the string-compare variants the caller passes the expected
    # content in $3 because regenerating it here would duplicate
    # build_unified_config / build_sshd_dropin / the rendered MOTD
    # source tempfile, and the regeneration path is not free of side
    # effects (build_unified_config touches WARNING_LINES_OVERRIDE).
    local kind="$1" path="$2" expected="${3:-}"
    local rendered
    case "$kind" in
        issue)       rendered="$(render_issue;     printf x)"; rendered="${rendered%x}" ;;
        issue_net)   rendered="$(render_issue_net; printf x)"; rendered="${rendered%x}" ;;
        motd_config) rendered="$expected"$'\n' ;;
        sshd_dropin) rendered="$expected"$'\n' ;;
        motd_script)
            # The MOTD script is a ~900-line file; a string compare
            # inside bash would fork off 1 MiB of argument buffer
            # unnecessarily. Defer to `diff -q` instead, which streams
            # two file descriptors and exits 0 / 1 / 2.
            if ! diff -q "$expected" "$path" >/dev/null 2>&1; then
                log_error "self-check failed: $path does not match rendered source $expected"
                exit 4
            fi
            return 0
            ;;
        *) log_error "self_check: unknown kind: $kind"; exit 4 ;;
    esac

    local on_disk
    on_disk="$(cat "$path"; printf x)"
    on_disk="${on_disk%x}"

    if [[ "$rendered" != "$on_disk" ]]; then
        log_error "self-check failed: $path does not match re-render"
        exit 4
    fi
}

# =============================================================================
# Banner phase
# =============================================================================
phase_banner() {
    [[ "$BANNER_ENABLED" == "true" ]] || { log_info "banner phase: skipped (disabled)"; return 0; }

    log_info "banner phase: starting"
    render_warning_lines
    _compute_box_width

    local issue_content issue_net_content
    issue_content="$(render_issue)"
    issue_net_content="$(render_issue_net)"

    if $DRY_RUN; then
        printf '===== %s =====\n' "$ISSUE_FILE"
        printf '%s\n' "$issue_content"
        printf '\n===== %s =====\n' "$ISSUE_NET_FILE"
        printf '%s\n' "$issue_net_content"
        if [[ "$CLEAR_MOTD" == "true" ]]; then
            printf '\n===== /etc/motd (would be cleared) =====\n'
        fi
        printf '\n[dry-run] BOX_WIDTH=%d  STYLE=%s  LANGUAGE=%s\n' \
            "$BOX_WIDTH" "$STYLE" "$LANGUAGE" >&2
        return 0
    fi

    # Write /etc/issue
    if [[ -f "$ISSUE_FILE" ]] && diff -q <(printf '%s\n' "$issue_content") "$ISSUE_FILE" >/dev/null 2>&1; then
        log_info "$ISSUE_FILE already up to date"
    else
        if [[ -f "$ISSUE_FILE" ]] && [[ "$BACKUP" != "true" ]] && ! $FORCE; then
            log_error "$ISSUE_FILE exists and --no-backup was passed without --force"
            exit 4
        fi
        backup_file "$ISSUE_FILE"
        printf '%s\n' "$issue_content" | atomic_write "$ISSUE_FILE"
        log_info "wrote $ISSUE_FILE"
    fi
    self_check issue "$ISSUE_FILE"

    # Write /etc/issue.net
    if [[ -f "$ISSUE_NET_FILE" ]] && diff -q <(printf '%s\n' "$issue_net_content") "$ISSUE_NET_FILE" >/dev/null 2>&1; then
        log_info "$ISSUE_NET_FILE already up to date"
    else
        if [[ -f "$ISSUE_NET_FILE" ]] && [[ "$BACKUP" != "true" ]] && ! $FORCE; then
            log_error "$ISSUE_NET_FILE exists and --no-backup was passed without --force"
            exit 4
        fi
        backup_file "$ISSUE_NET_FILE"
        printf '%s\n' "$issue_net_content" | atomic_write "$ISSUE_NET_FILE"
        log_info "wrote $ISSUE_NET_FILE"
    fi
    self_check issue_net "$ISSUE_NET_FILE"

    # Clear /etc/motd — only relevant when the banner phase runs and the
    # MOTD phase isn't going to overwrite update-motd.d anyway. We still
    # honour CLEAR_MOTD when both run; pam_motd composes the dynamic
    # output from /etc/update-motd.d/*, so the static /etc/motd is
    # additive and harmless to blank.
    #
    # Symlink handling: Debian/Ubuntu ship /etc/motd as a symlink to
    # /run/motd.dynamic so pam_motd can compose a fresh file per boot.
    # `atomic_write` uses `mv -f` under the hood; `mv -f` on a symlink
    # REPLACES the link with the tempfile (a regular empty file) and
    # orphans /run/motd.dynamic for the rest of the boot. We detect
    # the link explicitly, back it up via `cp -P`, then `rm -f` before
    # writing the cleared static file. Callers who do not want the
    # static clobber should pass `--no-clear-motd`.
    if [[ "$CLEAR_MOTD" == "true" ]]; then
        if [[ -L /etc/motd ]]; then
            local _motd_target
            _motd_target="$(readlink /etc/motd 2>/dev/null || echo '?')"
            log_info "/etc/motd is a symlink -> $_motd_target (pam_motd dynamic)"
            backup_file /etc/motd
            rm -f /etc/motd
            printf '' | atomic_write /etc/motd
            log_info "cleared /etc/motd (replaced symlink with empty regular file)"
        elif [[ -f /etc/motd ]] && [[ ! -s /etc/motd ]]; then
            log_info "/etc/motd already empty"
        else
            backup_file /etc/motd
            printf '' | atomic_write /etc/motd
            log_info "cleared /etc/motd"
        fi
    fi
}

# =============================================================================
# MOTD phase
# =============================================================================

# Build the unified config file content. Both banner and MOTD keys go
# into the same file so /etc/motd.conf is the single source of truth.
build_unified_config() {
    # Refresh the WARNING_LINES_OVERRIDE scalar from the live array so
    # the heredoc sees the current set of override lines (CLI + config
    # already merged by _split_warning_lines_override). No-op when the
    # array is empty — the scalar stays "" and renders as ''.
    _join_warning_lines_override
    cat <<EOF
# =============================================================================
# motd — installed configuration
# -----------------------------------------------------------------------------
# Generated by: $PROG_NAME $MOTD_VERSION
# Source URL  : $PROJECT_URL
#
# This file is PARSED (never sourced) by:
#   - the motd installer (re-run --config=$MOTD_CONFIG_PATH to update)
#   - the runtime MOTD script ($MOTD_SCRIPT_PATH)
# Both readers use a whitelist KEY=VALUE parser that rejects shell
# expansion metacharacters. Do NOT embed \$(...), backticks, or \\ into
# values — they will be dropped at parse time, not executed.
#
# Edit by hand if you like; re-running the installer will rewrite the
# file (a pristine backup is taken on the first install). Quote any
# value containing spaces.
#
# The file's own mtime serves as the "last installed" indicator — we
# deliberately do NOT embed a timestamp line here because that would
# make every installer run byte-different from the previous one,
# defeating the idempotency check and accreting one backup per run.
# =============================================================================

# Note: scope toggles (BANNER_ENABLED / MOTD_ENABLED /
# SSHD_BANNER_MANAGE) are deliberately NOT written here. They are
# CLI-only per-invocation flags; persisting them would cause a one-off
# --motd-only run to silently disable the banner for every future
# install. See load_config's whitelist comment for details.
# (Do NOT wrap flag names in backticks here: this heredoc is UNQUOTED
# so shell values like \$COMPANY_NAME expand. Backticks around a token
# turn into command substitution and execute the token — a prior
# revision of this comment said \`--motd-only\` and shipped a visible
# "--motd-only: command not found" error on every install.)

# -- Banner --
COMPANY_NAME="$COMPANY_NAME"
CONTACT="$CONTACT"
LANGUAGE="$LANGUAGE"
STYLE="$STYLE"
MIN_WIDTH=$MIN_WIDTH
STATUTE="$STATUTE"
STATUTE_ASCII="$STATUTE_ASCII"
# WARNING_LINES_OVERRIDE — optional. Single-quoted so the literal \\n
# separator survives the config-file parser (the double-quoted branch
# rejects backslash). Empty by default; the language preset is used.
WARNING_LINES_OVERRIDE='$WARNING_LINES_OVERRIDE'
ISSUE_FILE="$ISSUE_FILE"
ISSUE_NET_FILE="$ISSUE_NET_FILE"
CLEAR_MOTD=$CLEAR_MOTD

# -- MOTD --
MOTD_SUBTITLE="$MOTD_SUBTITLE"
MOTD_MIN_WIDTH=$MOTD_MIN_WIDTH
MOTD_VERBOSE=$MOTD_VERBOSE
MOTD_FOOTER="$MOTD_FOOTER"
MOTD_SHOW_SERVICES=$MOTD_SHOW_SERVICES
MOTD_SHOW_UPDATES=$MOTD_SHOW_UPDATES
MOTD_SHOW_RECENT_LOGINS=$MOTD_SHOW_RECENT_LOGINS
MOTD_SECURITY_PRIV_ONLY=$MOTD_SECURITY_PRIV_ONLY
MOTD_PUBIP_URL="$MOTD_PUBIP_URL"
MOTD_SCRIPT_PATH="$MOTD_SCRIPT_PATH"
MOTD_CONFIG_PATH="$MOTD_CONFIG_PATH"
MOTD_CACHE_DIR="$MOTD_CACHE_DIR"

# -- sshd integration --
SSHD_BANNER_DROPIN="$SSHD_BANNER_DROPIN"
SSHD_RELOAD=$SSHD_RELOAD

# -- Backups --
BACKUP=$BACKUP
BACKUP_DIR="$BACKUP_DIR"
EOF
}

# Resolve the path to the MOTD source script that ships next to install.sh.
_motd_source_path() {
    local self_dir
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    printf '%s/motd/10-system-info.sh' "$self_dir"
}

# -----------------------------------------------------------------------------
# Ubuntu default update-motd.d scripts we disable when we install our own
# dynamic MOTD. Every path that exists AND has the executable bit set is
# chmod'd 0644 (package-managed content untouched — only the +x bit is
# dropped) and its path recorded in $BACKUP_DIR/update-motd.d.disabled.list
# so uninstall.sh can put the +x back exactly where it was.
#
# We enumerate explicitly instead of globbing /etc/update-motd.d/*:
#
#   * Globbing would disable any custom script an operator added after us,
#     which is surprising and hostile.
#   * The known-defaults list changes slowly (the Ubuntu 22.04 and 24.04
#     lists overlap almost completely), and any new entry is additive —
#     it just means the next Ubuntu release might still show one default
#     block until we update the list. Better than nuking user scripts.
#
# If a file doesn't exist on this host (minimal image, Alpine, RHEL
# without landscape-common, ...) we silently skip it.
# -----------------------------------------------------------------------------
_ubuntu_motd_defaults() {
    cat <<'EOF'
/etc/update-motd.d/00-header
/etc/update-motd.d/10-help-text
/etc/update-motd.d/50-landscape-sysinfo
/etc/update-motd.d/50-motd-news
/etc/update-motd.d/80-livepatch
/etc/update-motd.d/80-esm
/etc/update-motd.d/85-fwupd
/etc/update-motd.d/88-esm-announce
/etc/update-motd.d/90-updates-available
/etc/update-motd.d/91-contract-ua-esm-status
/etc/update-motd.d/91-release-upgrade
/etc/update-motd.d/92-unattended-upgrades
/etc/update-motd.d/95-hwe-eol
/etc/update-motd.d/97-overlayroot
/etc/update-motd.d/98-fsck-at-reboot
/etc/update-motd.d/98-reboot-required
EOF
}

# Drop the executable bit on every known Ubuntu default that is (a) present,
# (b) a regular file or a non-package-owned symlink, and (c) currently
# executable. Paths that were actually modified are appended to
# $disabled_list so uninstall.sh can put them back.
#
# Two layout shapes show up on Ubuntu 24.04:
#
#   1. **Regular file** — most update-motd.d hooks (`00-header`,
#      `90-updates-available`, …). We chmod 0644 to remove +x; the file
#      content is left untouched, so a package upgrade that replaces
#      the file restores the executable bit and we redo the chmod on
#      the next install.sh run.
#
#   2. **Symlink** — `50-landscape-sysinfo` is the only one in the wild
#      and points at `/usr/share/landscape/landscape-sysinfo.wrapper`.
#      The historical fix was to skip symlinks entirely because chmod
#      follows symlinks and would corrupt the package-managed target's
#      executable bit (dpkg --verify would then flag landscape-common
#      as tampered). The cosmetic regression was: Landscape's "System
#      information as of …" block still appeared above the motd output.
#
#      The fix: replace the SYMLINK ITSELF with an empty regular
#      file, leaving the package-managed wrapper alone. The symlink
#      at /etc/update-motd.d/50-landscape-sysinfo is NOT dpkg-owned
#      (verified via `dpkg -S` returning "no path found" for the
#      symlink path; only the wrapper target is package-owned).
#      Removing and replacing the symlink therefore does not trip
#      `dpkg --verify`. The replacement is an empty 0644 stub which
#      pam_motd skips (no +x = not executed). The symlink's original
#      target is recorded in `update-motd.d.disabled.list` with a
#      `symlink:<target>` notation so uninstall.sh can recreate the
#      symlink byte-identical to the upstream layout.
#
# The function is idempotent: a second run over an already-disabled host
# is a no-op, nothing is logged, nothing is appended to the list.
_disable_ubuntu_motd_defaults() {
    local disabled_list="${BACKUP_DIR}/update-motd.d.disabled.list"
    local path changed=0 replaced_links=0

    # Only create + harden on first use — never overwrite the mode on
    # an existing operator-hardened backup dir. See backup_file for
    # the same guard.
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 0700 "$BACKUP_DIR" 2>/dev/null || true
        chown root:root "$BACKUP_DIR" 2>/dev/null || true
    fi

    # Read existing list (if any) so we don't duplicate entries across runs.
    local existing=""
    [[ -f "$disabled_list" ]] && existing="$(cat "$disabled_list" 2>/dev/null)"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$path" == "$MOTD_SCRIPT_PATH" ]] && continue  # never disable ourselves
        # [[ -L ]] test MUST come before [[ -f ]] because [[ -f ]] follows
        # symlinks and would match a symlink whose target is a regular file.
        if [[ -L "$path" ]]; then
            # Replace the symlink with an empty 0644 stub. The original
            # target is captured for restore. We treat any existing
            # `symlink:` entry as "already done" and short-circuit so a
            # re-run is a no-op.
            local link_target
            link_target="$(readlink "$path" 2>/dev/null || true)"
            if [[ -z "$link_target" ]]; then
                log_warn "could not read symlink target for $path — skipping"
                continue
            fi
            local list_marker="symlink:${path}:${link_target}"
            if printf '%s\n' "$existing" | grep -qxF "$list_marker"; then
                # Already neutralised on a prior run.
                continue
            fi
            rm -f "$path" 2>/dev/null || {
                log_warn "could not remove symlink $path (permission?)"
                continue
            }
            : >"$path" 2>/dev/null || {
                log_warn "could not create empty stub at $path"
                continue
            }
            chmod 0644 "$path" 2>/dev/null || true
            chown root:root "$path" 2>/dev/null || true
            log_info "replaced symlink $path with empty stub (was -> $link_target)"
            replaced_links=$((replaced_links + 1))
            printf '%s\n' "$list_marker" >> "$disabled_list"
            existing="$existing"$'\n'"$list_marker"
            continue
        fi
        [[ -f "$path" ]] || continue           # script not present on this host
        [[ -x "$path" ]] || continue           # already disabled — nothing to do

        chmod 0644 "$path" 2>/dev/null || {
            log_warn "could not chmod -x $path (permission?)"
            continue
        }
        log_info "disabled Ubuntu default: $path"
        changed=$((changed + 1))

        # Append to the disabled list unless it's already in there.
        if ! printf '%s\n' "$existing" | grep -qxF "$path"; then
            printf '%s\n' "$path" >> "$disabled_list"
            existing="$existing"$'\n'"$path"
        fi
    done < <(_ubuntu_motd_defaults)

    if [[ "$changed" -eq 0 ]] && [[ "$replaced_links" -eq 0 ]]; then
        log_info "Ubuntu MOTD defaults already disabled (or none present)"
    fi

    if [[ -f "$disabled_list" ]]; then
        chmod 0600 "$disabled_list" 2>/dev/null || true
        chown root:root "$disabled_list" 2>/dev/null || true
    fi
}

phase_motd() {
    [[ "$MOTD_ENABLED" == "true" ]] || { log_info "motd phase: skipped (disabled)"; return 0; }

    local motd_src motd_dir cfg_content
    motd_src="$(_motd_source_path)"
    motd_dir="$(dirname "$MOTD_SCRIPT_PATH")"

    if [[ ! -f "$motd_src" ]]; then
        log_error "motd source script not found: $motd_src"
        log_hint "ensure the 'motd/' directory shipped alongside install.sh"
        exit 4
    fi

    cfg_content="$(build_unified_config)"

    if $DRY_RUN; then
        printf '\n===== %s (would be installed) =====\n' "$MOTD_SCRIPT_PATH"
        head -20 "$motd_src"
        printf '...\n[%d lines total]\n' "$(wc -l < "$motd_src" | tr -d ' ')"
        printf '\n===== %s (would be written) =====\n' "$MOTD_CONFIG_PATH"
        printf '%s\n' "$cfg_content"
        printf '\n===== Ubuntu default update-motd.d scripts that would be disabled =====\n'
        local candidate shown=0
        while IFS= read -r candidate; do
            [[ -z "$candidate" ]] && continue
            if [[ -L "$candidate" ]]; then
                # Symlinks are replaced with an empty stub instead of
                # being skipped. Mirrors the real-run logic in
                # _disable_ubuntu_motd_defaults.
                local _tgt
                _tgt="$(readlink "$candidate" 2>/dev/null || echo '?')"
                printf '  would replace symlink %s -> %s with empty stub\n' "$candidate" "$_tgt"
                shown=$((shown + 1))
                continue
            fi
            if [[ -f "$candidate" ]] && [[ -x "$candidate" ]]; then
                printf '  would chmod -x %s\n' "$candidate"
                shown=$((shown + 1))
            fi
        done < <(_ubuntu_motd_defaults)
        [[ "$shown" -eq 0 ]] && printf '  (none present on this host)\n'
        printf '\n[dry-run] motd cache dir: %s\n' "$MOTD_CACHE_DIR" >&2
        return 0
    fi

    log_info "motd phase: starting"

    # Some distros (RHEL minimal, Alpine) ship without /etc/update-motd.d/.
    # We do not auto-create it because PAM may not have pam_motd wired in.
    if [[ ! -d "$motd_dir" ]]; then
        log_warn "$motd_dir does not exist — pam_motd may not be configured on this distro"
        log_hint "Debian/Ubuntu: apt install libpam-modules    (provides pam_motd.so)"
        log_hint "RHEL/Alma/Rocky: ensure pam_motd.so is in /etc/pam.d/sshd"
        log_warn "skipping MOTD script install — banner phase (if any) is unaffected"
        return 0
    fi

    # One-time legacy cleanup — mirrors the Salt formula's
    # login_banner_motd_cache_legacy_cleanup state. /tmp/.motd_pubip
    # is the world-writable public-IP cache from an earlier revision
    # of the MOTD script. Any local user could pre-plant a file there
    # and the root MOTD script would read it back into a terminal on
    # the next SSH login — terminal-injection / LPE vector. Hosts
    # that have been managed by Salt or by a recent install.sh
    # already had /var/cache/motd in place, but a host that was only
    # ever managed by an older install.sh keeps the legacy cache
    # around forever without this cleanup. Removed only by install.sh,
    # not uninstall: uninstall removes what it installed, and this
    # file is something the installer is REPLACING with
    # /var/cache/motd.
    rm -f /tmp/.motd_pubip 2>/dev/null || true

    # 1. Cache directory + salt-status marker. The marker mtime is read by
    #    the runtime script as "last provisioning time"; touching it on
    #    every install is the cheapest possible heartbeat.
    #
    #    Only chmod/chown on creation so a pre-existing, operator-hardened
    #    cache dir keeps its mode. The allowlist already restricts
    #    MOTD_CACHE_DIR to /var/cache/motd*, so this is defence in depth.
    if [[ ! -d "$MOTD_CACHE_DIR" ]]; then
        mkdir -p "$MOTD_CACHE_DIR"
        chmod 0755 "$MOTD_CACHE_DIR"
        chown root:root "$MOTD_CACHE_DIR" 2>/dev/null || true
        log_info "created $MOTD_CACHE_DIR"
    fi
    touch "$MOTD_CACHE_DIR/salt-status" 2>/dev/null || true
    chmod 0644 "$MOTD_CACHE_DIR/salt-status" 2>/dev/null || true

    # 2. Unified config file (banner + MOTD + sshd keys).
    if [[ -f "$MOTD_CONFIG_PATH" ]] && diff -q <(printf '%s\n' "$cfg_content") "$MOTD_CONFIG_PATH" >/dev/null 2>&1; then
        log_info "$MOTD_CONFIG_PATH already up to date"
    else
        backup_file "$MOTD_CONFIG_PATH"
        printf '%s\n' "$cfg_content" | atomic_write "$MOTD_CONFIG_PATH" 0644
        log_info "wrote $MOTD_CONFIG_PATH"
    fi
    # Byte-compare the on-disk /etc/motd.conf against the content we
    # just rendered. This catches FS-level write failures that the
    # atomic rename somehow let through and any post-install
    # hand-edit that slipped in between atomic_write and the next
    # phase.
    self_check motd_config "$MOTD_CONFIG_PATH" "$cfg_content"

    # 3. Runtime MOTD script.
    #
    # Empty-source guard: a zero-byte $motd_src would produce a zero-byte
    # /etc/update-motd.d/10-system-info, which `bash -n` at the bottom
    # of this function would *confirm as valid* (empty scripts parse
    # clean) and the install would silently deploy a no-op MOTD. Detect
    # the empty source up front and refuse.
    if [[ ! -s "$motd_src" ]]; then
        log_error "source motd script is empty or missing: $motd_src"
        exit 4
    fi

    # Render the runtime script with MOTD_CONFIG_PATH substituted.
    # The stock source calls `_motd_load_config /etc/motd.conf`; without
    # this substitution the runtime would ignore --motd-config-path and
    # always read /etc/motd.conf. Rendering to a tempfile (rather than
    # patching in place after atomic_write) keeps the idempotency check
    # `diff -q <rendered> <installed>` honest — a patched-in-place
    # target would fail the diff on every re-run and flap the backup.
    local rendered_src="$motd_src"
    local rendered_tmp=""
    if [[ "$MOTD_CONFIG_PATH" != "/etc/motd.conf" ]]; then
        rendered_tmp="$(mktemp "${TMPDIR:-/tmp}/.motd-src.XXXXXXXX")" || {
            log_error "failed to create tempfile for rendered motd source"
            exit 4
        }
        # shellcheck disable=SC2064
        trap "rm -f '$rendered_tmp'" EXIT
        # sed delimiter `|` is safe: _validate_abs_path rejects pipe
        # alongside whitespace, control bytes, and $ ` " \. No
        # sed-active byte can survive into MOTD_CONFIG_PATH, so the
        # `s|A|B|` substitution is bounded by the literal delimiters
        # we wrote above and the RHS interpolation is closed safely.
        # The prefix allowlist in _validate_managed_prefix is a
        # secondary filter (it restricts WHERE the path lives, not
        # WHICH bytes it may contain) — do not rely on it to catch
        # sed metacharacters.
        sed "s|^_motd_load_config /etc/motd\\.conf\$|_motd_load_config ${MOTD_CONFIG_PATH}|" \
            "$motd_src" >"$rendered_tmp" || {
            log_error "failed to render motd source with MOTD_CONFIG_PATH=$MOTD_CONFIG_PATH"
            rm -f "$rendered_tmp"
            exit 4
        }
        rendered_src="$rendered_tmp"
    fi

    if [[ -f "$MOTD_SCRIPT_PATH" ]] && diff -q "$rendered_src" "$MOTD_SCRIPT_PATH" >/dev/null 2>&1; then
        log_info "$MOTD_SCRIPT_PATH already up to date"
    else
        backup_file "$MOTD_SCRIPT_PATH"
        # Feed the rendered source directly via stdin redirection
        # instead of cat|pipe — no subshell, no UUOC, same semantics.
        atomic_write "$MOTD_SCRIPT_PATH" 0755 < "$rendered_src"
        log_info "wrote $MOTD_SCRIPT_PATH"
    fi
    # Byte-compare: the installed MOTD script must match the rendered
    # source byte-for-byte. Catches a corrupt copy that the atomic
    # rename passed through.
    self_check motd_script "$MOTD_SCRIPT_PATH" "$rendered_src"

    if [[ -n "$rendered_tmp" ]]; then
        rm -f "$rendered_tmp"
        trap - EXIT
    fi

    # 4. Disable Ubuntu's default /etc/update-motd.d/* scripts so they
    #    don't render alongside ours. Without this step a login shows
    #    the Ubuntu 00-header / 10-help-text / 50-landscape-sysinfo /
    #    50-motd-news / 90-updates-available / 91-contract-ua-esm-status
    #    etc. blocks BEFORE and AFTER our rounded-box header — which is
    #    the single worst first-impression a branded MOTD can make.
    #
    #    The helper is idempotent and records which paths it actually
    #    touched in $BACKUP_DIR/update-motd.d.disabled.list so uninstall.sh
    #    can restore the +x state cleanly.
    _disable_ubuntu_motd_defaults

    # 5. profile.d wrapper — renders the MOTD live at interactive login.
    #
    #    The runtime MOTD script now exits immediately when stdout is not
    #    a TTY ([ -t 1 ] || exit 0). This means pam_motd — which redirects
    #    stdout to /run/motd.dynamic — gets an empty cache file and displays
    #    nothing. The actual coloured MOTD is rendered by this profile.d
    #    wrapper, where stdout IS the login terminal.
    #
    #    Guards:
    #      * `case $-` — only interactive shells (scp/rsync/CI skip this)
    #      * `$PS1`    — double-check for interactive mode
    #      * The script itself gates on [ -t 1 ], so even a piped `bash -l`
    #        gets no output.
    #
    #    Naming: `zz-` prefix ensures this runs after all other profile.d
    #    scripts (e.g. system hardening that sets TMOUT, umask).
    local profiled_wrapper="/etc/profile.d/zz-motd.sh"
    local profiled_content
    profiled_content="$(cat <<PROFILED
# Managed by motd ($PROJECT_URL) — do not edit.
# Render the dynamic MOTD with colours at interactive login.
# pam_motd is bypassed (script exits when stdout is not a TTY)
# so this wrapper is the sole MOTD display path.
case \$- in *i*) ;; *) return ;; esac
[ -n "\$PS1" ] || return
[ -x "$MOTD_SCRIPT_PATH" ] && "$MOTD_SCRIPT_PATH"
PROFILED
)"

    if [[ -f "$profiled_wrapper" ]] && diff -q <(printf '%s\n' "$profiled_content") "$profiled_wrapper" >/dev/null 2>&1; then
        log_info "$profiled_wrapper already up to date"
    else
        backup_file "$profiled_wrapper"
        printf '%s\n' "$profiled_content" | atomic_write "$profiled_wrapper" 0644
        log_info "wrote $profiled_wrapper"
    fi

    # 6. Final smoke check: rendered script must parse cleanly. Catches
    #    a corrupt copy or an FS-level write failure that the atomic
    #    rename somehow let through.
    if ! bash -n "$MOTD_SCRIPT_PATH" 2>/dev/null; then
        log_error "MOTD script syntax check failed after install: $MOTD_SCRIPT_PATH"
        exit 4
    fi
}

# =============================================================================
# sshd phase
# =============================================================================

# Marker comment that lets us recognise our own line in /etc/ssh/sshd_config
# when no Include directive is present and we have to append directly.
readonly SSHD_APPEND_MARKER="# motd-banner: managed by ${PROJECT_URL} — do not edit"

# Build the drop-in file body. Same content for both append and drop-in
# paths — only the surrounding context differs.
build_sshd_dropin() {
    cat <<EOF
# Managed by motd ($PROJECT_URL) — do not edit.
# Re-run the motd installer to refresh, or remove via uninstall.sh.
Banner $ISSUE_NET_FILE
EOF
}

phase_sshd() {
    [[ "$SSHD_BANNER_MANAGE" == "true" ]] || { log_info "sshd phase: skipped (disabled)"; return 0; }

    local sshd_main=/etc/ssh/sshd_config
    local dropin="$SSHD_BANNER_DROPIN"
    local dropin_content
    dropin_content="$(build_sshd_dropin)"

    if $DRY_RUN; then
        local mode="drop-in"
        if [[ -f "$sshd_main" ]] && ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d' "$sshd_main" 2>/dev/null; then
            mode="append-to-sshd_config"
        fi
        printf '\n===== %s =====\n' "$dropin"
        printf '%s\n' "$dropin_content"
        printf '\n[dry-run] sshd integration mode: %s\n' "$mode" >&2
        printf '[dry-run] target ssh banner file: %s\n' "$ISSUE_NET_FILE" >&2
        # Surface the marker check at dry-run time too so an operator
        # who runs --dry-run before the real install learns
        # immediately that the chosen --sshd-dropin path collides
        # with an existing unmanaged file. The real-install branch
        # enforces the same rule via _sshd_install_dropin /
        # _sshd_append_main and aborts with exit 3 unless --force is
        # passed.
        if [[ "$mode" == "drop-in" ]] \
           && [[ -e "$dropin" ]] \
           && ! grep -qF "# Managed by motd" "$dropin" 2>/dev/null \
           && ! $FORCE; then
            printf '[dry-run] WARNING: %s exists and is not managed by motd\n' "$dropin" >&2
            printf '[dry-run] real install would refuse with exit 3 unless --force is passed\n' >&2
        fi
        return 0
    fi

    log_info "sshd phase: starting"

    if [[ ! -f "$sshd_main" ]]; then
        log_warn "$sshd_main not found — skipping sshd integration"
        return 0
    fi

    # Decide path: drop-in (preferred) vs append-to-main.
    if grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d' "$sshd_main" 2>/dev/null; then
        _sshd_install_dropin "$dropin" "$dropin_content"
    else
        log_warn "$sshd_main has no 'Include /etc/ssh/sshd_config.d/*.conf' directive"
        log_warn "falling back to direct append (with marker comment)"
        _sshd_append_main "$sshd_main"
    fi
}

_sshd_install_dropin() {
    local dropin="$1" content="$2"
    local dir
    dir="$(dirname "$dropin")"

    if [[ ! -d "$dir" ]]; then
        log_warn "$dir does not exist — creating"
        mkdir -p "$dir"
        chmod 0755 "$dir"
    fi

    # Refuse to overwrite any pre-existing drop-in whose contents do not
    # carry our managed marker. Without this guard, an operator typo on
    # `--sshd-dropin` (e.g. pointing at the cloud-init drop-in
    # /etc/ssh/sshd_config.d/10-allow-root-password-login.conf) silently
    # replaces the unrelated file with a `Banner /etc/issue.net` directive
    # — `sshd -t` accepts it because the directive is syntactically valid,
    # and on the next reboot the host loses whatever the original drop-in
    # was guaranteeing (root login, password auth, MaxAuthTries override, …).
    # The marker check is positional: every managed drop-in we ever wrote
    # starts with `# Managed by motd`, so a byte-identical idempotent re-run
    # passes the check naturally; only files we did NOT write hit the abort.
    # `--force` overrides for the rare case where an operator deliberately
    # wants to take ownership of an existing drop-in — backup_file still
    # captures the previous content as `<base>.pristine.bak` first.
    if [[ -e "$dropin" ]] \
       && ! grep -qF "# Managed by motd" "$dropin" 2>/dev/null \
       && ! $FORCE; then
        log_error "$dropin exists and is not managed by motd"
        log_hint  "if this was intentional, pass --force to take ownership"
        log_hint  "(a pristine backup of the existing file will be captured first)"
        exit 3
    fi

    # Idempotent: skip the write entirely if the content hasn't changed.
    # The sshd test/reload only fires when the file actually changes.
    if [[ -f "$dropin" ]] && diff -q <(printf '%s\n' "$content") "$dropin" >/dev/null 2>&1; then
        log_info "$dropin already up to date"
        return 0
    fi

    # Validate-then-move: write the candidate to a dotfile sibling (so the
    # sshd_config.d glob `*.conf` does NOT pick it up yet), run sshd -t
    # against a synthetic main config that Includes it, and only rename
    # into place on success. This closes the write-then-validate window
    # where a broken drop-in briefly existed under its real name and
    # could have been read by a concurrent sshd reload (parallel tool,
    # Ctrl-C between write and validate, fresh-install race with no
    # backup to revert to).
    local tmp
    tmp="$(mktemp "${dir}/.${PROG_NAME}.XXXXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT
    chmod 0644 "$tmp"
    printf '%s\n' "$content" > "$tmp"

    if ! _sshd_validate dropin "$tmp"; then
        rm -f "$tmp"
        trap - EXIT
        log_error "sshd validation failed for candidate drop-in — refusing to install"
        exit 4
    fi

    backup_file "$dropin"
    mv -f "$tmp" "$dropin"
    trap - EXIT
    log_info "wrote $dropin (validated)"
    # Byte-compare the installed drop-in against the rendered body.
    # Mirrors the issue / issue_net self-check shape.
    self_check sshd_dropin "$dropin" "$content"
    reload_sshd
}

_sshd_append_main() {
    local sshd_main="$1"

    # Already managed?
    if grep -qF "$SSHD_APPEND_MARKER" "$sshd_main" 2>/dev/null; then
        # Marker present — verify the Banner line is the right one. If
        # it points elsewhere, fall through to the rewrite path below.
        #
        # Fixed-string match (-F) to avoid regex metacharacter pitfalls:
        # the default /etc/issue.net contains a literal '.', and under
        # -E that '.' would match ANY single character, so "Banner
        # /etc/issueXnet" would spuriously count as a match. Using -xF
        # makes the grep a whole-line literal compare. We accept that
        # sshd_config lines with leading whitespace are NOT recognised
        # as managed — sshd_config itself never ships such lines, and
        # if an operator hand-indented the directive the "stale block"
        # rewrite path is the safe outcome.
        if grep -qxF "Banner $ISSUE_NET_FILE" "$sshd_main" 2>/dev/null; then
            log_info "$sshd_main already has managed Banner directive"
            return 0
        fi
        log_info "$sshd_main has stale managed Banner block — rewriting"
    fi

    # Single-pass rewrite: strip any existing managed block AND append the
    # new one in one awk invocation, write to a sibling tempfile, validate,
    # then rename once. The older split approach ran `_sshd_strip_managed_block`
    # first (one tmp + one mv) and then rebuilt the append candidate (second
    # tmp + second mv), which meant the file briefly existed on disk with
    # the block stripped but no banner block appended. Not fatal, but not
    # idempotent either: a parallel reader between the two renames would
    # observe a partial state. One awk pipeline + one rename is cleaner.
    local tmp dir end_marker
    dir="$(dirname "$sshd_main")"
    end_marker="${SSHD_APPEND_MARKER/managed by/end managed by}"
    tmp="$(mktemp "${dir}/.${PROG_NAME}.XXXXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    awk -v start="$SSHD_APPEND_MARKER" \
        -v end="$end_marker" \
        -v banner="Banner $ISSUE_NET_FILE" '
        # Phase 1: copy input while dropping any existing managed block.
        index($0, start) { skip = 1; next }
        skip && index($0, end) { skip = 0; next }
        skip { next }
        { print }
        # Phase 2: append the fresh managed block at EOF.
        END {
            print ""
            print start
            print banner
            print end
        }
    ' "$sshd_main" > "$tmp"

    chmod --reference="$sshd_main" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
    chown --reference="$sshd_main" "$tmp" 2>/dev/null || chown root:root "$tmp" 2>/dev/null || true

    if ! _sshd_validate main "$tmp"; then
        rm -f "$tmp"
        trap - EXIT
        log_error "sshd validation failed for candidate main config — refusing to install"
        exit 4
    fi

    backup_file "$sshd_main"
    mv -f "$tmp" "$sshd_main"
    trap - EXIT
    log_info "appended managed Banner block to $sshd_main (validated)"
    reload_sshd
}

# -----------------------------------------------------------------------------
# _sshd_validate — one helper, two call shapes.
#
# Shape A (drop-in):
#     _sshd_validate dropin <candidate>
#   The candidate is a freshly-written sshd_config.d drop-in. We copy the
#   live /etc/ssh/sshd_config into a throwaway main file, append an
#   explicit `Include <candidate>` line, and run `sshd -t -f` against
#   that synthetic main. The candidate lives in sshd_config.d/ as a
#   dotfile (".motd.XXXX"), so the existing glob `Include
#   /etc/ssh/sshd_config.d/*.conf` does NOT pick it up — clean isolation
#   between "what's currently live" and "what we're about to ship".
#
# Shape B (main):
#     _sshd_validate main <candidate>
#   The candidate is a complete replacement /etc/ssh/sshd_config (the
#   append-to-main fallback for hosts without an Include directive).
#   We run `sshd -t -f <candidate>` directly — no indirection needed.
#
# Consolidated from two near-duplicate validators. The earlier split
# used a separate `_sshd_strip_managed_block` helper that was merged
# into the awk pipeline inside _sshd_append_main; anyone looking for a
# standalone strip should copy that awk block rather than reintroducing
# the split two-rename approach.
# -----------------------------------------------------------------------------
_sshd_validate() {
    local kind="$1" candidate="$2" err test_dir test_main

    if ! command -v sshd >/dev/null 2>&1; then
        log_warn "sshd binary not in PATH — skipping syntactic validation"
        return 0
    fi

    case "$kind" in
        dropin)
            local sshd_main=/etc/ssh/sshd_config
            if [[ ! -f "$sshd_main" ]]; then
                log_warn "$sshd_main not found — skipping candidate validation"
                return 0
            fi
            test_dir="$(mktemp -d)"
            # shellcheck disable=SC2064
            trap "rm -rf '$test_dir'" RETURN
            test_main="${test_dir}/sshd_config"
            cp "$sshd_main" "$test_main"
            printf '\nInclude %s\n' "$candidate" >> "$test_main"
            if err="$(sshd -t -f "$test_main" 2>&1)"; then
                log_info "sshd -t passed (candidate drop-in)"
                return 0
            fi
            log_error "sshd -t failed for candidate drop-in $candidate:"
            ;;
        main)
            if err="$(sshd -t -f "$candidate" 2>&1)"; then
                log_info "sshd -t passed (candidate main config)"
                return 0
            fi
            log_error "sshd -t failed for candidate main config $candidate:"
            ;;
        *)
            log_error "_sshd_validate: unknown kind: $kind"
            return 1
            ;;
    esac
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    return 4
}

# =============================================================================
# Main
# =============================================================================
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "$PROG_NAME must run as root (try: sudo $0 ...)"
        exit 2
    fi
}

main() {
    # Side-effect-free early exits. `--version` and `--help` must NOT
    # source /etc/motd.conf or emit any log lines other than their own
    # output — they are pure introspection flags. If we let them fall
    # through to the full arg-parse below, the config pre-load in
    # step 1 would run first and emit `[info] loading config from ...`
    # before the version string, which is noisy and could mask real
    # errors when /etc/motd.conf is malformed.
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s\n' "$PROG_NAME" "$MOTD_VERSION"
                exit 0
                ;;
        esac
    done

    # Two-pass argument handling:
    #
    #   1. Pre-scan for --config / --config=PATH so we know which file to
    #      load BEFORE applying CLI flags on top.
    #   2. load_config populates variables respecting env_set_* markers
    #      (env > config).
    #   3. parse_args runs the full flag handler and overwrites freely,
    #      giving CLI > env > config > defaults.
    local next_is_config=false arg_config=""
    for arg in "$@"; do
        if $next_is_config; then
            arg_config="$arg"; next_is_config=false
            continue
        fi
        case "$arg" in
            --config)    next_is_config=true ;;
            --config=*)  arg_config="${arg#*=}" ;;
        esac
    done

    if [[ -n "$arg_config" ]]; then
        # Explicit --config: the operator asked for THIS file. A missing
        # file is a fatal configuration error — falling through to
        # defaults would silently misconfigure a fleet.
        CONFIG_FILE="$arg_config"
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "config file not found: $CONFIG_FILE"
            log_hint "drop --config to use /etc/motd.conf (if present) or built-in defaults"
            exit 3
        fi
        load_config "$CONFIG_FILE"
    elif [[ -z "$CONFIG_FILE" ]] && [[ -f /etc/motd.conf ]]; then
        # Auto-discovered /etc/motd.conf — always allowed to be absent.
        CONFIG_FILE=/etc/motd.conf
        load_config "$CONFIG_FILE"
    elif [[ -n "$CONFIG_FILE" ]]; then
        # CONFIG_FILE came from an environment variable. Treat missing as
        # soft-miss (same lenient shape load_config has always had for
        # the non-explicit path).
        load_config "$CONFIG_FILE"
    fi

    parse_args "$@"

    # Translate the persistence scalar into the array IF the CLI did
    # not already populate it (CLI > env/config precedence). Must run
    # between parse_args and validate_config so per-line validation
    # sees the final set of override lines, regardless of source.
    _split_warning_lines_override

    # --uninstall short-circuits into the sibling script.
    #
    # Forward every path-shaped variable we resolved from CLI/env/config:
    # without this forwarding a user who installed with
    # `--motd-script-path /opt/motd/10-sysinfo.sh --sshd-dropin ...`
    # and then ran `install.sh --uninstall` would see the uninstaller
    # default back to /etc/update-motd.d/10-system-info and completely
    # miss the real files on disk. Also switched the `&& … || true`
    # flag forwarding to an explicit `if` — `&& true || true` in `set
    # -e` scripts was a latent Boolean-coercion bug.
    if $UNINSTALL; then
        local self_dir
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        if [[ ! -x "${self_dir}/uninstall.sh" ]]; then
            log_error "uninstall.sh not found next to install.sh"
            exit 4
        fi
        log_info "handing off to ${self_dir}/uninstall.sh"
        local -a uninst_args=(
            --backup-dir       "$BACKUP_DIR"
            --motd-script-path "$MOTD_SCRIPT_PATH"
            --motd-config-path "$MOTD_CONFIG_PATH"
            --motd-cache-dir   "$MOTD_CACHE_DIR"
            --sshd-dropin      "$SSHD_BANNER_DROPIN"
        )
        if [[ "$DRY_RUN" == "true" ]]; then
            uninst_args+=(--dry-run)
        fi
        # `--force` is intentionally not forwarded: uninstall.sh has
        # no interactive prompts and nothing to force. install.sh
        # still honours --force locally (it permits overwriting
        # managed files when --no-backup is set).
        exec "${self_dir}/uninstall.sh" "${uninst_args[@]}"
    fi

    if ! $DRY_RUN; then
        require_root
    fi

    validate_config
    detect_distro

    # Phase order is load-bearing: banner first because the sshd drop-in
    # references /etc/issue.net and that file must exist before sshd -t
    # is run.
    phase_banner
    phase_motd
    phase_sshd

    log_info "done."
}

main "$@"
