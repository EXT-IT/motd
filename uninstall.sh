#!/usr/bin/env bash
# =============================================================================
# motd — uninstaller
# -----------------------------------------------------------------------------
# Reverses every change install.sh might have made:
#
#   1. Banner phase
#      - restore /etc/issue and /etc/issue.net from BACKUP_DIR (or leave
#        them in place if no backup exists — the system needs /etc/issue
#        to exist, and silently deleting it is worse than the warning
#        being stale)
#      - restore /etc/motd from backup if one exists
#
#   2. MOTD phase
#      - restore /etc/update-motd.d/10-system-info from backup, or remove
#        the file if no backup exists
#      - restore /etc/motd.conf from backup, or remove if no backup
#      - leave /var/cache/motd/ alone by default (it may contain marker
#        files from other systems); --purge removes it
#
#   3. sshd phase
#      - remove /etc/ssh/sshd_config.d/99-motd-banner.conf if present
#      - if the installer appended a managed block to /etc/ssh/sshd_config,
#        strip the managed block (between the marker comments)
#      - validate the result with `sshd -t`
#      - reload sshd
#
# All restores happen via temp-file + rename so an interrupted uninstall
# never leaves a half-written config.
#
# License : Apache-2.0
# Copyright: (c) 2026 EXT IT GmbH
# Homepage : https://github.com/EXT-IT/motd
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# See install.sh for the rationale on capturing locale -a into a variable
# before the grep — bash 3.2 + pipefail + SIGPIPE propagation bug.
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

# See install.sh for why this is NOT named `VERSION`: every modern
# Linux distro's /etc/os-release defines a `VERSION=` line. A
# readonly VERSION here would propagate into any subshell that
# sources /etc/os-release and fail silently under `set -e`.
readonly MOTD_VERSION="1.0.0"
readonly PROG_NAME="motd-uninstall"
readonly PROJECT_URL="https://github.com/EXT-IT/motd"

# Match the install-side defaults — operators expect uninstall to clean
# up wherever install put things.
BACKUP_DIR="${BACKUP_DIR:-/var/backups/motd}"
MOTD_SCRIPT_PATH="${MOTD_SCRIPT_PATH:-/etc/update-motd.d/10-system-info}"
MOTD_CONFIG_PATH="${MOTD_CONFIG_PATH:-/etc/motd.conf}"
MOTD_CACHE_DIR="${MOTD_CACHE_DIR:-/var/cache/motd}"
SSHD_BANNER_DROPIN="${SSHD_BANNER_DROPIN:-/etc/ssh/sshd_config.d/99-motd-banner.conf}"
SSHD_RELOAD="${SSHD_RELOAD:-true}"

DRY_RUN=false
PURGE=false
# The cache dir is preserved by default (PURGE=false). `--keep-cache` is
# kept on the CLI as an explicit opt-in for symmetry with --purge, and
# to let operators write `--purge --keep-cache` and have the keep win.
# There is no separate state variable because nothing branches on it —
# the PURGE flag is the single source of truth.

# Same marker the installer uses when it has to append to sshd_config
# directly. Used to find the managed block on uninstall so we can strip
# only the lines we wrote.
readonly SSHD_APPEND_MARKER_START="# motd-banner: managed by ${PROJECT_URL} — do not edit"
readonly SSHD_APPEND_MARKER_END="# motd-banner: end managed by ${PROJECT_URL} — do not edit"

