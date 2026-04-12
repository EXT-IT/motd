# =============================================================================
# motd — corporate pillar example
# -----------------------------------------------------------------------------
# Mirrors examples/config-corporate.conf at the standalone repo root.
# Profile: English-language pre-login banner with the heavy double-line
# style, contact line set, dynamic MOTD enabled with the safe-default
# (non-verbose) section visibility, no footer line.
#
# Suitable for any internal corporate fleet that wants:
#   - a serious-looking pre-login warning with a contact email
#   - the post-login system dashboard turned on
#   - kernel version and public IP kept off the screen (CIS L1)
#   - Recent Logins still on so the operator sees their own session history
#
# Scope flags (banner_enabled / motd_enabled) follow the same intent as
# the standalone --no-banner / --no-motd CLI flags. Pillar default is
# both enabled, which matches `BANNER_ENABLED=true` and `MOTD_ENABLED=true`
# in the config-corporate.conf companion.
#
# Backup default differs from the standalone — see salt/README.md
# Security section. Set explicitly here to match `BACKUP=true`.
#
# CLI parity (standalone installer):
#     sudo ./install.sh --config examples/config-corporate.conf
# =============================================================================

login_banner:

  # ── Banner ──
  company_name: "Acme Corporation"
  contact: "security@acme.example"
  language: en
  style: double
  min_width: 64
  statute: "§202a StGB"
  statute_ascii: "section 202a StGB"
  clear_motd: true

  # ── MOTD ──
  motd:
    subtitle: " · Managed Server"
    min_width: 58
    verbose: false        # CIS L1 §1.7.x — keep kernel and public IP private
    footer: ""            # silent footer; brand stays in the header box only
    show_services: true
    show_updates: true
    show_recent_logins: true

  # ── sshd integration ──
  sshd:
    banner_manage: true
    reload: true

  # ── Backups (opt in for parity with standalone default) ──
  backup:
    enabled: true
    dir: /var/backups/motd
