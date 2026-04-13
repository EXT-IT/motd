#!/usr/bin/env bash
# =============================================================================
# tests/test_pubip_optout.sh — verify MOTD_PUBIP_URL="" disables the probe
# -----------------------------------------------------------------------------
# motd.conf.example documents that setting MOTD_PUBIP_URL="" disables the
# public-IP probe entirely while keeping MOTD_VERBOSE=true intact (kernel
# version still rendered, no curl spawn, no DNS lookup, no third-party
# call). This guarantee was broken by the original Option-C commit
# (01b5f3b) because the defaulting line used `${VAR:-default}` (replaces
# unset OR empty) instead of `${VAR-default}` (replaces only unset),
# silently re-arming the default before the runtime guard could fire.
#
# This regression test asserts the contract on three layers:
#   1. install.sh persists explicit "" into the rendered /etc/motd.conf
#   2. install.sh writes the documented default when MOTD_PUBIP_URL is unset
#   3. The defaulting line in motd/10-system-info.sh preserves explicit ""
#
# Black-box: drives install.sh --dry-run and extracts the runtime
# defaulting line from motd/10-system-info.sh by grep — the test thus
# tracks the actual source file, not a hand-copied snippet.
#
# Usage: bash tests/test_pubip_optout.sh    (from repo root)
# Exit:  0 = all pass, 1 = at least one regression
# =============================================================================

set -u
IFS=$'\n\t'

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$_here/.."
_installer="$_root/install.sh"
_runtime="$_root/motd/10-system-info.sh"

if [[ ! -x "$_installer" ]]; then
    echo "FAIL: install.sh not found or not executable at $_installer" >&2
    exit 1
fi
if [[ ! -r "$_runtime" ]]; then
    echo "FAIL: 10-system-info.sh not readable at $_runtime" >&2
    exit 1
fi

_pass=0
_fail=0
_total=0

_assert_eq() {
    local label="$1" expected="$2" actual="$3"
    _total=$((_total + 1))
    if [[ "$actual" == "$expected" ]]; then
        printf "  PASS  %s\n" "$label"
        _pass=$((_pass + 1))
    else
        printf "  FAIL  %s\n" "$label" >&2
        printf "        expected: %s\n" "$expected" >&2
        printf "        actual:   %s\n" "$actual" >&2
        _fail=$((_fail + 1))
    fi
}

echo "MOTD_PUBIP_URL opt-out regression suite"
echo "======================================="
echo

# --- Layer 1: install.sh preserves explicit empty value ---
echo "Layer 1: install.sh --dry-run with MOTD_PUBIP_URL=\"\""
rendered=$(MOTD_PUBIP_URL="" "$_installer" --dry-run 2>&1 | grep -E '^MOTD_PUBIP_URL=' | head -1)
_assert_eq "install.sh persists empty value into rendered config" \
    'MOTD_PUBIP_URL=""' "$rendered"

# --- Layer 2: install.sh applies default when unset ---
echo
echo "Layer 2: install.sh --dry-run with MOTD_PUBIP_URL unset"
rendered=$(unset MOTD_PUBIP_URL; "$_installer" --dry-run 2>&1 | grep -E '^MOTD_PUBIP_URL=' | head -1)
_assert_eq "install.sh applies default when variable is unset" \
    'MOTD_PUBIP_URL="https://ifconfig.me"' "$rendered"

# --- Layer 3: runtime defaulting line preserves explicit empty ---
# Extract the MOTD_PUBIP_URL= defaulting line from the actual source so
# the test follows the file rather than a hand-copied snippet.
echo
echo "Layer 3: motd/10-system-info.sh defaulting line preserves \"\""
defaulting_line=$(grep -E '^MOTD_PUBIP_URL=' "$_runtime" | head -1)
if [[ -z "$defaulting_line" ]]; then
    echo "  SKIP  could not locate MOTD_PUBIP_URL= line in $_runtime" >&2
    _total=$((_total + 1)); _fail=$((_fail + 1))
else
    # Run the extracted line in a clean subshell with explicit empty env.
    result=$(MOTD_PUBIP_URL="" bash -c "$defaulting_line; printf '[%s]' \"\$MOTD_PUBIP_URL\"")
    _assert_eq "runtime line keeps explicit empty (no :- substitution)" \
        '[]' "$result"

    # And the same line applies the default when unset.
    result=$(unset MOTD_PUBIP_URL; bash -c "$defaulting_line; printf '[%s]' \"\$MOTD_PUBIP_URL\"")
    _assert_eq "runtime line applies default when unset" \
        '[https://ifconfig.me]' "$result"
fi

# --- Layer 4: the smoking-gun bash-semantics test ---
# Documents the operator-developer contract: ${VAR-X} differs from
# ${VAR:-X}. If a future refactor accidentally adds the colon back,
# this test makes the breakage visible at the semantic level, not just
# at the integration level above.
echo
echo "Layer 4: bash semantics contract for \${VAR-default} vs \${VAR:-default}"
result=$(MOTD_PUBIP_URL="" bash -c 'echo "[${MOTD_PUBIP_URL-default}]"')
_assert_eq "\${VAR-default} preserves explicit empty" '[]' "$result"
result=$(MOTD_PUBIP_URL="" bash -c 'echo "[${MOTD_PUBIP_URL:-default}]"')
_assert_eq "\${VAR:-default} replaces empty (this is why we use the no-colon form)" \
    '[default]' "$result"

echo
echo "======================================="
printf "Total: %d   Pass: %d   Fail: %d\n" "$_total" "$_pass" "$_fail"
[[ "$_fail" -eq 0 ]]