_use_color() { [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; }

log_info()  { printf '[info] %s\n' "$*" >&2; }
log_warn()  {
    if _use_color; then printf '\033[33m[warn]\033[0m %s\n' "$*" >&2
    else printf '[warn] %s\n' "$*" >&2
    fi
}
log_error() {
    if _use_color; then printf '\033[31m[error]\033[0m %s\n' "$*" >&2
    else printf '[error] %s\n' "$*" >&2
    fi
}
log_hint() {
    if _use_color; then printf '\033[36m[hint]\033[0m %s\n' "$*" >&2
    else printf '[hint] %s\n' "$*" >&2
    fi
}

usage() {
    cat <<'EOF'
motd uninstall — restore pre-installer state from backups

Usage:
  uninstall.sh [OPTIONS]

Options:
  --backup-dir DIR       Backup directory (default: /var/backups/motd)
  --motd-script-path P   Path to the installed MOTD script
                         (default: /etc/update-motd.d/10-system-info)
  --motd-config-path P   Path to the unified config (default: /etc/motd.conf)
  --motd-cache-dir DIR   Cache directory (default: /var/cache/motd)
  --sshd-dropin PATH     sshd drop-in path
                         (default: /etc/ssh/sshd_config.d/99-motd-banner.conf)
  --keep-cache           Preserve $MOTD_CACHE_DIR (default behaviour)
  --purge                Remove $MOTD_CACHE_DIR and the unified config file
                         even if no backup exists
  --no-sshd-reload       Do not reload sshd after restoring sshd_config
  -n, --dry-run          Print what would happen; make no changes
  -f, --force            Accepted for parity with install.sh; no-op here
                         (uninstall has no interactive prompts)
  -h, --help             Show this help and exit
      --version          Print version and exit

Behaviour:
  * For each managed file we look for <basename>.latest.bak in
    --backup-dir; if missing, we scan for the newest <basename>.*.bak
    instead.
  * If a backup exists and differs from the current file, restore it.
  * For files where no backup exists:
      - banner files (/etc/issue, /etc/issue.net) — left in place
      - MOTD script + unified config — removed
  * The cache directory is preserved unless --purge is given.
  * Any change to /etc/ssh/sshd_config.d/ or /etc/ssh/sshd_config is
    validated with `sshd -t` before sshd is reloaded.

Exit codes:
  0 success          1 usage error         2 permission/root error
  3 nothing to do    4 restore error
EOF
}

# -----------------------------------------------------------------------------
# Path validation (mirrors install.sh _validate_abs_path + _reject_shell_meta).
#
# Every path the uninstaller receives from the CLI ends up in `rm -f`,
# `mv -f`, or a grep/awk target. Without validation, a typo like
# `sudo uninstall.sh --sshd-dropin /etc/shadow` would rm the shadow file.
# Not an exploit (root CLI), but a sharp foot-gun and an inconsistency
# with the installer. Additionally, every path is gated by a prefix
# allowlist — the uninstaller has no legitimate need to touch anything
# outside its managed directories.
# -----------------------------------------------------------------------------
_validate_abs_path_var() {
    # $1 = variable name holding the path
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
    # Reject C0 control bytes (newline, CR, tab). Bash cannot even
    # store a NUL inside a shell variable — the assignment truncates
    # at the first \0 — so an explicit NUL check is unreachable and
    # has been dropped. printable/control classification uses the
    # POSIX character class [[:cntrl:]] which covers every C0 + DEL.
    case "$v" in
        *[[:cntrl:]]*)
            log_error "$var contains control characters — rejected"
            exit 3 ;;
    esac
    if [[ "$v" == *[[:space:]]* ]]; then
        log_error "$var must not contain whitespace, got: $v"
        exit 3
    fi
    # Shell metacharacters: $ ` " \ — rejected so the value can safely
    # embed in double-quoted contexts and in log lines.
    case "$v" in
        *\$*|*\`*|*\"*|*\\*)
            log_error "$var must not contain shell metacharacters (\$ \` \" \\)"
            exit 3 ;;
    esac
}

# Prefix allowlist: the uninstaller only touches paths that the installer
# could have created. Catches `--sshd-dropin /etc/shadow`-style mistakes
# before any rm/mv fires.
_validate_managed_prefix() {
    local var="$1" v
    v="${!var}"
    # Reject path-traversal segments and relative prefixes BEFORE the
    # allowlist check. The allowlist uses glob patterns like
    # /var/cache/motd* which happily match
    # /var/cache/motd/../../etc/shadow — so an operator typo on
    # `--sshd-dropin` could escape the allowlist entirely. Mirror of the
    # same fix in install.sh's _validate_managed_prefix: two copies of
    # the same function must never drift apart. Pure lexical reject,
    # no realpath dependency — see the install.sh copy for the full
    # rationale.
    case "$v" in
        */..|*/../*|*/./*|*/.|../*|./*)
            log_error "$var=$v contains a path-traversal segment (../ or ./)"
            log_hint "managed paths must be absolute and fully normalised"
            exit 3 ;;
    esac
    # Mirror of the install.sh fix. A naive trailing wildcard would match
    # sibling basenames like /var/cache/motdbackdoor because shell glob
    # `motd*` happily eats `motdbackdoor`. Anchoring on a path separator
    # (`<dir>` OR `<dir>/*`) restricts the allowlist to the literal
    # managed directory and its descendants.
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

parse_args() {
    # Normalise `--foo=bar` to `--foo bar`. See install.sh parse_args for
    # the rationale — mirror the same pre-processing so the two CLIs are
    # consistent.
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
            --backup-dir)
                if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                    log_error "missing value for --backup-dir"; exit 1
                fi
                BACKUP_DIR="$2"; shift 2 ;;
            --motd-script-path)
                if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                    log_error "missing value for --motd-script-path"; exit 1
                fi
                MOTD_SCRIPT_PATH="$2"; shift 2 ;;
            --motd-config-path)
                if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                    log_error "missing value for --motd-config-path"; exit 1
                fi
                MOTD_CONFIG_PATH="$2"; shift 2 ;;
            --motd-cache-dir)
                if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                    log_error "missing value for --motd-cache-dir"; exit 1
                fi
                MOTD_CACHE_DIR="$2"; shift 2 ;;
            --sshd-dropin)
                if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                    log_error "missing value for --sshd-dropin"; exit 1
                fi
                SSHD_BANNER_DROPIN="$2"; shift 2 ;;
            --keep-cache)     PURGE=false; shift ;;
            --purge)          PURGE=true;  shift ;;
            --no-sshd-reload) SSHD_RELOAD=false; shift ;;
            -n|--dry-run)     DRY_RUN=true;     shift ;;
            # --force is accepted for flag parity with install.sh. The
            # uninstaller has no interactive prompts, so the flag is a
            # documented no-op; it exists so automation that passes
            # `--force` to both sides does not fail on this one.
            -f|--force)       shift ;;
            -h|--help)        usage; exit 0 ;;
            --version)        printf '%s %s\n' "$PROG_NAME" "$MOTD_VERSION"; exit 0 ;;
            --) shift; break ;;
            -*) log_error "unknown option: $1"; exit 1 ;;
            *)  log_error "unexpected positional argument: $1"; exit 1 ;;
        esac
    done

    # Post-parse validation: every path the uninstaller might touch must
    # be syntactically safe AND live under an allowlisted prefix.
    _validate_abs_path_var BACKUP_DIR
    _validate_abs_path_var MOTD_SCRIPT_PATH
    _validate_abs_path_var MOTD_CONFIG_PATH
    _validate_abs_path_var MOTD_CACHE_DIR
    _validate_abs_path_var SSHD_BANNER_DROPIN

    _validate_managed_prefix BACKUP_DIR
    _validate_managed_prefix MOTD_SCRIPT_PATH
    _validate_managed_prefix MOTD_CONFIG_PATH
    _validate_managed_prefix MOTD_CACHE_DIR
    _validate_managed_prefix SSHD_BANNER_DROPIN
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "$PROG_NAME must run as root (try: sudo $0 ...)"
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# Backup discovery
# -----------------------------------------------------------------------------
find_latest_backup() {
    local base="$1"
    local latest="${BACKUP_DIR}/${base}.latest.bak"

    # Follow .latest.bak exactly ONE level. We deliberately avoid
    # `readlink -f` here because the backup target itself may be a
    # preserved symlink (e.g. /etc/motd -> /run/motd.dynamic captured
    # via `cp -P`). `readlink -f` would walk through the preserved
    # link as well and return the link destination as a regular file,
    # which would break atomic_replace's symlink branch and restore a
    # snapshot of /run/motd.dynamic content instead of rebuilding the
    # original symlink.
    if [[ -L "$latest" ]]; then
        local link_target target
        link_target="$(readlink "$latest" 2>/dev/null)" || return 1
        case "$link_target" in
            /*) target="$link_target" ;;
            *)  target="${BACKUP_DIR}/${link_target}" ;;
        esac
        if [[ -e "$target" ]] || [[ -L "$target" ]]; then
            printf '%s\n' "$target"
            return 0
        fi
    elif [[ -f "$latest" ]]; then
        printf '%s\n' "$latest"
        return 0
    fi

    # Pristine fallback: operator manually removed latest.bak, or the
    # symlink is dangling. The pristine artefact is the authoritative
    # pre-install state (install.sh writes it exactly once per file).
    local pristine="${BACKUP_DIR}/${base}.pristine.bak"
    if [[ -e "$pristine" ]] || [[ -L "$pristine" ]]; then
        printf '%s\n' "$pristine"
        return 0
    fi

    # Legacy fallback: newest matching timestamped backup by mtime.
    # Retained for compatibility with backups created before the
    # pristine scheme was introduced.
    #
    # IMPORTANT — the glob is `${base}.[0-9]*.bak`, NOT `${base}.*.bak`.
    # The looser form matches anything that starts with `${base}.` plus
    # arbitrary tail, which collides across prefix-sharing basenames:
    #
    #   base=motd
    #   files on disk:
    #     motd.20260101T125239Z.bak             (correct — /etc/motd backup)
    #     motd.conf.20260101T125311Z.bak        (wrong — /etc/motd.conf backup)
    #
    # With `motd.*.bak`, the glob matches BOTH, picks whichever is newer,
    # and happily restores motd.conf content into /etc/motd. pam_motd then
    # dumps the shell-config file into every SSH login. The tight glob
    # `motd.[0-9]*.bak` requires the first char after the dot to be a
    # digit; since install.sh timestamps start with `2` (year 2000+) and
    # no legitimate basename variant like `motd.conf` starts with a digit,
    # the two are strictly separated. `.pristine.bak` also never matches
    # because the first char after the dot is 'p'.
    local candidate best=""
    shopt -s nullglob
    for candidate in "${BACKUP_DIR}/${base}".[0-9]*.bak; do
        [[ -e "$candidate" ]] || [[ -L "$candidate" ]] || continue
        [[ "$candidate" == *".latest.bak" ]] && continue
        if [[ -z "$best" ]] || [[ "$candidate" -nt "$best" ]]; then
            best="$candidate"
        fi
    done
    shopt -u nullglob

    if [[ -n "$best" ]]; then
        printf '%s\n' "$best"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Atomic file ops (kept symmetrical with install.sh)
# -----------------------------------------------------------------------------
atomic_replace() {
    # $1 = src (existing readable file OR symlink), $2 = target path, [$3 = mode]
    #
    # Symlink-safe: install.sh's backup_file preserves symlinks via `cp -P`
    # (needed for /etc/motd -> /run/motd.dynamic on Debian/Ubuntu). Restore
    # must respect the link type or the "uninstalled" /etc/motd would be a
    # regular file containing a moment-in-time snapshot of the pam_motd
    # dynamic output — which is not the pre-install state. Detect the
    # symlink up front and rebuild the link atomically via mktemp + ln -sfn
    # + mv. chmod/chown on a symlink only affects the target on Linux, so
    # we deliberately skip them for the link branch.
    local src="$1" target="$2" mode="${3:-0644}"
    local dir tmp
    dir="$(dirname "$target")"

    if [[ -L "$src" ]]; then
        local link_target
        link_target="$(readlink "$src")" || {
            log_error "readlink failed on $src"; exit 4
        }
        tmp="$(mktemp -u "${dir}/.${PROG_NAME}.XXXXXXXX")" || {
            log_error "failed to mktemp name in $dir"; exit 4
        }
        ln -sfn "$link_target" "$tmp" || {
            log_error "ln -sfn failed: $tmp -> $link_target"; exit 4
        }
        # shellcheck disable=SC2064
        trap "rm -f '$tmp'" EXIT
        mv -f "$tmp" "$target" || {
            log_error "mv failed: $tmp -> $target"; exit 4
        }
        trap - EXIT
        log_info "restored symlink $target -> $link_target"
        return 0
    fi

    tmp="$(mktemp "${dir}/.${PROG_NAME}.XXXXXXXX")" || {
        log_error "failed to create tempfile in $dir"; exit 4
    }
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    cp -p "$src" "$tmp" || { log_error "cp failed: $src -> $tmp"; exit 4; }
    chmod "$mode" "$tmp" || { log_error "chmod failed on $tmp"; exit 4; }
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target" || { log_error "mv failed: $tmp -> $target"; exit 4; }
    trap - EXIT
}

# -----------------------------------------------------------------------------
# restore_or_remove: restore $1 from backup if a backup exists. If
# `$2 == remove-when-missing`, remove the target file when no backup is
# found. Otherwise leave it in place with a warning.
#
# motd-created files are tracked via a `<base>.created` marker in
# BACKUP_DIR. The marker is written by install.sh on the very first
# backup_file() call whose target does not yet exist (i.e. we are
# creating the file from nothing, not backing up an operator artefact).
# On uninstall, the marker takes precedence over "leave in place":
# a file we created must be REMOVED, regardless of whether the caller
# passed `remove-when-missing`. Without this, the uninstaller would
# either restore a misleading pristine snapshot (if a second install
# ran in between) or leave our own output in place ("no backup found
# — leaving file alone"), neither of which matches the pre-install
# state. The marker is deleted on successful removal so a re-run is
# a clean no-op.
# -----------------------------------------------------------------------------
restore_or_remove() {
    local target="$1" missing_action="${2:-leave}"
    local base
    base="$(basename "$target")"

    local created_marker="${BACKUP_DIR}/${base}.created"

    # motd-created: remove the file and the marker, regardless of
    # missing_action. This path is taken even when a pristine backup
    # from some earlier install cycle still exists on disk — the marker
    # is the authoritative signal that THIS installation of the file
    # came from nothing.
    if [[ -e "$created_marker" ]]; then
        if [[ -f "$target" ]] || [[ -L "$target" ]]; then
            if $DRY_RUN; then
                log_info "[dry-run] would remove $target (motd-created, marker present)"
            else
                rm -f "$target"
                log_info "removed $target (motd-created)"
            fi
        fi
        if ! $DRY_RUN; then
            rm -f "$created_marker"
        fi
        return 0
    fi

    local backup
    if ! backup="$(find_latest_backup "$base")"; then
        case "$missing_action" in
            remove-when-missing)
                if [[ -f "$target" ]]; then
                    if $DRY_RUN; then
                        log_info "[dry-run] would remove $target (no backup)"
                    else
                        rm -f "$target"
                        log_info "removed $target (no backup found)"
                    fi
                fi
                ;;
            *)
                if [[ -f "$target" ]]; then
                    log_warn "no backup found for $target — leaving file alone"
                fi
                ;;
        esac
        return 0
    fi

    if [[ -f "$target" ]] && cmp -s "$backup" "$target"; then
        log_info "$target already matches backup — no change"
        return 0
    fi

    if $DRY_RUN; then
        log_info "[dry-run] would restore $target from $backup"
        return 0
    fi

    atomic_replace "$backup" "$target"
    log_info "restored $target from $backup"
}

# -----------------------------------------------------------------------------
# Phase 1 — banner restore
# -----------------------------------------------------------------------------
phase_banner() {
    log_info "banner phase: restoring"
    restore_or_remove /etc/issue
    restore_or_remove /etc/issue.net
    restore_or_remove /etc/motd
}

# -----------------------------------------------------------------------------
# Restore the Ubuntu default update-motd.d scripts that install.sh
# disabled. The list of paths install.sh touched is recorded in
# $BACKUP_DIR/update-motd.d.disabled.list; entries come in two shapes:
#
#   1. Plain path:   /etc/update-motd.d/00-header
#      → restored via chmod +x (the file content was never touched)
#
#   2. Symlink record: symlink:/etc/update-motd.d/50-landscape-sysinfo:/usr/share/landscape/landscape-sysinfo.wrapper
#      → install.sh replaces a package-symlink with an empty 0644 stub
#        instead of leaving the package-managed target executable. The
#        original symlink target is captured at install time, and
#        uninstall recreates the symlink byte-identical to the upstream
#        layout via `ln -sf <target> <path>`. Empty stub is removed
#        first.
#
# Legacy compatibility: a list left behind by an older install without
# symlink handling will never contain a `symlink:` entry, so the new
# branch is a no-op for old layouts.
#
# Missing list file = nothing to do (either install.sh never ran on this
# host, or the list was purged). That's benign; we just log a hint.
# -----------------------------------------------------------------------------
_restore_ubuntu_motd_defaults() {
    local disabled_list="${BACKUP_DIR}/update-motd.d.disabled.list"
    if [[ ! -f "$disabled_list" ]]; then
        log_info "no update-motd.d disabled list at $disabled_list — nothing to restore"
        return 0
    fi

    local entry restored=0 missing=0 relinked=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        # Symlink record? Format: symlink:<path>:<original_target>
        if [[ "$entry" == symlink:* ]]; then
            # Strip the `symlink:` prefix; everything after the first
            # colon is the path, then a colon, then the target. Use
            # parameter expansion so we don't need cut/sed.
            local rest="${entry#symlink:}"
            local link_path="${rest%%:*}"
            local link_target="${rest#*:}"
            if [[ -z "$link_path" ]] || [[ -z "$link_target" ]] || [[ "$link_path" == "$link_target" ]]; then
                log_warn "malformed symlink record in $disabled_list: $entry"
                continue
            fi
            if [[ -L "$link_path" ]]; then
                # Already a symlink — maybe a package upgrade already
                # restored it. Trust it and move on.
                continue
            fi
            if $DRY_RUN; then
                log_info "[dry-run] would restore symlink $link_path -> $link_target"
                relinked=$((relinked + 1))
                continue
            fi
            # Remove the empty stub install.sh dropped, then ln -sf.
            # `-f` replaces an existing target atomically; covers the
            # rare case where an operator wrote a regular file there
            # between install and uninstall.
            rm -f "$link_path" 2>/dev/null || true
            if ln -sf "$link_target" "$link_path" 2>/dev/null; then
                log_info "restored symlink $link_path -> $link_target"
                relinked=$((relinked + 1))
            else
                log_warn "could not restore symlink $link_path -> $link_target"
            fi
            continue
        fi

        # Plain path: chmod +x restore.
        local path="$entry"
        if [[ -L "$path" ]]; then
            log_warn "skipping symlink $path from disabled list (legacy entry — refusing to chmod through a symlink)"
            continue
        fi
        if [[ ! -f "$path" ]]; then
            missing=$((missing + 1))
            continue
        fi
        if [[ -x "$path" ]]; then
            # Already executable — maybe a package upgrade already put the
            # bit back. Nothing to do.
            continue
        fi
        if $DRY_RUN; then
            log_info "[dry-run] would chmod +x $path"
        else
            chmod 0755 "$path" 2>/dev/null || {
                log_warn "could not restore +x on $path"
                continue
            }
            log_info "restored +x on $path"
        fi
        restored=$((restored + 1))
    done < "$disabled_list"

    if [[ "$missing" -gt 0 ]]; then
        log_warn "$missing entry(ies) in $disabled_list no longer exist on disk"
    fi
    if [[ "$restored" -eq 0 ]] && [[ "$relinked" -eq 0 ]]; then
        log_info "no Ubuntu default update-motd.d scripts needed restoring"
    fi

    # Remove the list file itself on non-dry-run so re-running the
    # uninstaller is a clean no-op. Keep it in dry-run mode so the
    # operator can inspect it.
    if ! $DRY_RUN; then
        rm -f "$disabled_list" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Phase 2 — MOTD removal
# -----------------------------------------------------------------------------
phase_motd() {
    log_info "motd phase: removing"

    # MOTD script: restore from backup, otherwise remove. The script is
    # ours; deleting it on uninstall is the right move when no backup
    # exists (the system was banner-less before we touched it).
    restore_or_remove "$MOTD_SCRIPT_PATH" remove-when-missing

    # Unified config file: same logic. Even with --keep-cache the config
    # itself is removed when no backup exists, because it's only ever
    # written by us; the cache *directory* is the thing we preserve.
    restore_or_remove "$MOTD_CONFIG_PATH" remove-when-missing

    # Profile.d wrapper: the installer deploys /etc/profile.d/zz-motd.sh
    # to render the coloured MOTD at interactive login (bypassing pam_motd
    # caching). Remove it on uninstall via restore_or_remove so the
    # backup/marker logic is consistent with all other managed files.
    restore_or_remove /etc/profile.d/zz-motd.sh remove-when-missing

    # Restore the executable bit on any Ubuntu default update-motd.d
    # scripts that install.sh disabled. Without this step an uninstall
    # would leave the host with a blank dynamic MOTD (all scripts
    # chmod'd -x and our 10-system-info removed) — a worse state than
    # before we touched it.
    _restore_ubuntu_motd_defaults

    # Cache directory: default behaviour is to preserve. --purge removes
    # it; otherwise we just print a hint so the operator knows it's there.
    if $PURGE; then
        if [[ -d "$MOTD_CACHE_DIR" ]]; then
            if $DRY_RUN; then
                log_info "[dry-run] would remove $MOTD_CACHE_DIR (--purge)"
            else
                rm -rf "$MOTD_CACHE_DIR"
                log_info "removed $MOTD_CACHE_DIR"
            fi
        fi
    else
        if [[ -d "$MOTD_CACHE_DIR" ]]; then
            log_hint "$MOTD_CACHE_DIR preserved (use --purge to remove)"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Phase 3 — sshd cleanup
# -----------------------------------------------------------------------------
phase_sshd() {
    log_info "sshd phase: cleaning up"

    local sshd_main=/etc/ssh/sshd_config
    local touched=false

    # 3a. Drop-in file: route through restore_or_remove so the
    # `<basename>.created` marker (written by install.sh's backup_file()
    # on first install when the drop-in path did not previously exist)
    # is cleaned up as part of the same code path that handles the
    # banner and MOTD files. A direct `rm -f "$SSHD_BANNER_DROPIN"`
    # would remove the file on disk but leave the marker as an orphan
    # in $BACKUP_DIR, so a fresh `install.sh && uninstall.sh` cycle
    # would never return $BACKUP_DIR to a clean state.
    #
    # restore_or_remove also picks up the rarer "operator had a
    # pre-existing drop-in at this path" case: backup_file would have
    # captured it as `<basename>.pristine.bak`, and the helper will
    # restore it verbatim instead of silently destroying it the way
    # a blind `rm -f` did.
    #
    # `touched` drives the subsequent sshd reload. We detect a change
    # by comparing sha256 before/after — any outcome that modifies the
    # file (rm, restore-to-different-content) reloads sshd. Idempotent
    # runs (cmp-equal restore, file already absent + marker absent)
    # leave sha unchanged and skip the reload. Fork cost is negligible
    # at uninstall time (this is not a hot path).
    local _dropin_sha_before=""
    if [[ -f "$SSHD_BANNER_DROPIN" ]]; then
        _dropin_sha_before="$(sha256sum "$SSHD_BANNER_DROPIN" 2>/dev/null | awk '{print $1}')"
    fi

    # Refuse to touch a drop-in path that is not ours. Without this
    # guard, `restore_or_remove` under `remove-when-missing` semantics
    # would happily `rm -f` any file at the path even when no backup
    # exists — turning an operator typo on `--sshd-dropin` into a
    # destructive action against unrelated cloud-init / distro drop-ins.
    #
    # Three signals tell us the file is genuinely managed by motd:
    #   1. content carries the `# Managed by motd` marker (normal case)
    #   2. a `<base>.created` marker exists in BACKUP_DIR (we wrote the
    #      file from nothing on first install)
    #   3. a `<base>.pristine.bak` exists in BACKUP_DIR (we captured an
    #      operator artefact and replaced it with our content)
    # Any of those is sufficient. None of them = the file is foreign and
    # we leave it alone with a clear log line.
    local _dropin_base
    _dropin_base="$(basename "$SSHD_BANNER_DROPIN")"
    local _dropin_marker="${BACKUP_DIR}/${_dropin_base}.created"
    local _dropin_pristine="${BACKUP_DIR}/${_dropin_base}.pristine.bak"
    local _dropin_managed=false
    if [[ -e "$_dropin_marker" ]] || [[ -e "$_dropin_pristine" ]] || [[ -L "$_dropin_pristine" ]]; then
        _dropin_managed=true
    elif [[ -f "$SSHD_BANNER_DROPIN" ]] \
         && grep -qF "# Managed by motd" "$SSHD_BANNER_DROPIN" 2>/dev/null; then
        _dropin_managed=true
    fi

    if $_dropin_managed; then
        restore_or_remove "$SSHD_BANNER_DROPIN" remove-when-missing
    elif [[ -f "$SSHD_BANNER_DROPIN" ]]; then
        log_warn "$SSHD_BANNER_DROPIN exists but is not managed by motd"
        log_hint "no managed marker, no pristine backup, and no managed-by-motd content header"
        log_hint "leaving the file alone — inspect manually if you intended to manage it via --sshd-dropin"
    else
        # Emit an explicit "skipped" log so the operator can tell "we
        # looked and it wasn't there" apart from "we never looked at
        # this path".
        log_info "skipped $SSHD_BANNER_DROPIN (not present, no marker)"
    fi

    local _dropin_sha_after=""
    if [[ -f "$SSHD_BANNER_DROPIN" ]]; then
        _dropin_sha_after="$(sha256sum "$SSHD_BANNER_DROPIN" 2>/dev/null | awk '{print $1}')"
    fi

    if [[ "$_dropin_sha_before" != "$_dropin_sha_after" ]] && ! $DRY_RUN; then
        touched=true
    fi

    # 3b. Appended block in main sshd_config (only present if the
    # installer's drop-in path was unavailable). Strip ONLY the lines
    # between our marker comments — never touch anything else in the
    # file.
    #
    # Both markers required: the awk strip loop below never resets
    # skip=1 if the end marker is absent, so it would eat every line
    # from the start marker to EOF. This happens if the installer was
    # SIGKILLed between writing the start marker and the end marker
    # (half-written install). Refuse up front with a clear hint —
    # better to leave a half-written sshd_config for human inspection
    # than to silently truncate it.
    if [[ -f "$sshd_main" ]] && grep -qF "$SSHD_APPEND_MARKER_START" "$sshd_main" 2>/dev/null; then
        if ! grep -qF "$SSHD_APPEND_MARKER_END" "$sshd_main" 2>/dev/null; then
            log_error "$sshd_main has motd start marker but no end marker"
            log_error "this looks like a half-written install (installer killed mid-write)"
            log_hint  "inspect $sshd_main manually and remove the managed block between these lines:"
            log_hint  "  start: $SSHD_APPEND_MARKER_START"
            log_hint  "  end:   $SSHD_APPEND_MARKER_END"
            log_hint  "uninstall.sh refuses to strip because awk would eat from start marker to EOF"
            exit 4
        fi
        if $DRY_RUN; then
            log_info "[dry-run] would strip managed block from $sshd_main"
        else
            local dir tmp
            dir="$(dirname "$sshd_main")"
            tmp="$(mktemp "${dir}/.${PROG_NAME}.XXXXXXXX")" || {
                log_error "failed to create tempfile in $dir"; exit 4
            }
            # shellcheck disable=SC2064
            trap "rm -f '$tmp'" EXIT
            # One-line lookback so we can eat the blank separator the
            # installer writes immediately BEFORE the start marker. The
            # old awk output would leave that blank behind, and N
            # install→uninstall cycles would accumulate N blanks at the
            # end of sshd_config — not fatal, but violates idempotency.
            # The lookback is: hold each line in `prev`, only print it
            # when the next line demands flushing; when we hit the start
            # marker, drop `prev` if it was blank.
            awk -v start="$SSHD_APPEND_MARKER_START" -v end="$SSHD_APPEND_MARKER_END" '
                {
                    if (index($0, start)) {
                        if (pending && prev == "") { pending = 0 }
                        skip = 1
                        next
                    }
                    if (skip && index($0, end)) { skip = 0; next }
                    if (skip) next
                    if (pending) print prev
                    prev = $0
                    pending = 1
                }
                END { if (pending) print prev }
            ' "$sshd_main" > "$tmp"
            chmod --reference="$sshd_main" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
            chown --reference="$sshd_main" "$tmp" 2>/dev/null || chown root:root "$tmp" 2>/dev/null || true

            # Validate the stripped candidate BEFORE it becomes live.
            # sshd -t -f <candidate> tests the tempfile in isolation —
            # if the strip produced an invalid file (malformed Include
            # context, unexpected end-of-block token, encoding issue),
            # we catch it here and leave the live sshd_config alone.
            # Without this check a broken strip + in-place mv would
            # leave sshd unable to start on the next reload. Mirrors
            # install.sh's _sshd_validate_main_config.
            if command -v sshd >/dev/null 2>&1; then
                local _err
                if ! _err="$(sshd -t -f "$tmp" 2>&1)"; then
                    log_error "sshd -t failed on uninstall candidate — leaving live config alone"
                    printf '%s\n' "$_err" | sed 's/^/    /' >&2
                    rm -f "$tmp"
                    trap - EXIT
                    exit 4
                fi
                log_info "sshd -t passed (uninstall candidate)"
            else
                log_warn "sshd binary not in PATH — skipping candidate validation"
            fi

            mv -f "$tmp" "$sshd_main"
            trap - EXIT
            log_info "stripped managed block from $sshd_main"
            touched=true
        fi
    fi

    # 3c. Validate + reload only if we changed something. Validation
    # failure is fatal — we never leave a host with a broken sshd.
    if $touched && ! $DRY_RUN; then
        if command -v sshd >/dev/null 2>&1; then
            local err
            if err="$(sshd -t 2>&1)"; then
                log_info "sshd -t passed"
            else
                log_error "sshd -t failed after cleanup:"
                printf '%s\n' "$err" >&2
                log_error "manual intervention required — uninstall.sh will NOT continue"
                exit 4
            fi
        else
            log_warn "sshd binary not in PATH — skipping syntactic validation"
        fi
        # Propagate reload_sshd's exit code. `reload_sshd` returns 4 on
        # systemctl failure (install.sh parity). Without an explicit
        # check, `set -e` would kill the script silently; we log the
        # exit path first so CI runners see a clear error line tying
        # the failure back to the reload phase, then exit with the
        # same code.
        local _reload_rc=0
        reload_sshd || _reload_rc=$?
        if (( _reload_rc != 0 )); then
            log_error "sshd reload failed during uninstall — leaving live daemon untouched"
            exit "$_reload_rc"
        fi
    fi
}

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

    [[ -z "$unit" ]] && { log_info "sshd not active; skipping reload"; return 0; }

    # Parity with install.sh's reload path. Log loudly on failure and
    # exit non-zero so automation can tell that the old banner may
    # still be live in the running daemon even though the stripped
    # drop-in is valid on disk (sshd -t passed a few lines earlier).
    # Exit code 4 = restore error, same code phase_sshd() uses for
    # other fatal reload-path failures.
    if systemctl reload "$unit" 2>/dev/null; then
        log_info "reloaded ${unit}.service"
        return 0
    fi
    log_error "failed to reload ${unit}.service — old banner may still be live"
    log_hint  "run manually: systemctl reload $unit"
    return 4
}

main() {
    parse_args "$@"
    $DRY_RUN || require_root

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "backup directory does not exist: $BACKUP_DIR"
        log_warn "banner files will be left in place; MOTD/sshd files removed if found"
    fi

    phase_banner
    phase_motd
    phase_sshd

    log_info "done."
}

main "$@"
