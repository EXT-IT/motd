#!/usr/bin/env bash
# =============================================================================
# tests/test_c1_injection.sh — pre-auth terminal-injection regression test
# -----------------------------------------------------------------------------
# Verifies that install.sh rejects UTF-8-encoded C1 control codepoints
# (U+0080–U+009F, encoded as 0xC2 0x80–0x9F) in COMPANY_NAME and other
# text fields. These bytes are valid UTF-8 and the iconv round-trip in
# _is_printable_safe accepts them, so without the explicit byte-pair
# check they would land in /etc/issue.net and act as terminal-injection
# vectors on xterm/VTE/Windows-Terminal with `allowC1Printable: true`
# (0x9B = CSI starter, 0x9D = OSC starter).
#
# Black-box: drives install.sh --dry-run with crafted COMPANY_NAME values
# and asserts the documented exit codes. Does not require root, does not
# touch the filesystem outside this script.
#
# Usage: bash tests/test_c1_injection.sh    (from repo root)
# Exit:  0 = all pass, 1 = at least one regression
# =============================================================================

set -u
IFS=$'\n\t'

# Locate install.sh relative to this script so the test works from any CWD.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_installer="$_here/../install.sh"
if [[ ! -x "$_installer" ]]; then
    echo "FAIL: install.sh not found or not executable at $_installer" >&2
    exit 1
fi

_pass=0
_fail=0
_total=0

# Run install.sh with the given COMPANY_NAME; assert the exit code
# matches expected. $1=label  $2=expected-exit  $3=COMPANY_NAME bytes
_assert_exit() {
    local label="$1" expected="$2" payload="$3"
    _total=$((_total + 1))
    local actual
    COMPANY_NAME="$payload" "$_installer" --dry-run >/dev/null 2>&1
    actual=$?
    if [[ "$actual" == "$expected" ]]; then
        printf "  PASS  %s (exit=%d)\n" "$label" "$actual"
        _pass=$((_pass + 1))
    else
        printf "  FAIL  %s (expected=%d, actual=%d)\n" "$label" "$expected" "$actual" >&2
        _fail=$((_fail + 1))
    fi
}

echo "C1-injection regression suite (install.sh _is_printable_safe)"
echo "============================================================="

# --- REJECT cases: must exit 3 (validation error) ---
echo
echo "Inputs that MUST be rejected (exit 3):"
_assert_exit "U+009B (CSI, 0xC2 0x9B) — pre-auth ANSI injection vector" \
    3 "$(printf 'X\xc2\x9bY')"
_assert_exit "U+009D (OSC, 0xC2 0x9D) — pre-auth window-title injection" \
    3 "$(printf 'X\xc2\x9dY')"
_assert_exit "U+0080 (lowest C1, 0xC2 0x80) — boundary" \
    3 "$(printf 'X\xc2\x80Y')"
_assert_exit "U+009F (highest C1, 0xC2 0x9F) — boundary" \
    3 "$(printf 'X\xc2\x9fY')"
_assert_exit "raw 0x9B (legacy 8-bit CSI, no UTF-8 framing)" \
    3 "$(printf 'X\x9bY')"
_assert_exit "C0 control 0x1B (ESC) — baseline reject" \
    3 "$(printf 'X\x1b[31mY')"

# --- ACCEPT cases: must exit 0 ---
echo
echo "Inputs that MUST be accepted (exit 0):"
_assert_exit "ASCII baseline" \
    0 "Acme Corp"
_assert_exit "German umlauts (ä ö ü ß) — 0xC3 lead bytes, outside C1" \
    0 "Müller & Söhne GmbH"
_assert_exit "U+00A9 © (0xC2 0xA9) — Latin-1 supplement, just above C1" \
    0 "$(printf '\xc2\xa9 Acme')"
_assert_exit "U+00AE ® (0xC2 0xAE)" \
    0 "$(printf 'Acme\xc2\xae')"
_assert_exit "U+00B0 ° (0xC2 0xB0) — degrees" \
    0 "$(printf '20\xc2\xb0C ops')"
# Note: emoji and other wide characters are rejected by a SEPARATE
# display-width guard (install.sh:_strlen_display), not by the
# printable/C1 check tested here. They are intentionally out of scope.

echo
echo "============================================================="
printf "Total: %d   Pass: %d   Fail: %d\n" "$_total" "$_pass" "$_fail"
[[ "$_fail" -eq 0 ]]
