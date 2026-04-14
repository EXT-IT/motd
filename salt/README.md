# motd (Salt)

Version: **v1.0.1** — see the top-level [`README.md`](../README.md) for the
project overview and [`CHANGELOG.md`](../CHANGELOG.md) for release notes.

Standards-compliant login banner **and** post-login dynamic MOTD for Linux
systems, delivered as a SaltStack formula. Writes the pre-auth banner files
(`/etc/issue`, `/etc/issue.net`), deploys a runtime-configured MOTD script
under `/etc/update-motd.d/`, drops a `sshd_config.d/` snippet that activates
the banner, and reloads `sshd` only when validation passes. Fully pillar-driven;
no tenant branding is baked into the formula.

This is the Salt-native variant of `motd`. A standalone shell installer
(`install.sh`) lives at the top level of the same repository and is
byte-for-byte compatible with the script and config file the Salt formula
deploys. See [`salt/pillar.example.sls`](pillar.example.sls) for a fully
commented example pillar.

> **Pillar namespace:** the top-level pillar key is `login_banner:`. All
> banner-related keys live directly under it; the MOTD and sshd features
> are grouped under `login_banner:motd:` and `login_banner:sshd:`
> sub-namespaces.

## Overview

The formula has two sub-states, both included by default and individually
gateable via pillar flags:

- **`banner.sls`** — pre-auth banner. Compiles two files from a single pillar
  data structure:
  - `/etc/issue` — pure ASCII, displayed on the local console. Uses a flat
    `=` ruler top and bottom, no box drawing characters. Safe on terminals
    that do not have a UTF-8 font loaded (VGA text mode, early boot,
    recovery shells).
  - `/etc/issue.net` — Unicode box, displayed by OpenSSH as the pre-auth
    banner when `Banner /etc/issue.net` is set in `sshd_config`. Box
    characters are selectable (`double`, `single`, `ascii`).

  Both files carry the same warning text: four preset lines (English or
  German), an optional contact line, and a mandatory statute citation. Width
  auto-grows to fit the longest line.

- **`motd.sls`** — post-login dynamic MOTD. Deploys a plain bash script
  (`/etc/update-motd.d/10-system-info`) and a runtime config file
  (`/etc/motd.conf`) that the script sources at every login. Renders the
  config from pillar, prepares the cache directory, neutralises the Ubuntu
  default `update-motd.d` scripts, and (optionally) writes a `sshd_config`
  drop-in that activates the banner. The script itself contains zero Jinja
  — it is the same artifact the standalone installer ships, so the two
  delivery paths are interchangeable.

`init.sls` is a thin include wrapper that pulls in `banner.sls` and/or
`motd.sls` based on the `login_banner:banner_enabled` and
`login_banner:motd_enabled` pillar flags (both default to `true`).

## Requirements

- Salt **3006 LTS** (Onedir) or later on both master and minion.
- Target OS for the banner sub-state: Debian/Ubuntu 20.04+ or RHEL/Rocky/Alma 8+.
- Target OS for the motd sub-state: **Ubuntu 22.04 LTS or 24.04 LTS** (the
  MOTD script assumes the Ubuntu `update-motd.d` mechanism and the
  `update-notifier` cache file layout). RHEL hosts can still use the banner
  sub-state — set `login_banner:motd_enabled: false` and ship the dynamic
  MOTD some other way.
- OpenSSH with `pam_motd` hooked into `/etc/pam.d/sshd` — the Ubuntu and
  Debian defaults. RHEL family ships the same hook out of the box.
- OpenSSH 8.2+ if you want the formula-managed `sshd_config.d/` drop-in
  (`login_banner:sshd:banner_manage`). Older OpenSSH does not include
  `sshd_config.d/*.conf` from the package config; set the directive yourself.
- Root-writable `/etc/issue`, `/etc/issue.net`, `/etc/motd`, `/etc/motd.conf`,
  `/etc/update-motd.d/`, `/etc/ssh/sshd_config.d/`, and `/var/cache/motd`.

