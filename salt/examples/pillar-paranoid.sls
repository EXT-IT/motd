# =============================================================================
# motd — paranoid / minimum-disclosure pillar example
# -----------------------------------------------------------------------------
# Mirrors examples/config-paranoid.conf at the standalone repo root.
# Profile: heavy pre-login warning with a long custom statute citation,
# the dynamic MOTD installed but with EVERY optional information block
# disabled. The post-login screen will show only the company header
# box, the bare system identity (FQDN, OS, IPs, uptime, load), and the
# resource bars. No services, no updates, no login history, no kernel
# version, no public IP.
#
# Suitable for high-sensitivity environments where every line of
# post-auth output is vetted: regulated industries, classified
# environments, ops-team-only bastion hosts.
#
# CLI parity (standalone installer):
#     sudo ./install.sh --config examples/config-paranoid.conf
# =============================================================================

login_banner:

  # ── Banner ──
  company_name: "Acme Restricted Systems"
  contact: "abuse@acme.example"
  language: en
  style: double
  min_width: 80      # wide box accommodates the long custom statute below

  # Long custom statute citation. Most legal teams want a multi-clause
  # warning that covers BSI IT-Grundschutz, GDPR, and the local computer
  # misuse act. Both Unicode and ASCII variants must fit in min_width-4.
  statute: "§202a StGB · GDPR Art. 32 · BSI SYS.1.3.M6 · all access logged"
  statute_ascii: "section 202a StGB / GDPR Art. 32 / BSI SYS.1.3.M6 / all access logged"

  clear_motd: true

  # ── MOTD ──
  motd:
    subtitle: " · Restricted"
    min_width: 64

    # Verbose info OFF — kernel version and public IP are post-auth recon
    # surface (CIS Ubuntu 24.04 L1 §1.7.x).
    verbose: false

    # Footer empty — never disclose provisioning system or support contact
    # in the post-login screen.
    footer: ""

    # Every optional section OFF.
    #   show_services:      hides the daemon-status row + the Security block.
    #   show_updates:       hides the package-count line.
    #   show_recent_logins: hides "Recent Logins" entirely (already user-
    #                       scoped, but paranoia says zero is the right number).
    show_services: false
    show_updates: false
    show_recent_logins: false

  # ── sshd integration ──
  sshd:
    banner_manage: true
    reload: true

  # ── Backups (opt in for parity with standalone default) ──
  backup:
    enabled: true
    dir: /var/backups/motd
