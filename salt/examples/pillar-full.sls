# =============================================================================
# motd — full pillar example
# -----------------------------------------------------------------------------
# Mirrors examples/config-full.conf at the standalone repo root: every
# supported key set to a *non-default* value, with a one-line comment per
# key explaining why an operator might want that choice.
#
# Use this file as a reference when building your own tenant pillar tree.
#
# CLI parity (standalone installer):
#     sudo ./install.sh --config examples/config-full.conf
# =============================================================================

login_banner:

  # ── Banner ──

  # Branded company name (default: "Managed Server").
  company_name: "EXT IT GmbH"

  # Contact line — routes incident reports to the right inbox.
  contact: "kontakt@ext-it.tech"

  # German preset — for bilingual sites or pure-DE tenants.
  language: de

  # Single-line box style — lighter visual weight than the default "double".
  style: single

  # Wider-than-default minimum box, in case you expect long contact strings
  # or multi-word company names that would otherwise look cramped.
  min_width: 72

  # German statute citation, Unicode form — StGB §202a covers
  # unauthorised data access under German criminal law.
  statute: "§202a StGB (Ausspähen von Daten)"

  # ASCII form of the same citation — rendered into /etc/issue where the
  # boot console may not have a UTF-8 font loaded yet.
  statute_ascii: "StGB section 202a (Ausspaehen von Daten)"

  # Custom warning lines — overrides the German preset with a verbatim
  # bilingual list. The Salt list is the canonical form; the standalone
  # CLI mirrors it via repeatable --warning-lines flags. Both shapes
  # produce the same /etc/issue.net output.
  warning_lines_override:
    - "WARNUNG: Nur autorisierter Zugriff."
    - "Dieses System ist Eigentum der EXT IT GmbH."
    - "WARNING: Authorized access only."
    - "Unauthorized access is monitored and prosecuted."

  # Non-default target paths — useful on read-only / overlay systems where
  # /etc is tmpfs-backed and you want the banners on persistent storage.
  issue_file: /etc/issue
  issue_net_file: /etc/issue.net

  # Keep /etc/motd in place — disables the default "blank it out" behaviour.
  # Useful when your distro's dynamic MOTD is already configured and you
  # only want the pre-login banner changed.
  clear_motd: false

  # ── MOTD ──
  motd:
    # Distinct subtitle for the MOTD header box. Leading separator is
    # intentional.
    subtitle: " · Production Fleet"

    # Wider header box to match the wider banner above. Auto-grows further
    # if "EXT IT GmbH · Production Fleet" + padding overflows.
    min_width: 64

    # Verbose mode: show kernel version and public IP. Off by default for
    # CIS Ubuntu 24.04 L1 §1.7.x compliance — opt in only on hosts with
    # admin-only SSH surface.
    verbose: true

    # Footer line shown at the very bottom of the MOTD. Empty by default.
    footer: "Managed by Salt — see https://github.com/EXT-IT/motd"

    # Section visibility — every block is shown by default.
    show_services: true
    show_updates: true
    show_recent_logins: true

    # Self-hosted IP probe — keep your public-IP lookups inside your own
    # infrastructure instead of leaking to ifconfig.me. The runtime script
    # wraps every call in `curl --max-time 2` and caches for 1 hour.
    pubip_url: "https://ip.demo.domain"

    # Non-default install paths — surface them so an operator who wants to
    # move things knows where to look.
    script_path: /etc/update-motd.d/10-system-info
    config_path: /etc/motd.conf
    cache_dir: /var/cache/motd

  # ── sshd integration ──
  sshd:
    # Manage the sshd_config.d/ drop-in. Salt validates the candidate
    # config with `sshd -t -f` before any reload.
    banner_manage: true

    # Non-default sshd drop-in path. Same place sshd_config.d normally
    # lives on Debian/Ubuntu and modern RHEL.
    banner_dropin: /etc/ssh/sshd_config.d/99-motd-banner.conf

    # Reload sshd after writing. Does NOT disconnect existing sessions.
    # Kept as a separate key so operators can stage the drop-in during
    # a maintenance window without an immediate reload.
    reload: true

  # ── Backups (opt in for parity with standalone default) ──
  backup:
    enabled: true
    # Non-default backup directory — e.g. /srv/backups already mirrored
    # offsite via your normal backup pipeline.
    dir: /srv/backups/motd