No Python packages, no formula dependencies, no external state trees.

## Installation

You have three common options.

### Option A — copy into your state tree

```bash
git clone https://github.com/EXT-IT/motd.git /tmp/motd
# 1. land the formula at salt://motd
cp -r /tmp/motd/salt /srv/salt/motd
# 2. land the runtime script *inside the same directory* so the formula's
#    `source: salt://motd/10-system-info.sh` reference resolves
cp /tmp/motd/motd/10-system-info.sh /srv/salt/motd/10-system-info.sh
```

> **Layout note** (D2 in the 2026-04-12 audit): the `file.managed` state in
> `motd.sls` references the bash script as `source: salt://motd/10-system-info.sh`,
> which Salt resolves to `<file_roots>/motd/10-system-info.sh` — i.e. the
> script must sit **directly inside** the formula directory, NOT under a
> nested `motd/` subdirectory. A first masterless setup attempt that mirrors
> the upstream repo layout (`/srv/salt/motd/motd/10-system-info.sh`) will
> fail with `Source file salt://motd/10-system-info.sh not found`.

Then reference the state by its directory name (`motd`) from your top file.

### Option B — git submodule

```bash
cd /srv/salt
git submodule add https://github.com/EXT-IT/motd.git vendor/motd
ln -s vendor/motd/salt motd
```

### Option C — GitFS remote

Add the repo as a read-only GitFS remote in `master.conf`:

```yaml
gitfs_remotes:
  - https://github.com/EXT-IT/motd.git:
      - root: salt
      - mountpoint: salt://motd
```

Then reference the state as `motd` from any other tree.

## Integration into `top.sls`

### Apply to every minion

```yaml
# states/top.sls
base:
  '*':
    - motd
```

### Apply per tenant in a multi-tenant tree

```yaml
# states/top.sls
base:
  'G@tenant:acme':
    - match: compound
    - motd
  'G@tenant:beispiel':
    - match: compound
    - motd
```

Pillar data is sourced per tenant the same way — each tenant has its own
`pillar/tenants/<tenant>/motd.sls` (containing a `login_banner:` block)
merged via `pillar/top.sls`.

## Pillar reference

All keys live under the top-level `login_banner:` namespace.

### Scope flags

| Key | Type | Default | Description |
|---|---|---|---|
| `banner_enabled` | bool | `true` | Include `banner.sls` (pre-auth banner sub-state). |
| `motd_enabled` | bool | `true` | Include `motd.sls` (post-login dynamic MOTD sub-state). |

Setting both flags to `false` is rejected at render time — the formula refuses
to apply an empty highstate.

### Banner keys (used by `banner.sls`)

| Key | Type | Default | Description |
|---|---|---|---|
| `company_name` | str (≤64 chars) | `"Managed Server"` | Brand name in the banner body. Also written to `/etc/motd.conf` for the MOTD script. Control characters rejected at render time. |
| `contact` | str (≤128 chars) | `""` | Optional contact line. Rendered as `Contact: <value>` only if non-empty. Banner-only — not written to `/etc/motd.conf` (the runtime MOTD script does not parse it). |
| `language` | `en` \| `de` | `en` | Preset translation for the four warning lines and the "prosecuted under" prefix. |
| `style` | `double` \| `single` \| `ascii` | `double` | Box drawing set for `/etc/issue.net`. |
| `min_width` | int | `56` | Minimum inner box width. Grows to `max(min_width, longest_line + 4)`, capped at 120. |
| `statute` | str | `"§202a StGB"` | Unicode statute citation for the SSH banner. |
| `statute_ascii` | str | `"section 202a StGB"` | ASCII variant of the statute for the local console. |
| `issue_file` | path | `/etc/issue` | Target path for the flat ASCII banner. |
| `issue_net_file` | path | `/etc/issue.net` | Target path for the Unicode SSH banner. |
| `clear_motd` | bool | `true` | If true, blank `/etc/motd` (the static file). If false, leave it untouched. |
| `sshd_reload` | bool | `true` | If true, reload sshd on `onchanges` of `issue_net_file`. |
| `warning_lines_override` | list of str | `[]` | If non-empty, replaces the language preset verbatim. Statute is still appended. |

