# motd — example pillar
#
# Purpose:   Configure the motd Salt formula. Covers BOTH the pre-auth login
#            banner (/etc/issue, /etc/issue.net) AND the post-login dynamic
#            MOTD script (/etc/update-motd.d/10-system-info + /etc/motd.conf).
# License:   Apache-2.0
# Copyright: (c) 2026 EXT IT GmbH
# Repo:      https://github.com/EXT-IT/motd
#
# Copy this file into your own pillar tree (e.g. pillar/global/motd.sls or
# pillar/tenants/<tenant>/motd.sls) and customize. Every key below is optional;
# defaults shown inline are what the formula assumes when the key is absent.
#
# Top-level namespace note:
#   The top-level pillar key is `login_banner:` even though the project has
#   been renamed to `motd`. The name is intentionally retained for backwards
#   compatibility with v1 adopters — renaming would break every existing tree.

login_banner:

  # ===========================================================================
  # Scope flags — which sub-states to apply
  # ===========================================================================

  # banner_enabled (bool)
  # If true, include banner.sls (writes /etc/issue + /etc/issue.net and,
  # optionally, blanks /etc/motd and reloads sshd on banner change).
  # Default: true
  banner_enabled: true

  # motd_enabled (bool)
  # If true, include motd.sls (deploys /etc/update-motd.d/10-system-info,
  # renders /etc/motd.conf from pillar, prepares /var/cache/motd, and writes
  # the sshd_config drop-in that activates the pre-auth banner).
  # Default: true
  motd_enabled: true

  # ===========================================================================
  # Pristine backup of pre-install state
  # ===========================================================================
  #
  # Matches install.sh's `backup_file` semantics: on the FIRST state.apply
  # every managed file is copied into `<backup:dir>/<basename>.pristine.bak`
  # BEFORE file.managed overwrites it. Subsequent applies never touch the
  # pristine artefacts, so the very first state on disk remains restorable
  # even after many installs with different company names, contacts, etc.
  #
  # cp -P is used under the hood so /etc/motd's Debian/Ubuntu symlink
  # to /run/motd.dynamic is preserved as-is instead of being dereferenced
  # into a moment-in-time content snapshot.
  #
  # Default is `enabled: False` so existing minions that already run the
  # formula do not suddenly start writing to /var/backups/ on the next
  # state.apply. Set `enabled: True` in pillar to opt in — recommended
  # for any host where you want the uninstaller (or the standalone
  # motd-uninstall tool) to be able to roll back cleanly.

  backup:
    # enabled (bool) — opt-in switch. Default: false.
    enabled: false
    # dir (abs path) — where pristine backups land.
    # Must NOT live under /tmp, /var/tmp, or /dev/shm (world-writable
    # LPE vector — render-time error if you try). Default: /var/backups/motd.
    dir: /var/backups/motd

  # ===========================================================================
  # Banner — pre-auth (/etc/issue + /etc/issue.net)
  # ===========================================================================

  # --- Identity --------------------------------------------------------------

  # company_name (str, max 64 chars, no control characters)
  # The legal/brand name rendered in the banner body. Also written to
  # /etc/motd.conf as COMPANY_NAME for the post-login MOTD script.
  # Default: "Managed Server"
  company_name: "Managed Server"

  # contact (str, optional)
  # If non-empty, renders a `Contact: <value>` line above the statute line
  # in /etc/issue and /etc/issue.net. Banner-only — the post-login MOTD
  # script does not read CONTACT and motd.sls does NOT emit it into
  # /etc/motd.conf. Leave empty to omit entirely.
  # Default: "" (empty; no contact line rendered)
  contact: ""

  # --- Localisation ----------------------------------------------------------

  # language (enum: en | de)
  # Selects the preset warning lines. Ignored when warning_lines_override is
  # non-empty. The "prosecuted under" prefix and the statute separator are
  # also language-switched.
  # Default: en
  language: en

  # --- Visual style ----------------------------------------------------------

  # style (enum: double | single | ascii)
  # Box drawing character set for /etc/issue.net.
  #   double -> ╔═╗║╚╝   (Unicode, default)
  #   single -> ┌─┐│└┘   (Unicode, lighter)
  #   ascii  -> +-+|+-+  (pure ASCII; for terminals without a UTF-8 font)
  # /etc/issue always uses a flat ASCII '=' ruler regardless of style.
  # Default: double
  style: double

  # min_width (int)
  # Minimum inner width of the box. Grows automatically to
  # `max(min_width, longest_line + 4)`, capped at 120.
  # Default: 56
  min_width: 56

  # --- Legal citation --------------------------------------------------------
  #
  # The statute line is ALWAYS appended as the final text line, even when
  # warning_lines_override is set. Legal compliance is not optional.
  #
  # BSI IT-Grundschutz SYS.1.3.M6 and CFAA case law both recommend a specific
  # statute citation in the pre-auth banner. For German-operated systems,
  # §202a StGB ("Ausspähen von Daten") is the usual reference.

  # statute (str)
  # Unicode citation for /etc/issue.net (the SSH banner).
  # Default: "§202a StGB"
  statute: "§202a StGB"

  # statute_ascii (str)
  # ASCII variant for /etc/issue (local console may lack a UTF-8 font).
  # Default: "section 202a StGB"
  statute_ascii: "section 202a StGB"

  # --- Target paths ----------------------------------------------------------

  # issue_file (path)
  # Destination for the flat-ASCII local console banner.
  # Default: /etc/issue
  issue_file: /etc/issue

  # issue_net_file (path)
  # Destination for the Unicode box SSH banner. Reference this in sshd_config
  # via `Banner /etc/issue.net` (the motd sub-state will write a drop-in for
  # you when `sshd:banner_manage` is true).
  # Default: /etc/issue.net
  issue_net_file: /etc/issue.net

  # --- Static MOTD + sshd reload ---------------------------------------------

  # clear_motd (bool)
  # If true, blank the static /etc/motd file so only the pre-auth banner is
  # shown on login. If false, the banner state does not touch /etc/motd at
  # all (existing content is preserved). This is independent of the dynamic
  # MOTD script under /etc/update-motd.d/ — that one is owned by motd.sls.
  # Default: true
  clear_motd: true

  # sshd_reload (bool)
  # If true, the banner state reloads sshd (non-disconnecting) via
  # `systemctl reload sshd || systemctl reload ssh` whenever the issue.net
  # file actually changed. The reload is gated by `onchanges`, so idempotent
  # applies are silent.
  # Default: true
  sshd_reload: true

  # --- Override (advanced) ---------------------------------------------------

  # warning_lines_override (list of str)
  # When non-empty, REPLACES the language preset with these lines verbatim.
  # Use for custom legal text. The statute line is still appended at the end.
  # Default: [] (use language preset)
  warning_lines_override: []

  # ===========================================================================
  # MOTD — post-login dynamic
  # ===========================================================================
  #
  # The dynamic MOTD is a plain bash script (no Jinja) shipped under
  # /etc/update-motd.d/. It reads /etc/motd.conf at every login to pick up
  # the values below. The Salt sub-state motd.sls renders /etc/motd.conf,
  # prepares /var/cache/motd, neutralises the Ubuntu default update-motd.d
  # scripts, and (optionally) writes a sshd_config drop-in for the pre-auth
  # banner from banner.sls.
  #
  # All keys live under `login_banner:motd:`.

  motd:

    # subtitle (str, max 64 chars, no \, `, $, or ")
    # Rendered in the MOTD header next to the company name. The leading
    # separator (e.g. " · ") is part of the value so the empty case is
    # naturally suppressed. Cap matches motd.sls _KEY_LIMITS['motd:subtitle'].
    # Default: " · Managed Server"
    subtitle: " · Managed Server"

    # min_width (int, 20-120)
    # Minimum width of the MOTD header box. The script grows the box to
    # fit the longest line just like the banner does. Upper bound 120
    # matches the standalone install.sh MAX_WIDTH; values above 120 are
    # rejected at render time.
    # Default: 54
    min_width: 54

    # verbose (bool)
    # If true, the MOTD prints kernel + OS version, full mount usage,
    # extended fail2ban detail, and recent logins for ALL users (when
    # show_recent_logins is also true). The default of false matches CIS
    # Ubuntu 24.04 L1 §1.7.x — kernel/OS version stays out of the MOTD,
    # `last` is scoped to the current user only, less information leaks
    # post-auth.
    # Default: false
    verbose: false

    # footer (str, max 128 chars, no \, `, $, or ")
    # Optional footer line shown beneath the MOTD body. Empty omits the
    # footer entirely.
    # Default: "" (no footer)
    footer: ""

    # show_services (bool)
    # If true, the MOTD probes installed core services (sshd, systemd-resolved,
    # docker, ufw, fail2ban, salt-minion, ...) and shows a one-line status
    # block. Probes are skipped on hosts where the service is not installed.
    # Default: true
    show_services: true

    # show_updates (bool)
    # If true, the MOTD reads /var/lib/update-notifier/updates-available
    # (cache file, locale-neutral parser) and shows the count of pending
    # security and regular updates. No `apt list` calls in the hot path.
    # Default: true
    show_updates: true

    # show_recent_logins (bool)
    # If true, the MOTD shows recent logins. Scoped to the current user
    # ($LUSER) when verbose is false; fleet-wide only when verbose is true.
    # Default: true
    show_recent_logins: true

    # security_priv_only (bool)
    # When true, the runtime MOTD script only renders the post-login
    # Security and Currently-banned blocks for users that are members of
    # sudo, wheel, or admin. On shared bastion / jump hosts the fail2ban
    # blocklist, Wazuh health, and running-security-tool state are
    # information you do not want visible to every SSH session.
    # The default of false matches the legacy single-admin-VM behaviour
    # where the post-auth security surface was useful context for every
    # logged-in shell. 1:1 parity with install.sh --motd-security-priv-only.
    # Default: false
    security_priv_only: false

    # pubip_url (str, max 256 chars, no \, `, $, or ")
    # URL queried via `curl --max-time 2` for the public-facing IP of the
    # host. The result is cached in MOTD_CACHE_DIR for 1 hour and sanitised
    # via `tr -dc '0-9a-fA-F:.'` on read. Skipped entirely on Proxmox hosts.
    # Set to empty string to disable the public-IP probe outright.
    # Default: "https://ifconfig.me"
    pubip_url: "https://ifconfig.me"

    # script_path (path)
    # Where to install the MOTD script. The default is the standard Ubuntu
    # update-motd.d numeric prefix.
    # Default: /etc/update-motd.d/10-system-info
    script_path: /etc/update-motd.d/10-system-info

    # config_path (path)
    # Where to render the runtime config file. The MOTD script sources this
    # file at the top of every invocation, so changes take effect on the
    # next login (no state.apply needed for read-only tweaks).
    # Default: /etc/motd.conf
    config_path: /etc/motd.conf

    # cache_dir (path)
    # Root-owned 0755 cache directory under /var/cache. The MOTD script
    # writes the public-IP cache and the Salt apply marker here. NEVER
    # point this at /tmp, /var/tmp, or /dev/shm — those are world-writable
    # and let any local user pre-plant a cache file the root MOTD script
    # then reads back on the next login (terminal-injection vector).
    # Default: /var/cache/motd
    cache_dir: /var/cache/motd

  # ===========================================================================
  # SSHD integration
  # ===========================================================================
  #
  # The motd sub-state can drop a small sshd_config drop-in that activates
  # the pre-auth banner from /etc/issue.net. This is the only way the formula
  # touches sshd configuration; the rest is left to your existing sshd state
  # (or your distro defaults).
  #
  # All keys live under `login_banner:sshd:`.

  sshd:

    # banner_manage (bool)
    # If true, motd.sls writes the drop-in below, validates the resulting
    # sshd config via `sshd -t`, and reloads sshd on change. The reload is
    # gated by validation, so a broken config is never loaded.
    # If false, no sshd state runs from motd.sls — you are expected to set
    # `Banner /etc/issue.net` somewhere else.
    # Default: true
    banner_manage: true

    # banner_dropin (path)
    # Where to write the drop-in. Must live under /etc/ssh/sshd_config.d/
    # for OpenSSH 8.2+ to pick it up via the default Include directive.
    # Default: /etc/ssh/sshd_config.d/99-motd-banner.conf
    banner_dropin: /etc/ssh/sshd_config.d/99-motd-banner.conf

    # reload (bool)
    # Independent reload toggle. The top-level `sshd_reload:` key above
    # controls whether banner.sls reloads sshd when /etc/issue.net
    # changes; THIS key controls whether motd.sls reloads sshd after
    # writing the sshd_config drop-in. Split so operators can stage the
    # drop-in during a maintenance window and let the change go live
    # only at an approved reload time. Leave both at true unless you
    # have a reason to stage.
    # Default: true
    reload: true


