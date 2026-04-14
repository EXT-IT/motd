# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-04-14

Patch release. Two security-relevant fixes and two minor polish items. No
behaviour change for operators on default settings.

### Security

- Reject UTF-8-encoded C1 control bytes (`0xC2 0x80`–`0xC2 0x9F`, i.e.
  `U+0080`–`U+009F`) in operator-settable banner fields (`COMPANY_NAME`,
  `CONTACT`, `MOTD_SUBTITLE`, …). The previous printable-safe check ran
  after an `iconv` round-trip that left valid-UTF-8 C1 encodings intact —
  allowing `0x9B` (CSI) / `0x9D` (OSC) to land in `/etc/issue.net` and
  trigger pre-auth ANSI/OSC injection on terminals with
  `allowC1Printable: true`. The reject runs in a subshell under
  `LC_ALL=C` so byte-mode regex works regardless of the caller's locale.
  Restores 1:1 parity with the Salt path (`salt/banner.sls`).

### Fixed

- `MOTD_PUBIP_URL=""` now actually disables the public-IP probe. The
  defaulting line previously used `${VAR:-default}`, which substitutes
  the default on *unset OR empty* — so an explicit empty-string opt-out
  (documented in `motd.conf.example` as one of three ways to turn the
  probe off) was silently overwritten with `ifconfig.me` before the
  runtime guard could see it. The fix switches both the installer and
  the runtime script to `${VAR-default}` (no colon), falling back only
  when the variable is *unset* and preserving explicit empty-string
  opt-out. Same semantics as the Salt path, which uses
  `pillar.get` with a default that fires only on key-absence.
- Quickstart instructions replaced the broken `curl | bash` one-liner
  with `git clone` — the installer needs `motd/10-system-info.sh` from
  the repo directory, which is unreachable when piped from stdin.

### Chore

- Silence ShellCheck `SC2154` false-positive in the installer's `ERR`
  trap.

### Tests

- New regression suites:
  - `tests/test_c1_injection.sh` — 11 black-box cases covering the C1
    control-byte reject. Locale-independent, no root needed.
  - `tests/test_pubip_optout.sh` — 4-layer regression covering the
    installer, the runtime defaulting line (extracted from source by
    `grep` so the test tracks the file), and the underlying
    bash-semantics contract. 6/6 pass.

## [1.0.0] — 2026-04-12

First public release. `motd` ships both halves of the login UX — the pre-auth
warning banner and the post-login dynamic MOTD — as a single installer and a
single SaltStack formula driven by one unified configuration schema.

### Added

#### Pre-login banner

- Standalone `install.sh` supporting Debian, Ubuntu, RHEL, Alma, Rocky,
  CentOS, and Fedora.
- Idempotent writes to `/etc/issue` (flat ASCII) and `/etc/issue.net`
  (Unicode box) with automatic timestamped backups of any pre-existing
  content and a `.latest.bak` symlink to the most recent copy.
- Auto-growing Unicode box with configurable style (`double`, `single`,
  `ascii`) that adapts to the longest line so tenant names cannot overflow
  silently. Hard cap at 120 columns.
- English and German preset warning lines selectable via `--language`, with
  ASCII transliteration (`ü→ue`, `ö→oe`, `ß→ss`) for `/etc/issue` so boot
  consoles without a UTF-8 font still render cleanly.
- Configurable statute citation (default `§202a StGB` for German-operated
  systems) so operators in other jurisdictions can adapt the legal basis of
  the pre-login warning without patching the installer.