### MOTD keys (used by `motd.sls`, sub-namespace `login_banner:motd:`)

| Key | Type | Default | Description |
|---|---|---|---|
| `subtitle` | str (≤64, no `\` `` ` `` `$` `"`) | `" · Managed Server"` | Subtitle next to the company name in the MOTD header. Leading separator is part of the value. |
| `min_width` | int (20-120) | `54` | Minimum width of the MOTD header box. Grows to fit the longest line. Upper bound 120 matches the standalone installer (`MAX_WIDTH`). |
| `verbose` | bool | `false` | If true, MOTD prints kernel/OS version, full mount usage, and fleet-wide recent logins. Default of false matches CIS Ubuntu 24.04 L1 §1.7.x. |
| `footer` | str (≤128, no `\` `` ` `` `$` `"`) | `""` | Optional footer line. Empty omits the footer. |
| `show_services` | bool | `true` | Show one-line status of installed services. Core daemons (SSH, UFW) and a broad candidate list are probed via `_have_unit()` stat calls — installed daemons render as coloured `●` bullets, absent ones are silently hidden. Candidates include Docker, Containerd, fail2ban, blocklist/ipset, Wazuh, auditd, NetBird, WireGuard, OpenVPN, Restic/Borg, PostgreSQL, MariaDB, MySQL, Redis, MongoDB, InfluxDB, Nginx, Apache, Caddy, Traefik, HAProxy, Podman, CrowdSec, ClamAV, Sophos, Prometheus, Grafana, Zabbix, SNMP, Keepalived, Postfix, Dovecot, Samba, SSSD, Veeam, NinjaOne, and Proxmox (`pve-cluster`). |
| `show_updates` | bool | `true` | Show pending APT update count via the locale-neutral `update-notifier` cache. |
| `show_recent_logins` | bool | `true` | Show recent logins. Scoped to `$LUSER` when verbose is false. |
| `security_priv_only` | bool | `false` | When `true`, the runtime motd script suppresses the Security / Currently-banned blocks for users that are NOT in `sudo` / `wheel` / `admin`. Opt-in for shared bastion hosts; default preserves single-admin VM behaviour. 1:1 parity with `install.sh --motd-security-priv-only`. |
| `pubip_url` | str (≤256, no `\` `` ` `` `$` `"`) | `"https://ifconfig.me"` | URL queried for public IP. Cached 1 h, sanitised on read. Set to `""` to disable. |
| `script_path` | path | `/etc/update-motd.d/10-system-info` | Where to install the MOTD script. |
| `config_path` | path | `/etc/motd.conf` | Where to render the runtime config file. The script sources this at every login. |
| `cache_dir` | path | `/var/cache/motd` | Root-owned 0755 cache directory. **Never** point at `/tmp`, `/var/tmp`, or `/dev/shm` (terminal-injection vector). |

### SSHD keys (used by `motd.sls`, sub-namespace `login_banner:sshd:`)

| Key | Type | Default | Description |
|---|---|---|---|
| `banner_manage` | bool | `true` | If true, write a `sshd_config.d/` drop-in that activates the pre-auth banner, validate via `sshd -t`, reload sshd on change. |
| `banner_dropin` | path | `/etc/ssh/sshd_config.d/99-motd-banner.conf` | Where to write the drop-in. Must live under `sshd_config.d/` for OpenSSH 8.2+ default Include to pick it up. |
| `reload` | bool | `true` | Independent reload toggle for the sshd drop-in. Controls whether `motd.sls` reloads sshd after writing the drop-in. The top-level `sshd_reload` controls banner.sls reloads separately. Set to `false` to stage the drop-in during a maintenance window without reloading immediately. |

See `pillar.example.sls` for a fully commented example.

## Examples

### Example 1 — minimal (English)

```yaml
login_banner:
  company_name: "Acme Inc"
```