# =============================================================================
# Example 1 — EXT IT GmbH (German infrastructure, English banner, full MOTD)
# =============================================================================
#
# login_banner:
#   banner_enabled: true
#   motd_enabled: true
#   company_name: "EXT IT GmbH"
#   contact: "noc@ext-it.tech"
#   language: en
#   style: double
#   min_width: 56
#   statute: "§202a StGB"
#   statute_ascii: "section 202a StGB"
#   clear_motd: true
#   sshd_reload: true
#   motd:
#     subtitle: " · EXT IT Managed"
#     min_width: 56
#     verbose: false
#     footer: "Tickets: https://support.ext-it.tech"
#     show_services: true
#     show_updates: true
#     show_recent_logins: true
#     pubip_url: "https://ifconfig.me"
#   sshd:
#     banner_manage: true
#
# Renders (/etc/issue.net):
#   ╔════════════════════════════════════════════════════════╗
#   ║  WARNING: Authorized access only.                      ║
#   ║  This system is property of EXT IT GmbH.               ║
#   ║  Unauthorized access is strictly prohibited.           ║
#   ║  All connections are monitored and logged.             ║
#   ║  Contact: noc@ext-it.tech                              ║
#   ║  Violations prosecuted under §202a StGB.               ║
#   ╚════════════════════════════════════════════════════════╝
#
# Renders (/etc/motd.conf):
#   COMPANY_NAME="EXT IT GmbH"
#   # (CONTACT is a banner-only field; it lives in banner.sls
#   #  rendering context, not in /etc/motd.conf — see the
#   #  comment in motd.sls for the rationale.)
#   MOTD_SUBTITLE=" · EXT IT Managed"
#   MOTD_MIN_WIDTH=56
#   MOTD_VERBOSE=false
#   MOTD_FOOTER="Tickets: https://support.ext-it.tech"
#   MOTD_SHOW_SERVICES=true
#   MOTD_SHOW_UPDATES=true
#   MOTD_SHOW_RECENT_LOGINS=true
#   MOTD_PUBIP_URL="https://ifconfig.me"
#   MOTD_CACHE_DIR="/var/cache/motd"