- Optional contact line rendered above the statute when non-empty.
- Repeatable `--warning-lines` CLI flag (mirroring the Salt pillar
  `warning_lines_override`) for fully custom pre-auth copy; the statute
  line is still appended automatically for legal compliance. Per-line cap
  is 128 characters; single quote, shell metacharacters (`$`, `` ` ``,
  `"`, `\`), control characters, and emoji are rejected at install time.
  Config-file persistence form is
  `WARNING_LINES_OVERRIDE='Line 1\nLine 2'` (single-quoted, literal `\n`
  separator).

#### Post-login dynamic MOTD

- Runtime bash script (`motd/10-system-info.sh`) deployed to
  `/etc/update-motd.d/10-system-info`. Renders a branded, auto-centered
  header box, logged-in user privileges, system facts, memory and disk
  bars with green → yellow → red thresholds, service health summary,
  updates count, reboot-required warning, security drilldown, and a
  recent-logins block scoped to the currently-logged-in user.
- Service auto-discovery for SSH, UFW, fail2ban, Blocklist (ipset),
  Wazuh, auditd, Salt minion, NetBird, Docker, Containerd, WireGuard,
  OpenVPN, Restic, Borg, plus 30+ infrastructure daemons (PostgreSQL,
  MariaDB, Redis, MongoDB, Nginx, Apache, Caddy, Traefik, HAProxy,
  Prometheus, Grafana, Zabbix, CrowdSec, ClamAV, Postfix, Dovecot,
  Samba, SSSD, Keepalived, Proxmox, …) via a single batched
  `systemctl is-active` call.
- fail2ban per-IP ban detail via
  `fail2ban-client get <jail> banip --with-time` with a bounded-cost
  summary cap at 10 IPs (no log-file scans in the hot path).
- Locale-neutral `update-notifier` parser — works on `de_DE`, `fr_FR`,
  and any gettext-localised output — extracting total and security
  update counts by integer position instead of English phrase matching.
  Immune to the Ubuntu 24.04+ESM preamble, and trusts a parsed "0
  updates" result without falling through to `apt list --upgradable`.
- Runtime toggles for every block: `--no-motd-services`,
  `--no-motd-updates`, `--no-motd-logins`. Disabled sections also skip
  their gathering code so hot-path cost drops accordingly.
- Opt-in verbose mode (`--motd-verbose`) showing kernel version and
  public IP. Off by default per CIS Ubuntu 24.04 L1 §1.7.x
  recon-surface reduction.
- Optional branded footer line (`--motd-footer`) for "Managed by …"
  notices.
- `--motd-security-priv-only` flag (and matching
  `login_banner:motd:security_priv_only` pillar) to suppress the
  Security / Currently-banned blocks for non-privileged users on
  shared bastion hosts.

#### sshd integration

- Automatic drop-in at `/etc/ssh/sshd_config.d/99-motd-banner.conf`
  activating `Banner /etc/issue.net`, with a magic-marker-based
  fallback that appends directly to `sshd_config` on systems that do
  not ship the `Include sshd_config.d/*.conf` line.
- `sshd -t` validation runs before every reload. A bad drop-in is
  reverted immediately from backup — the running daemon never sees a
  broken config.
- Non-disconnecting `systemctl reload sshd`: the installer never uses
  `restart`, so active administrator sessions survive a banner update.

#### Salt formula

- Three-file formula: `salt/init.sls` is a thin include wrapper that
  pulls in `salt/banner.sls` and `salt/motd.sls` based on pillar flags
  `login_banner:banner_enabled` and `login_banner:motd_enabled` (both
  default `true`). Applying the formula with both flags `false` is
  rejected at render time.
- Fully pillar-driven configuration under a single `login_banner:`
  namespace, with `motd:` and `sshd:` sub-namespaces for the MOTD and
  sshd-integration features.
- Idempotent `file.managed` states with explicit `require` /
  `onchanges` chains so the sshd reload only fires when the banner or
  MOTD files actually changed.
- Deploys the same runtime MOTD script the standalone installer ships
  — no Jinja-at-runtime, no template drift between the two delivery
  paths.
- Neutralises the Ubuntu default `/etc/update-motd.d/*` scripts
  declaratively via `file.managed` with `replace: False` (keeps the
  package-managed content intact, only drops the executable bit), and
  skips symlinks to protect package-managed targets such as
  `landscape-common`'s `50-landscape-sysinfo`.
- `.latest.bak` symlinks and pristine-backup markers parity with the
  standalone installer, gated on
  `login_banner:backup:enabled` (default `false` for upgrade safety on
  Salt; `true` is recommended for new tenants that want full
  uninstall round-trip guarantees).
- Per-artefact sshd reload split: `login_banner:sshd_reload` controls
  reload on banner change (`banner.sls`),
  `login_banner:sshd:reload` controls reload on drop-in change
  (`motd.sls`). Operators can stage the drop-in for a maintenance
  window while reloading sshd for the banner immediately (or vice
  versa).

#### Installer / uninstaller ergonomics

- Scope aliases `--banner-only` and `--motd-only` for installers that
  want only one of the two features.
- Dry-run mode (`--dry-run`) prints everything that would be written —
  `/etc/issue`, `/etc/issue.net`, the first 20 lines of the MOTD
  script, the full `/etc/motd.conf`, and the sshd drop-in — without
  touching disk.
- Config-file precedence: CLI flags override environment variables
  which override `/etc/motd.conf` which override built-in defaults.
- GNU-style `--opt=value` and POSIX-style `--opt value` are both
  accepted.
- Unified `/etc/motd.conf` is read by both the installer at install
  time **and** the runtime MOTD script at every login, so the two
  delivery paths converge on a single source of truth.
- Uninstaller with three-phase symmetry (banner, MOTD, sshd),
  `--purge` to also remove `/etc/motd.conf` and `/var/cache/motd`,
  `--keep-cache` (default) to preserve the public-IP cache, and
  `sshd -t` validation before any reload. A `reload sshd` failure
  during uninstall is treated as a hard error and propagated through
  the exit code, not silently logged.
- Example configurations under `examples/` covering a minimal setup
  (`config-minimal.conf`), a managed-infrastructure baseline
  (`config-corporate.conf`), a paranoid banner-plus-minimal-MOTD mode
  (`config-paranoid.conf`), and a full feature matrix
  (`config-full.conf`).
- Matching `salt/examples/pillar-{minimal,corporate,paranoid,full}.sls`
  — each a 1:1 translation of its standalone counterpart, so operators
  who know one shape can switch between delivery modes without
  relearning the field set.

### Security

- Shell-injection guard on every pillar-derived string that lands in
  `/etc/motd.conf`. Values containing `\`, `` ` ``, `$`, or `"` are
  rejected at render time with a clear error message.
- Control-character and ANSI-escape rejection on every user-provided
  string before it reaches the banner files. Company name capped at 64
  characters, contact line at 128 (long email addresses fit).
- Config-file loader is a strict `KEY=VALUE` regex parser — never
  `source`d. A previous draft relied on `source` in a subshell under
  the incorrect assumption that subshells isolate side effects; the
  regex parser accepts only literal strings and rejects unescaped
  `$`, `` ` ``, `\`, `"`, and single quote on every value shape.
  Malformed values are a hard error (exit 3), not a silent fallthrough
  to defaults. The runtime additionally refuses to load a
  `/etc/motd.conf` that is not root-owned (`[ -O "$path" ]`
  trust-boundary check).
- Path-allowlist guard on every installer / uninstaller file operation
  rejects `../` and `./` segments lexically before the allowlist is
  consulted, so no glob pattern can match a traversal such as
  `/var/cache/motd/../../etc/shadow`.
- Public-IP cache lives under root-owned `/var/cache/motd/`
  (mode 0755), never `/tmp/`. Reads are sanitised through a character
  whitelist (`tr -dc '0-9a-fA-F:.' | head -c 64`) and length-capped so
  a tampered cache file cannot emit ANSI / OSC terminal-hijack
  sequences. One-time cleanup of the legacy `/tmp/.motd_pubip` cache is
  performed by both the installer and the Salt formula on first run.
- `MOTD_PUBIP_URL` validator rejects shell metacharacters before the
  URL reaches any `curl` invocation.
- `last` is scoped to the currently-logged-in user. Fleet-wide
  `last -n N` patterns leak cross-admin movement patterns; this release
  never runs `last` fleet-wide outside opt-in verbose mode.
- Every external command in the MOTD hot path is wrapped in
  `timeout 2` so a hung daemon socket (`fail2ban-server`, `dockerd`,
  `netbird`, `wazuh-control`, `systemctl`) cannot block SSH login.
- Atomic writes only: tempfile next to the target, `chown root:root`,
  `chmod 0644`, then `mv -f`. Never leaves a config file in a
  half-written state.
- Symlink guard on the `_disable_ubuntu_motd_defaults` step: the
  installer and the Salt formula both skip symlinks to avoid corrupting
  package-managed targets such as
  `/etc/update-motd.d/50-landscape-sysinfo`, which is a symlink to
  `landscape-common`.
- The Salt formula additionally gates the `sshd:banner_manage` block on
  `banner_enabled`, so a config of `banner_enabled: false` +
  `sshd:banner_manage: true` is silently skipped instead of triggering
  a compile error.

### Performance

- Hot-path budget: ~500-600 ms typical warm-cache runtime on an Ubuntu
  24.04 LXC with a realistic service surface, up to ~700 ms on
  worst-case load. Hard ceiling of 2 s per daemon probe. See the
  README "Performance" section for the measurement methodology and the
  hard rules that hold the budget.
- Zero `salt-call` invocations in the runtime MOTD. The "last Salt
  apply" timestamp is read from the mtime of a marker file
  (`/var/cache/motd/salt-status`) that the Salt formula touches on
  every `state.apply`.
- Binary availability checks use `hash <name>` at the top of the
  service-checks section — a bash builtin that walks `$PATH` once per
  binary, populates bash's internal hash table, and lets every later
  invocation skip the PATH walk entirely. Zero forks, zero failed
  `execve` attempts.
- Single batched `systemctl is-active "${units[@]}"` call for the
  dynamic-discovery candidate list.
- `docker ps` called once per login with
  `-a --format '{{.State}}'`, counted in-shell. Saves two socket
  round-trips versus the previous `ps -q` + `ps -aq` pair.
- Public-IP probe cached for 1 h, skipped entirely on Proxmox hosts
  (no public default route).
- Terse enumeration variants only: `ipset -t list` (header only, not
  the full member dump); `systemctl list-unit-files` cached into a
  shell variable.
- Update count read from `/var/lib/update-notifier/updates-available`
  (cache file), not `apt list --upgradable`.

### Documentation

- Top-level `README.md` with feature overview, sample outputs for both
  the pre-login banner and the post-login MOTD, quickstart for both
  delivery paths, unified configuration reference table, example
  configurations, performance section, and development / verification
  checklist.
- Salt-specific `salt/README.md` with state-layout diagram, pillar
  reference, tenant-override patterns, sshd reload semantics, backup
  default notes, and troubleshooting.
- Keep a Changelog + Semantic Versioning commitment documented in
  this file.
- Apache License 2.0 with a populated copyright notice
  (EXT IT GmbH, 2026).

[1.0.1]: https://github.com/EXT-IT/motd/releases/tag/v1.0.1
[1.0.0]: https://github.com/EXT-IT/motd/releases/tag/v1.0.0