Renders `/etc/issue.net`:

```
╔════════════════════════════════════════════════════════╗
║  WARNING: Authorized access only.                      ║
║  This system is property of Acme Inc.                  ║
║  Unauthorized access is strictly prohibited.           ║
║  All connections are monitored and logged.             ║
║  Violations prosecuted under §202a StGB.               ║
╚════════════════════════════════════════════════════════╝
```

### Example 2 — German tenant with single-line box

```yaml
login_banner:
  company_name: "Beispiel GmbH"
  contact: "it@beispiel.example"
  language: de
  style: single
  min_width: 60
```

Renders `/etc/issue.net`:

```
┌────────────────────────────────────────────────────────────┐
│  WARNUNG: Nur autorisierter Zugriff.                       │
│  Dieses System ist Eigentum von Beispiel GmbH.             │
│  Unbefugter Zugriff ist strikt untersagt.                  │
│  Alle Verbindungen werden überwacht und protokolliert.     │
│  Contact: it@beispiel.example                              │
│  Verstöße werden verfolgt nach §202a StGB.                 │
└────────────────────────────────────────────────────────────┘
```

### Example 3 — ASCII-only for serial consoles

```yaml
login_banner:
  company_name: "LegacyBox"
  style: ascii
  clear_motd: false
  sshd_reload: false
```

Renders `/etc/issue.net`:

```
+========================================================+
|  WARNING: Authorized access only.                      |
|  This system is property of LegacyBox.                 |
|  Unauthorized access is strictly prohibited.           |
|  All connections are monitored and logged.             |
|  Violations prosecuted under §202a StGB.               |
+========================================================+
```

## sshd reload semantics

**Differs from the standalone installer** — by design, both pathways reach the same operational invariant.

The standalone installer uses a single global `SSHD_RELOAD=true/false` (CLI flag `--no-sshd-reload`). The Salt formula has two separate keys:

| Pillar key | Sub-state | Drives |
|---|---|---|
| `login_banner:sshd_reload` | `banner.sls` | `cmd.run` reload on `onchanges` of `login_banner_net` (the `/etc/issue.net` write) |
| `login_banner:sshd:reload` | `motd.sls` | `cmd.run` reload on `onchanges` of `login_banner_sshd_banner_dropin` (the `sshd_config.d/` drop-in write — W4 split) |

Both keys default to `true` and both pathways reach "deploy the artefact, do not reload sshd now" when set to `false` — which is what an operator needs during a change window: stage the new config but defer the reload to an approved maintenance slot.

The two-key split is the part that has no standalone equivalent: an operator can set `login_banner:sshd:reload: false` to stage the drop-in for the next maintenance window while still reloading sshd for the banner immediately (or vice versa). Standalone collapses both into one knob because `install.sh` runs the phases sequentially and a per-artefact split is harder to reason about on a single command line.

If you flip a host between Salt and standalone management, the upgrade path is straightforward: a `SSHD_RELOAD=false` standalone config becomes BOTH `sshd_reload: false` AND `sshd:reload: false` on the Salt side. Setting only one of the two leaves the other reload enabled.

## State layout

The formula compiles into up to ~20 state IDs across the two sub-states. All
state IDs are unique across the formula so cross-state `require` / `watch`
work without ambiguity.

### `banner.sls`

| State ID | Resource | Condition |
|---|---|---|
| `login_banner` | `file.managed` on `issue_file` | `banner_enabled: true` |
| `login_banner_net` | `file.managed` on `issue_net_file` | `banner_enabled: true` |
| `login_banner_static_motd_clear` | `file.managed` on `/etc/motd` | `clear_motd: true` |
| `login_banner_net_sshd_reload` | `cmd.run` (reload sshd on issue.net change) | `sshd_reload: true` |

The reload state is declared with `onchanges: - file: login_banner_net` and
`require: - file: login_banner_net`. `onchanges` makes idempotent applies
silent; `require` ensures that a render failure on `issue.net` short-circuits
before sshd is asked to reload a missing or broken banner file. This is
deliberate — a broken banner state must never take down sshd.