# =============================================================================
# Example 2 — German-language tenant, single-line box, MOTD without recent
#             logins (admin-only host where login leakage matters less)
# =============================================================================
#
# login_banner:
#   banner_enabled: true
#   motd_enabled: true
#   company_name: "Beispiel GmbH"
#   contact: "it@beispiel.example"
#   language: de
#   style: single
#   min_width: 60
#   statute: "§202a StGB"
#   statute_ascii: "section 202a StGB"
#   clear_motd: true
#   sshd_reload: true
#   motd:
#     subtitle: " · Beispiel Infra"
#     min_width: 60
#     verbose: false
#     footer: ""
#     show_services: true
#     show_updates: true
#     show_recent_logins: false
#     pubip_url: "https://ifconfig.me"
#   sshd:
#     banner_manage: true
#
# Renders (/etc/issue.net):
#   ┌────────────────────────────────────────────────────────────┐
#   │  WARNUNG: Nur autorisierter Zugriff.                       │
#   │  Dieses System ist Eigentum von Beispiel GmbH.             │
#   │  Unbefugter Zugriff ist strikt untersagt.                  │
#   │  Alle Verbindungen werden überwacht und protokolliert.     │
#   │  Contact: it@beispiel.example                              │
#   │  Verstöße werden verfolgt nach §202a StGB.                 │
#   └────────────────────────────────────────────────────────────┘


# =============================================================================
# Example 3 — Paranoid (banner only, no dynamic MOTD)
# =============================================================================
#
# Locked-down host: a public-facing bastion or jump box where every byte of
# post-auth output is unwanted. The pre-auth banner is the only thing the
# formula manages; the dynamic MOTD script, the cache directory, the sshd
# drop-in, and /etc/motd.conf are all skipped because motd_enabled is false.
#
# Pair this with a sshd_config that hand-sets `Banner /etc/issue.net` (since
# motd.sls will not write the drop-in).
#
# login_banner:
#   banner_enabled: true
#   motd_enabled: false
#   company_name: "Bastion"
#   contact: ""
#   language: en
#   style: ascii            # serial console safe
#   min_width: 56
#   clear_motd: true        # blank /etc/motd — no post-auth output at all
#   sshd_reload: true
#
# Renders (/etc/issue.net):
#   +========================================================+
#   |  WARNING: Authorized access only.                      |
#   |  This system is property of Bastion.                   |
#   |  Unauthorized access is strictly prohibited.           |
#   |  All connections are monitored and logged.             |
#   |  Violations prosecuted under §202a StGB.               |
#   +========================================================+
#
# State IDs applied: login_banner, login_banner_net,
# login_banner_static_motd_clear, login_banner_net_sshd_reload.
# State IDs SKIPPED: every login_banner_motd_* and login_banner_sshd_*.