### `motd.sls`

| State ID | Resource | Condition |
|---|---|---|
| `login_banner_motd_cache_dir` | `file.directory` on `cache_dir` | `motd_enabled: true` |
| `login_banner_motd_cache_legacy_cleanup` | `file.absent` on `/tmp/.motd_pubip` | `motd_enabled: true` |
| `login_banner_motd_marker` | `file.touch` on `${cache_dir}/salt-status` | `motd_enabled: true` |
| `login_banner_motd_config` | `file.managed` on `config_path` | `motd_enabled: true` |
| `login_banner_motd_script` | `file.managed` on `script_path` (source: `salt://motd/10-system-info.sh`) | `motd_enabled: true` |
| `login_banner_motd_disable_<name>` | `file.managed` on `/etc/update-motd.d/<name>` (clears +x) | `motd_enabled: true` (per Ubuntu default script that exists on the host) |
| `login_banner_sshd_banner_dropin` | `file.managed` on `sshd:banner_dropin` | `sshd:banner_manage: true` |
| `login_banner_sshd_validate` | `cmd.run` `sshd -t` | `sshd:banner_manage: true` |
| `login_banner_sshd_reload` | `cmd.run` (reload sshd on drop-in change) | `sshd:banner_manage: true` |

The MOTD script (`login_banner_motd_script`) is shipped as a plain bash file
via `source: salt://motd/10-system-info.sh` — there is **no** `template:
jinja` clause. All runtime configuration flows through `/etc/motd.conf`,
which is rendered by `login_banner_motd_config` from the
`login_banner:motd:` sub-namespace. The script sources `/etc/motd.conf` at
every login, so read-only tweaks (subtitle, footer, feature toggles) take
effect on the next login without a `state.apply` round-trip.

The sshd integration is two-stage: `login_banner_sshd_validate` runs `sshd
-t` against the new drop-in, and `login_banner_sshd_reload` reloads sshd
only if validation passed (`require: - cmd: login_banner_sshd_validate` +
`onchanges: - file: login_banner_sshd_banner_dropin`). A broken drop-in
fails the validate state, the reload never runs, and sshd keeps the
previous-good config in memory. The drop-in itself `require`s
`login_banner_net`, so a broken banner.sls render short-circuits before sshd
ever sees a `Banner` directive that points at a missing file.

## MOTD

The post-login MOTD shows a compact box per login with: hostname + tenant
subtitle, kernel/OS abbreviated (or full when `verbose: true`), uptime, load,
local mounts disk usage, RAM, public IP (cached), pending APT updates, recent
logins (scoped to `$LUSER` unless `verbose: true`), and one-line status of the
detected core services. The footer line is opt-in via `motd:footer`.

### Runtime configuration via `/etc/motd.conf`

The Salt formula renders `/etc/motd.conf` from pillar; the standalone bash
installer at the top of the repo writes the same file format. The script
itself is byte-identical between the two delivery paths. Example rendered
output for `company_name: "EXT IT GmbH"` and the documented defaults:

```
# /etc/motd.conf — rendered by Salt formula 'motd'
# https://github.com/EXT-IT/motd
# Do not edit — changes will be overwritten on next state.apply.
#
# Shared with the standalone installer — both read this file.

# -- branding (shared with banner) --
# (CONTACT is a banner-only field; it lives in banner.sls rendering
#  context, not in /etc/motd.conf — see the comment in motd.sls for
#  the rationale.)
COMPANY_NAME="EXT IT GmbH"

# -- motd --
MOTD_SUBTITLE=" · EXT IT Managed"
MOTD_MIN_WIDTH=56
MOTD_VERBOSE=false
MOTD_FOOTER="Tickets: https://support.ext-it.tech"
MOTD_SHOW_SERVICES=true
MOTD_SHOW_UPDATES=true
MOTD_SHOW_RECENT_LOGINS=true
MOTD_PUBIP_URL="https://ifconfig.me"
MOTD_CACHE_DIR="/var/cache/motd"
```

(Strings are wrapped in `"..."` literals after the `_check` macro has
rejected backslash, backtick, `$`, and `"` at render time. With those four
shell-active metacharacters out of the way, the value can be embedded
as-is — UTF-8 is preserved (so `·` stays as `·` instead of getting escaped
to `\u00b7` like Jinja's `|tojson` would do), and `source /etc/motd.conf`
from bash is always safe.)

### Example rendered output

The runtime script draws a Unicode box (`╭─╮`/`╰─╯`) and renders
services as coloured `●` bullets — green `●` = active, yellow `●` =
inactive/unknown, red `●` = failed. ASCII rendering below; on a real
terminal the box is drawn with light box-drawing characters and the
bullets are coloured:

```
╭────────────────────────────────────────────────────────╮
│  webd01.example · EXT IT Managed                       │
│  Ubuntu 24.04 · up 12d 4h · load 0.18                  │
│  Disk /: 34% of 60G · RAM: 1.2 / 4.0 G                 │
│  Public IP: 203.0.113.42 (cached)                      │
│  Updates: 137 available (101 security)                 │
│  Services: ● SSH  ● UFW  ● Docker  ● Containerd        │
│            ● fail2ban  ● Wazuh  ● NetBird              │
│  Salt: last apply 2026-04-11 09:32                     │
│                                                        │
│  Tickets: https://support.ext-it.tech                  │
╰────────────────────────────────────────────────────────╯
```

The Services line wraps when the list of detected daemons exceeds the
box width, so the rendered output grows vertically with the number of
active daemons rather than overflowing horizontally. Recent logins,
fail2ban ban detail, and the Security block appear as separate blocks
below the header on hosts where they have content to display.

### Hot-path safety

The MOTD script is on the SSH login critical path. The change-safety baseline
applies in full:

- Zero `salt-call` invocations (those would add ~500 ms per login on LXC).
  The "last salt apply" timestamp is read from the mtime of
  `${cache_dir}/salt-status`, which the formula touches on every
  `state.apply` via `login_banner_motd_marker`.
- Every external command that talks to a daemon socket (`fail2ban-client`,
  `docker ps`, `systemctl is-active`) is wrapped in `timeout 2`.
- The public IP probe is cached for 1 h under `${cache_dir}/pubip`, capped
  in length, sanitised on read (`tr -dc '0-9a-fA-F:.'`), and skipped
  entirely on Proxmox hosts.
- The APT update count is read from `/var/lib/update-notifier/updates-available`
  with a position-based parser (locale-neutral) — no `apt list --upgradable`
  in the hot path.
- The cache directory is `/var/cache/motd` (root-owned, 0755). The legacy
  `/tmp/.motd_pubip` from the pre-audit era is removed unconditionally on
  every apply.

### Idempotence notes

A clean `state.apply` re-run reports `Succeeded: N (changed=0)` on
every state **except one**: `login_banner_motd_marker` is a
`file.touch` on `${cache_dir}/salt-status`, so its mtime updates on
every apply. This is the input to the runtime MOTD script's
"Salt: last apply HH:MM" line — the marker must refresh to keep the
render current. Expect `changed=1` for exactly this one state on a
true no-op run; it does **not** indicate drift, it is the marker
doing its job. Every other state in `banner.sls` and `motd.sls` is
strictly idempotent and reports `changed=0` on a re-apply with an
unchanged pillar.

## SSHD configuration

By default (`login_banner:sshd_reload: True`), the state validates the live
sshd config with `sshd -t` and reloads the daemon whenever `/etc/issue.net`
changes. The `Banner /etc/issue.net` directive must still be set once — either
via the companion `motd.sls` drop-in (which writes
`/etc/ssh/sshd_config.d/99-motd-banner.conf`) or manually:

```
# /etc/ssh/sshd_config (or a drop-in under sshd_config.d/)
Banner /etc/issue.net
```

Set `login_banner:sshd_reload: False` in pillar if you manage sshd reloads
externally. In that case, add `require: - file: login_banner_net` to your own
sshd_config state so a broken banner cannot take the daemon down.

## Pillar examples

Four ready-to-copy pillar files live under `salt/examples/`. Each one is a
1:1 translation of a standalone-installer config under `examples/`, so an
operator who knows one shape can switch between deployment modes without
relearning the field set.

| Pillar example | Standalone counterpart | Profile |
|---|---|---|
| `salt/examples/pillar-minimal.sls` | `examples/config-minimal.conf` | The handful of fields most operators want to set; everything else falls back to defaults. |
| `salt/examples/pillar-corporate.sls` | `examples/config-corporate.conf` | English banner, double-line box, dynamic MOTD on with safe-default visibility. |
| `salt/examples/pillar-paranoid.sls` | `examples/config-paranoid.conf` | Heavy custom statute, banner on, every optional MOTD section disabled. |
| `salt/examples/pillar-full.sls` | `examples/config-full.conf` | Every supported key set to a non-default value, with `warning_lines_override` demonstrated. |

To use one as a starting point, copy it into your tenant pillar tree and
adjust the values:

```bash
mkdir -p /srv/pillar/tenants/<tenant>
cp salt/examples/pillar-corporate.sls /srv/pillar/tenants/<tenant>/login_banner.sls
# edit, then wire up via your pillar top file
salt '<minion>' saltutil.refresh_pillar
salt '<minion>' state.apply motd test=True
```

The `backup:enabled: true` setting in the corporate / paranoid / full
examples is **deliberately explicit** because the formula default is
`false` (see the "Backup default differs from the standalone installer"
note in the Security section). Drop it if you want the upgrade-safe
silent default.

## Troubleshooting

**SSH does not show the banner after `state.apply`:**

1. Confirm `sshd_config` contains `Banner /etc/issue.net`.
2. Confirm the banner file exists: `ls -l /etc/issue.net`.
3. Confirm sshd reloaded: `systemctl status sshd` (check the last reload
   timestamp) or force it manually: `systemctl reload sshd`.
4. SSH clients cache the banner during the pre-auth phase only. Open a new
   connection to see the change; an existing session will not update.

**Banner still shows old company name after pillar change:**

```bash
salt '*' saltutil.refresh_pillar
salt '*' state.apply motd
```

Pillar is cached on the minion until an explicit refresh.

**MOTD still shows old subtitle / footer after pillar change:**

The MOTD script sources `/etc/motd.conf` at every login, but `/etc/motd.conf`
itself is only re-rendered by `state.apply`. Force an apply, then open a
new SSH session:

```bash
salt '*' saltutil.refresh_pillar
salt '*' state.apply motd
```

A re-login is required because pam_motd only fires at session start.

**MOTD shows "last apply: never" or a stale timestamp:**

The marker file `/var/cache/motd/salt-status` is touched by the
`login_banner_motd_marker` state. If it is missing, run `state.apply` once
to recreate it. If the timestamp is stale, your scheduled `state.apply`
runs may be failing — check `salt-run jobs.list_jobs` on the master.

**`login_banner_sshd_validate` fails with `sshd: no hostkeys available`:**

This means the host has no SSH host keys yet (a freshly bootstrapped
minion). Run `dpkg-reconfigure openssh-server` once on the host, or set
`login_banner:sshd:banner_manage: false` in pillar until host keys are
in place.

**Render fails with `motd: ... contains shell metacharacter (\, \`, $, or ")`:**

A pillar value under `login_banner:motd:` (subtitle, footer, pubip_url, …)
contains a backslash, backtick, dollar sign, or double quote. These are
rejected because they would break out of the surrounding `"..."` literal in
`/etc/motd.conf` and reach a shell `source`. Strip the offending character.

**State raises `login-banner: company_name contains a control character`:**

Your pillar value contains a byte below 0x20 or equal to 0x7F. The state
rejects these because they reach a terminal (`getty`/`sshd`) and could emit
ANSI/OSC escapes. Strip the offending byte from pillar.

**Box is narrower than expected:**

`min_width` only sets the floor. The box grows to `longest_line + 4` when
text is long. If you need a fixed width, lower `min_width` and shorten your
text, or set `warning_lines_override` to lines that fit inside `min_width`.

**Banner rendering looks misaligned in UTF-8 locale:**

Unicode combining characters are not counted correctly by `length` and
may cause a 1-cell drift in some terminals. If you need to use such
characters, shorten the line by 1–2 characters to give the pad headroom.

**RHEL family: `/etc/issue` shows kernel version after every apply:**

This happens when `/etc/issue` is managed by another mechanism (e.g.
anaconda-generated issue, or the `issue` macro in systemd). Remove the
competing source once and let the Salt state own the file.

## Security notes

- The banner sub-state rejects control characters and strings longer than 64
  characters in `company_name` and `contact` at render time. Banner strings
  reach a TTY; a tampered value could emit ANSI/OSC escapes
  (terminal-injection vector).
- The MOTD sub-state additionally rejects backslash, backtick, `$`, and `"`
  in every string value rendered into `/etc/motd.conf`. The file is `source`d
  by a bash script, and those four metacharacters would break out of the
  surrounding `"..."` literal. With them rejected up front, the values can
  be embedded as-is (UTF-8 preserved, no `\uXXXX` escaping) and `source` is
  always safe. Per-key length caps live in `motd.sls` `_KEY_LIMITS`:
  `motd:subtitle` 64, `motd:footer` 128, `company_name` 64; everything
  else falls through to `_MAX_VAL_LEN` 256.
- The statute citation is always appended, even when `warning_lines_override`
  is set. Legal compliance (BSI IT-Grundschutz SYS.1.3.M6, US-CFAA case law)
  expects a specific statute reference in the pre-auth banner.
- CIS Ubuntu 24.04 Level 1 §1.7.x asks for kernel and OS version to be kept
  out of the MOTD. The MOTD script suppresses both by default; opt in via
  `motd:verbose: true` for admin-only hosts where the trade-off is acceptable.
- `last` is scoped to `$LUSER` by default for the same reason: a fleet-wide
  `last -n N` leaks cross-admin movement patterns to every authenticated user.
  Verbose mode opts back in.
- The MOTD cache directory is `/var/cache/motd` (root-owned, 0755). The
  formula refuses to render if the configured `cache_dir` value contains
  shell metacharacters, and the legacy `/tmp/.motd_pubip` cache file from
  the pre-audit era is removed unconditionally on every apply. Never point
  `cache_dir` at `/tmp`, `/var/tmp`, or `/dev/shm`.
- The sshd reload is gated by `sshd -t` validation. A broken drop-in fails
  validation, the reload never runs, and sshd keeps the previous-good config
  in memory. The drop-in itself `require`s the issue.net file state, so a
  broken banner.sls render short-circuits before any sshd state runs.
- The banner reload is gated by `onchanges` so idempotent applies do not
  churn the service.

### Backup default differs from the standalone installer

`install.sh` defaults to `BACKUP=true` (every overwrite captures a pristine
copy under `/var/backups/motd`). Salt defaults to
`login_banner:backup:enabled: false`. The two values are intentionally
divergent — a Salt-managed fleet runs `state.apply` on every minion on a
schedule, and a default of `true` would silently create a 0700-owned
backup directory plus pristine snapshots on every host the formula was
ever applied to, even ones that never explicitly opted in. Disk usage and
audit surface for hosts that never asked for backups would grow without
operator notice.

**New tenants who want parity with the standalone installer should set
`login_banner:backup:enabled: true` explicitly in their pillar** (and
optionally `login_banner:backup:dir` if `/var/backups/motd` is not the
right destination on their disk layout). Existing tenants are not
affected — the default of `false` is the upgrade-safe choice.

## License

Apache-2.0

Copyright (c) 2026 EXT IT GmbH

See the repository root `LICENSE` file for the full text.
