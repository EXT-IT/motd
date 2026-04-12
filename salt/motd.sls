{#-
  motd — Salt sub-state for the post-login dynamic MOTD.

  Purpose: deploy the standalone /etc/update-motd.d/10-system-info script,
           render the runtime config file /etc/motd.conf from pillar, prepare
           the cache directory used by the script, neutralise the Ubuntu
           default update-motd.d scripts, and (optionally) drop a sshd_config
           drop-in that activates the pre-auth /etc/issue.net banner from the
           sibling banner.sls.

  This file is included by init.sls when `login_banner:motd_enabled` is True
  (default). The companion sub-state banner.sls handles the pre-auth banner;
  both share the same `login_banner:` pillar namespace.

  Distro / package assumptions:
    - Ubuntu 24.04 LTS (also tested on 22.04 LTS).
    - pam_motd hooked into /etc/pam.d/sshd (the Debian/Ubuntu default).
    - /etc/update-motd.d/ exists and is executed at login by pam_motd.
    - sshd reads /etc/ssh/sshd_config.d/*.conf (default since OpenSSH 8.2).

  License:    Apache-2.0
  Copyright:  (c) 2026 EXT IT GmbH
  Repository: https://github.com/EXT-IT/motd

  Top-level pillar namespace `login_banner:` is intentionally retained for
  backwards compatibility with v1 adopters even though the project has been
  renamed to `motd`. Renaming the namespace would break every existing tree.

  Pillar schema (sub-namespace) — see pillar.example.sls for the full doc.

  login_banner:
    motd:
      subtitle: " · Managed Server"
      min_width: 54
      verbose: false
      footer: ""
      show_services: true
      show_updates: true
      show_recent_logins: true
      security_priv_only: false
      pubip_url: "https://ifconfig.me"
      script_path: /etc/update-motd.d/10-system-info
      config_path: /etc/motd.conf
      cache_dir: /var/cache/motd
    sshd:
      banner_manage: true
      banner_dropin: /etc/ssh/sshd_config.d/99-motd-banner.conf

  Design notes (from the change-safety baseline):
    - The MOTD script itself is a plain bash file shipped via
      `source: salt://motd/10-system-info.sh` — NOT a Jinja template. The
      runtime configuration lives in /etc/motd.conf which the script sources
      at startup. This keeps render-time logic out of the hot path and lets
      the standalone installer reuse the exact same script and config file.
    - /etc/motd.conf values are emitted with `|tojson` so quoting is correct
      for any printable ASCII string. We additionally reject backslash,
      backtick and `$` at render time — those would survive JSON quoting and
      reach a shell `source` of the file. Same defence-in-depth posture as
      the control-character reject in banner.sls.
    - The cache directory is /var/cache/motd (root-owned, 0755). Never use
      /tmp / /var/tmp / /dev/shm — those are world-writable and would let any
      local user pre-plant a cache file that the root MOTD script reads back
      on the next login (LPE / terminal-injection vector). The legacy
      /tmp/.motd_pubip cache from the pre-audit era is removed unconditionally.
    - The sshd reload is gated by `sshd -t` validation. If validation fails,
      Salt marks the validate state failed and the reload state never runs.
      The drop-in `require`s login_banner_net so a missing /etc/issue.net
      cannot ship a Banner directive that would point at nothing.
    - Ubuntu default update-motd.d scripts are neutralised via `replace: False`
      + an `onlyif` test, which clears the executable bit without touching
      package-managed content. This is reversible by `apt --reinstall` and
      survives package upgrades cleanly.
-#}

{#- =========================================================================
    1. Pillar intake + input sanitation
    ========================================================================= -#}

{%- set _company_raw = salt['pillar.get']('login_banner:company_name', 'Managed Server') %}
{#- `contact` is intentionally not read here because Salt uses the pillar
    tree as the persistent source of truth: CONTACT lives in the pillar,
    not in /etc/motd.conf, so there is nothing to re-persist on the next
    state.apply. The standalone installer (install.sh) diverges here by
    design — it uses /etc/motd.conf as its own persistence layer for
    re-runs without flags, so it writes CONTACT into the runtime config
    even though the runtime MOTD script (motd/10-system-info.sh) does
    not parse CONTACT. Two layers, two persistence models; see the
    Architecture section of salt/README.md for the full rationale. -#}

{%- set _motd_subtitle          = salt['pillar.get']('login_banner:motd:subtitle', ' · Managed Server') %}
{%- set _motd_min_width         = salt['pillar.get']('login_banner:motd:min_width', 54) | int %}
{%- set _motd_verbose           = salt['pillar.get']('login_banner:motd:verbose', False) %}
{%- set _motd_footer            = salt['pillar.get']('login_banner:motd:footer', '') %}
{%- set _motd_show_services     = salt['pillar.get']('login_banner:motd:show_services', True) %}
{%- set _motd_show_updates      = salt['pillar.get']('login_banner:motd:show_updates', True) %}
{%- set _motd_show_recent_logins = salt['pillar.get']('login_banner:motd:show_recent_logins', True) %}
{#- security_priv_only — when True, the runtime motd script suppresses
    the Security / Currently-banned blocks for users that are NOT in
    sudo / wheel / admin. Opt-in for shared bastion hosts; default False
    preserves the legacy "everyone sees everything" behaviour on single-
    admin VMs. 1:1 parity with install.sh --motd-security-priv-only. -#}
{%- set _motd_security_priv_only = salt['pillar.get']('login_banner:motd:security_priv_only', False) %}
{%- set _motd_pubip_url         = salt['pillar.get']('login_banner:motd:pubip_url', 'https://ifconfig.me') %}
{%- set _motd_script_path       = salt['pillar.get']('login_banner:motd:script_path', '/etc/update-motd.d/10-system-info') %}
{%- set _motd_config_path       = salt['pillar.get']('login_banner:motd:config_path', '/etc/motd.conf') %}
{%- set _motd_cache_dir         = salt['pillar.get']('login_banner:motd:cache_dir', '/var/cache/motd') %}

{%- set _sshd_banner_manage = salt['pillar.get']('login_banner:sshd:banner_manage', True) %}
{%- set _sshd_banner_dropin = salt['pillar.get']('login_banner:sshd:banner_dropin', '/etc/ssh/sshd_config.d/99-motd-banner.conf') %}
{#- Separate reload toggle. install.sh distinguishes between "write the
    drop-in" and "reload sshd now"; keeping a dedicated key here mirrors
    that split, which matters for change-window semantics: operators may
    want Salt to stage the drop-in but only reload during an approved
    maintenance window. Default True. -#}
{%- set _sshd_reload_toggle = salt['pillar.get']('login_banner:sshd:reload', True) %}

{#- Pristine-backup feature (see banner.sls for the why). motd.sls backs
    up the runtime config, the MOTD script, and the sshd drop-in — three
    artefacts that the state can overwrite. The pillar flag is shared
    with banner.sls so enabling it once in pillar covers both sub-states
    consistently. -#}
{%- set _backup_enabled = salt['pillar.get']('login_banner:backup:enabled', False) %}
{%- set _backup_dir     = salt['pillar.get']('login_banner:backup:dir', '/var/backups/motd') %}

{#- Shell-injection guard for paths embedded in cmd.run backup commands.
    Every pillar value that reaches a shell substitution below goes
    through this check. Called after the pillar.get assignments so a
    tainted value fails at render time rather than at shell execution
    time on the minion.

    Character set kept in lockstep with install.sh's `_validate_abs_path`
    + `_reject_shell_meta`:
      - \\ ` $ "           reject broken-out double-quoted literals
      - '                  same rationale, even though cmd.run uses unquoted
                           substitution today (defence in depth)
      - whitespace/C0      break sshd_config / cp arg splitting / TTY escapes
      - |                  sed delimiter in install.sh's MOTD_CONFIG_PATH
                           render path; mirrored here for schema parity so
                           a path install.sh rejects also fails the Salt
                           formula
      - &                  shell background operator in cmd.run, and sed
                           replacement-string backreference on the install.sh
                           side. Real shell-injection here because cmd.run
                           interpolates these into a plain `cp -P -- <path>
                           ...` command; `/foo/bad&path` would background
                           `cp -P -- /foo/bad` and execute `path
                           /foo/backup/…` as a second statement. -#}
{%- macro _check_path(name, value) -%}
{%- if not value.startswith('/') -%}
{{ raise('motd: ' ~ name ~ ' must be an absolute path, got ' ~ value) }}
{%- endif -%}
{%- for _forbid in ['\\', '`', '$', '"', "'", ' ', '\t', '\n', '\r', '|', '&'] -%}
{%- if _forbid in value -%}
{{ raise('motd: ' ~ name ~ ' contains a forbidden character (whitespace, shell meta, or control) — rejected to keep the backup pipeline safe') }}
{%- endif -%}
{%- endfor -%}
{%- endmacro %}

{{- _check_path('motd:script_path', _motd_script_path) -}}
{{- _check_path('motd:config_path', _motd_config_path) -}}
{{- _check_path('motd:cache_dir',   _motd_cache_dir)   -}}
{{- _check_path('sshd:banner_dropin', _sshd_banner_dropin) -}}

{%- if _backup_enabled %}
  {%- if _backup_dir.startswith('/tmp/') or _backup_dir.startswith('/var/tmp/') or _backup_dir.startswith('/dev/shm/') %}
    {{ raise('motd: backup:dir must not live under /tmp, /var/tmp, or /dev/shm — world-writable paths are an LPE vector') }}
  {%- endif %}
  {{- _check_path('backup:dir', _backup_dir) -}}
{%- endif %}

{#- Reject world-writable cache prefixes: the runtime MOTD script reads
    cache files as root on every login, and an attacker-plantable cache
    file is a terminal-injection / LPE vector. Same posture install.sh
    already enforces via _validate_abs_path + the comment block at the
    top of this file. -#}
{%- if _motd_cache_dir.startswith('/tmp/') or _motd_cache_dir.startswith('/var/tmp/') or _motd_cache_dir.startswith('/dev/shm/') %}
  {{ raise('motd: motd:cache_dir must not live under /tmp, /var/tmp, or /dev/shm — world-writable paths are an LPE vector') }}
{%- endif %}

{#- basename helpers — no native `basename` filter in Jinja. -#}
{%- set _motd_script_base = _motd_script_path.split('/') | last %}
{%- set _motd_config_base = _motd_config_path.split('/') | last %}
{%- set _sshd_dropin_base = _sshd_banner_dropin.split('/') | last %}

{#- Read banner_enabled from the shared namespace. The sshd drop-in
    section below hard-`require`s the `login_banner_net` state ID
    produced by the sibling banner.sls — that state only exists when
    banner.sls is actually included, which init.sls only does when
    `banner_enabled` is truthy. A config of `banner_enabled=false` +
    `sshd:banner_manage=true` would compile-error on "state ID not
    found" because motd.sls would reference a state that the highstate
    does not contain. We raise a render-time error up front rather than
    silently skipping the drop-in: skip-by-default used to leave the
    operator with a "configured but not deployed" state nobody could
    see in salt output. Explicit error at pillar-parse time makes the
    mismatch discoverable. -#}
{%- set _banner_enabled = salt['pillar.get']('login_banner:banner_enabled', True) %}
{%- if _sshd_banner_manage and not _banner_enabled %}
  {{ raise('motd: sshd:banner_manage=true requires banner_enabled=true — cannot point sshd Banner at a /etc/issue.net file that banner.sls will not write. Either set banner_enabled=true or set sshd:banner_manage=false.') }}
{%- endif %}

{#- Reject characters that would survive JSON-quoting and break out of the
    bash `source` of /etc/motd.conf:
      - backslash:  \"  becomes  ", terminating the string
      - backtick:   `cmd` runs cmd
      - dollar:     $(cmd) or $VAR expansion
      - double quote: would terminate the surrounding "..." literal
      - control chars / DEL: as in banner.sls, would reach a TTY
      - length cap: per-key (see _KEY_LIMITS below)
    Whitelist-by-rejection is the same posture as banner.sls control-char
    rejection. With all four shell-active metacharacters rejected up front,
    the _bashq macro below can emit a simple "..." literal and be safe.

    Length limits are kept in lockstep with install.sh's readonly
    MAX_*_LEN constants. The standalone and salt variants must share
    the same schema — otherwise a pillar that the salt formula accepts
    cannot be reproduced via `install.sh --motd-subtitle`. -#}
{%- set _MAX_VAL_LEN = 256 %}
{%- set _KEY_LIMITS = {
      'motd:subtitle':     64,
      'motd:footer':      128,
      'company_name':      64,
} %}
{%- set _shell_meta = ['\\', '`', '$', '"'] %}
{#- Cast to string up front so non-string pillar values (int, bool, None)
    still go through length and metacharacter validation. Without the
    cast, `value is string` gated the checks on type and a numeric pillar
    value like `motd:min_width: 54` bypassed the whole macro — safe by
    coincidence, but other types (list, None) could render as "[1, 2]"
    or "None" into /etc/motd.conf and defeat the quoting contract. -#}
{#- Also reject Unicode C1 control codepoints (U+0080–U+009F). A
    byte-by-byte `_bytes[0]` scan alone is always 0xC2 for any 2-byte
    UTF-8 sequence, so a pillar value containing the bare CSI starter
    `"\u009b"` (= UTF-8 0xC2 0x9B) would pass the C0/DEL filter and
    render into /etc/motd.conf. On a terminal with allowC1Printable=true
    the byte sequence is interpreted as a real CSI escape. The extra
    branch below matches any 2-byte sequence whose first byte is 0xC2
    and whose second byte is in 0x80–0x9F — exactly the UTF-8 encoding
    of U+0080–U+009F. Mirror of the iconv round-trip in install.sh's
    `_is_printable_safe`. -#}
{%- macro _check(name, value) -%}
{%- set _value = value | string -%}
{%- set _limit = _KEY_LIMITS.get(name, _MAX_VAL_LEN) -%}
{%- if _value | length > _limit -%}
{{ raise('motd: ' ~ name ~ ' exceeds ' ~ _limit ~ ' characters') }}
{%- endif -%}
{%- for _ch in _value -%}
{%- set _bytes = _ch.encode('utf-8') -%}
{%- set _o = _bytes[0] if _bytes | length == 1 else 255 -%}
{%- if _o < 32 or _o == 127 -%}
{{ raise('motd: ' ~ name ~ ' contains a control character') }}
{%- endif -%}
{%- if _bytes | length == 2 and _bytes[0] == 0xC2 and _bytes[1] >= 0x80 and _bytes[1] <= 0x9F -%}
{{ raise('motd: ' ~ name ~ ' contains a C1 control codepoint (U+0080–U+009F) — refusing to render /etc/motd.conf') }}
{%- endif -%}
{%- if _ch in _shell_meta -%}
{{ raise('motd: ' ~ name ~ ' contains shell metacharacter (\\, `, $, or ") — refusing to render /etc/motd.conf') }}
{%- endif -%}
{%- endfor -%}
{%- endmacro %}

{#- _bashq — emit a value as a bash-safe double-quoted literal.
    Pre-conditions guaranteed by _check above:
      - no backslash, backtick, dollar, or double quote
      - no control characters or DEL
    Under those constraints, "<value>" is a valid bash literal that
    expands to the literal value with no shell interpretation. UTF-8 is
    preserved as-is (jinja's |tojson would escape it to \uXXXX, which
    bash treats as a literal six-character sequence — wrong). -#}
{%- macro _bashq(value) -%}
"{{ value }}"
{%- endmacro %}

{{- _check('motd:subtitle', _motd_subtitle) -}}
{{- _check('motd:footer', _motd_footer) -}}
{{- _check('motd:pubip_url', _motd_pubip_url) -}}
{{- _check('motd:script_path', _motd_script_path) -}}
{{- _check('motd:config_path', _motd_config_path) -}}
{{- _check('motd:cache_dir', _motd_cache_dir) -}}
{{- _check('company_name', _company_raw) -}}

{#- Upper cap matches the standalone install.sh MAX_WIDTH constant
    (120). Both sides refuse the same range so a pillar that renders
    through Salt also validates under install.sh. -#}
{%- if _motd_min_width < 20 or _motd_min_width > 120 %}
  {{ raise('motd: motd:min_width must be between 20 and 120, got ' ~ _motd_min_width) }}
{%- endif %}

{#- Ubuntu default update-motd.d scripts to neutralise. The list is the
    union of what 22.04 and 24.04 ship out of the box and is kept in
    lockstep with install.sh's `_ubuntu_motd_defaults()`. The `onlyif:
    test -f` guard handles hosts where a given script does not exist.

    `50-landscape-sysinfo` is intentionally NOT in this list — it is a
    symlink to a package-managed wrapper, and the regular `file.managed:
    replace: False, mode: '0644'` state below would chmod through the
    symlink (just as a naive `chmod 0644` would in the standalone
    installer). Symlinks are handled separately by the dedicated
    `login_banner_motd_neutralise_landscape_sysinfo` state below, which
    replaces the symlink itself with an empty stub. -#}
{%- set _ubuntu_default_motd = [
      '00-header',
      '10-help-text',
      '50-motd-news',
      '80-esm',
      '80-livepatch',
      '85-fwupd',
      '88-esm-announce',
      '90-updates-available',
      '91-contract-ua-esm-status',
      '91-release-upgrade',
      '92-unattended-upgrades',
      '95-hwe-eol',
      '97-overlayroot',
      '98-fsck-at-reboot',
      '98-reboot-required',
] %}

{# =========================================================================
   2. State declarations — cache + marker
   ========================================================================= #}

{% if _backup_enabled %}
{# Pristine backup directory — shared semantics with banner.sls. Both
   sub-states create the SAME directory (`login_banner:backup:dir`) but
   under DIFFERENT state IDs (`login_banner_backup_dir_banner` vs
   `login_banner_backup_dir_motd`) because Salt does NOT merge identical
   state declarations across included SLS files — it raises "Conflicting
   ID" at highstate compile time. Both `file.directory` calls are
   idempotent, so whichever runs second is a no-op. #}
login_banner_backup_dir_motd:
  file.directory:
    - name: {{ _backup_dir }}
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True

{# Backup the unified config, the runtime script, and the sshd drop-in
   if they exist on disk. `unless` short-circuits every apply after the
   first so the copy is idempotent. cp -P preserves any symlinks the
   operator may have put in place — rare for these paths, but the cost
   of defending against it is zero. See banner.sls for the full
   rationale on cmd.run vs file.copy (shutil.copy dereferences links). #}
{# .created marker parity with install.sh's backup_file(). Without
   this marker, a second state.apply with a changed pillar would
   capture the first apply's output as "pristine" and uninstall.sh
   would then restore motd-generated content as if it were the
   pre-install state. See salt/banner.sls for the identical pattern on
   /etc/issue and /etc/issue.net.

   Three managed files live under motd.sls:
     - {{ _motd_config_path }}        (unified config)
     - {{ _motd_script_path }}        (runtime MOTD script)
     - {{ _sshd_banner_dropin }}      (sshd drop-in, only when
                                       sshd:banner_manage=true)
   Each gets its own marker state, gated by both `_backup_enabled`
   (this whole block) and the same onlyif/unless logic as the banner
   side: drop the marker only when the target file is absent AND no
   pristine.bak / marker already exists. #}
login_banner_created_marker_motd_config:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/{{ _motd_config_base }}.created &&
        chmod 0600 {{ _backup_dir }}/{{ _motd_config_base }}.created
    - onlyif: test ! -e {{ _motd_config_path }} -a ! -L {{ _motd_config_path }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _motd_config_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
    - require_in:
        - file: login_banner_motd_config

login_banner_backup_motd_config:
  cmd.run:
    - name: cp -P -- {{ _motd_config_path }} {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak
    - onlyif: test -e {{ _motd_config_path }} -o -L {{ _motd_config_path }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _motd_config_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
        - cmd: login_banner_created_marker_motd_config
    - require_in:
        - file: login_banner_motd_config

{# .latest.bak symlinks — parity with the standalone install.sh and
   uninstall.sh. See banner.sls for the full rationale (the standalone
   uninstaller follows .latest.bak exactly one level to find the most
   recent pristine backup; we mirror the layout so a host that flips
   between Salt and standalone management never loses its backup
   discoverability). force: True covers the rare case of a
   pre-existing regular file at the same name; onlyif gates against
   a missing pristine.bak so we never leave a dangling symlink. #}
login_banner_backup_motd_config_latest:
  file.symlink:
    - name: {{ _backup_dir }}/{{ _motd_config_base }}.latest.bak
    - target: {{ _motd_config_base }}.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/{{ _motd_config_base }}.pristine.bak
    - require:
        - cmd: login_banner_backup_motd_config

{# See login_banner_created_marker_motd_config above for the rationale.
   Same pattern for the runtime MOTD script. #}
login_banner_created_marker_motd_script:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/{{ _motd_script_base }}.created &&
        chmod 0600 {{ _backup_dir }}/{{ _motd_script_base }}.created
    - onlyif: test ! -e {{ _motd_script_path }} -a ! -L {{ _motd_script_path }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _motd_script_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
    - require_in:
        - file: login_banner_motd_script

login_banner_backup_motd_script:
  cmd.run:
    - name: cp -P -- {{ _motd_script_path }} {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak
    - onlyif: test -e {{ _motd_script_path }} -o -L {{ _motd_script_path }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _motd_script_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
        - cmd: login_banner_created_marker_motd_script
    - require_in:
        - file: login_banner_motd_script

login_banner_backup_motd_script_latest:
  file.symlink:
    - name: {{ _backup_dir }}/{{ _motd_script_base }}.latest.bak
    - target: {{ _motd_script_base }}.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/{{ _motd_script_base }}.pristine.bak
    - require:
        - cmd: login_banner_backup_motd_script
{% endif %}

login_banner_motd_cache_dir:
  file.directory:
    - name: {{ _motd_cache_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

{# Remove the legacy world-writable cache file from the pre-audit era. Any
   file under /tmp/.motd_pubip is a terminal-injection vector and must not
   be allowed to linger. #}
login_banner_motd_cache_legacy_cleanup:
  file.absent:
    - name: /tmp/.motd_pubip

{# The MOTD script reads this file's mtime to display
   "Salt: last apply YYYY-MM-DD HH:MM". `file.touch` updates mtime on every
   state.apply, which is exactly the semantic we want. #}
login_banner_motd_marker:
  file.touch:
    - name: {{ _motd_cache_dir }}/salt-status
    - require:
        - file: login_banner_motd_cache_dir

{# =========================================================================
   3. State declarations — runtime config + script
   ========================================================================= #}

{# /etc/motd.conf is the runtime config the standalone bash MOTD script
   sources at every login. We render it inline here so the script itself
   stays a plain (Jinja-free) artifact and can be byte-identical to the
   one shipped by the standalone installer. Values are emitted via |tojson
   so quoting is correct for any printable ASCII string; the _check macro
   above already rejected the dangerous metacharacters at parse time. #}
login_banner_motd_config:
  file.managed:
    - name: {{ _motd_config_path }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # {{ _motd_config_path }} — rendered by Salt formula 'motd'
        # https://github.com/EXT-IT/motd
        # Do not edit — changes will be overwritten on next state.apply.
        #
        # Shared with the standalone installer — both read this file.

        # -- branding (shared with banner) --
        # CONTACT is intentionally NOT emitted here. Salt uses the pillar
        # tree as the source of truth: CONTACT lives in the pillar and
        # is consumed only by banner.sls, so there is nothing to write
        # into /etc/motd.conf. The standalone installer takes a different
        # path — it writes CONTACT into /etc/motd.conf because that file
        # is its own persistence layer for re-runs without flags. Both
        # are correct for their architecture; only the place CONTACT is
        # stored differs. See the Architecture section of salt/README.md
        # and the comment block at the top of this file for details.
        COMPANY_NAME={{ _bashq(_company_raw) }}

        # -- motd --
        MOTD_SUBTITLE={{ _bashq(_motd_subtitle) }}
        MOTD_MIN_WIDTH={{ _motd_min_width }}
        MOTD_VERBOSE={{ 'true' if _motd_verbose else 'false' }}
        MOTD_FOOTER={{ _bashq(_motd_footer) }}
        MOTD_SHOW_SERVICES={{ 'true' if _motd_show_services else 'false' }}
        MOTD_SHOW_UPDATES={{ 'true' if _motd_show_updates else 'false' }}
        MOTD_SHOW_RECENT_LOGINS={{ 'true' if _motd_show_recent_logins else 'false' }}
        MOTD_SECURITY_PRIV_ONLY={{ 'true' if _motd_security_priv_only else 'false' }}
        MOTD_PUBIP_URL={{ _bashq(_motd_pubip_url) }}
        MOTD_CACHE_DIR={{ _bashq(_motd_cache_dir) }}

{# The MOTD script is a plain bash file (no Jinja). It is sourced unchanged
   from the formula's motd/ directory. Note the absence of `template: jinja`
   — that is intentional. The script reads /etc/motd.conf at runtime, so
   config changes do not require a state apply to take effect (although the
   marker mtime would still be stale). `require` makes the config file the
   hard prerequisite. #}
login_banner_motd_script:
  file.managed:
    - name: {{ _motd_script_path }}
    - source: salt://motd/10-system-info.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
        - file: login_banner_motd_config

{# profile.d wrapper — the sole MOTD display path.

   The runtime MOTD script exits immediately when stdout is not a TTY
   ([ -t 1 ] || exit 0). pam_motd redirects stdout to /run/motd.dynamic
   (a regular file), so the script produces no output via pam_motd. The
   profile.d wrapper runs in the interactive login shell where stdout IS
   the terminal, so the coloured MOTD renders exactly once.

   Guards:
     * `case $-` — only interactive shells (scp/rsync/CI skip this)
     * `$PS1`    — double-check for interactive mode
     * The script itself gates on [ -t 1 ], so even a piped `bash -l`
       gets no output.

   Naming: `zz-` prefix ensures this runs after all other profile.d
   scripts (e.g. system hardening that sets TMOUT, umask).

   Kept in lockstep with install.sh's profiled_content block. #}
login_banner_motd_profiled:
  file.managed:
    - name: /etc/profile.d/zz-motd.sh
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by motd (https://github.com/EXT-IT/motd) — do not edit.
        # Render the dynamic MOTD with colours at interactive login.
        # pam_motd is bypassed (script exits when stdout is not a TTY)
        # so this wrapper is the sole MOTD display path.
        case $- in *i*) ;; *) return ;; esac
        [ -n "$PS1" ] || return
        [ -x "{{ _motd_script_path }}" ] && "{{ _motd_script_path }}"
    - require:
        - file: login_banner_motd_script

{# =========================================================================
   4. State declarations — neutralise Ubuntu default update-motd.d scripts
   ========================================================================= #}

{# We do NOT delete or overwrite these files: they are package-managed by
   base-files / update-notifier-common / etc, and reinstalling those packages
   must restore them. We only drop the executable bit. `replace: False` keeps
   the file content untouched; `mode: '0644'` clears +x. The `onlyif` guard
   ensures the state is a no-op on hosts where the script does not exist
   (e.g. minimal containers). The additional `! test -L` guard ensures we
   never accidentally chmod through a symlink — if a future Ubuntu release
   adds a symlinked default we will leave it alone here and the operator
   can add a dedicated `*_neutralise_*` state below for the new entry.
   Generated state IDs are unique per script. #}
{% for _name in _ubuntu_default_motd %}
{%- set _id_suffix = _name | replace('-', '_') %}
login_banner_motd_disable_{{ _id_suffix }}:
  file.managed:
    - name: /etc/update-motd.d/{{ _name }}
    - user: root
    - group: root
    - mode: '0644'
    - replace: False
    - onlyif:
        - test -f /etc/update-motd.d/{{ _name }}
        - "! test -L /etc/update-motd.d/{{ _name }}"
{% endfor %}

{# Landscape sysinfo symlink replacement.

   /etc/update-motd.d/50-landscape-sysinfo on Ubuntu 24.04 cloud images is
   a symlink to /usr/share/landscape/landscape-sysinfo.wrapper, a
   package-managed file. The naive `chmod 0644` (file.managed +
   replace: False) would follow the symlink and corrupt the wrapper's
   executable bit, tripping `dpkg --verify` and breaking landscape on
   the next package run.

   Replacing the SYMLINK ITSELF with an empty regular file is safe:
   `dpkg -S /etc/update-motd.d/50-landscape-sysinfo` returns "no path
   found" because only the wrapper target is package-owned, not the
   symlink at the update-motd.d/ path. Removing the symlink and writing
   an empty 0644 stub leaves the package-managed wrapper untouched and
   produces a pam_motd no-op (no +x = not executed).

   `force: True` makes file.managed remove a non-file (symlink, dir)
   before writing. The state runs only if the path is currently a
   symlink — once replaced, the path is a regular file and the state
   becomes a no-op (because force: True is harmless on idempotent
   re-applies and the contents already match). #}
login_banner_motd_neutralise_landscape_sysinfo:
  file.managed:
    - name: /etc/update-motd.d/50-landscape-sysinfo
    - user: root
    - group: root
    - mode: '0644'
    - contents: ''
    - force: True
    - onlyif: test -L /etc/update-motd.d/50-landscape-sysinfo

{# =========================================================================
   5. State declarations — sshd_config drop-in for the pre-auth banner
   ========================================================================= #}

{% if _sshd_banner_manage and _banner_enabled %}
{% if _backup_enabled %}
{# .created marker parity with install.sh for the sshd drop-in. Fresh
   hosts do not ship with a drop-in at
   /etc/ssh/sshd_config.d/99-motd-banner.conf, so the marker branch is
   the usual path on first install and the pristine-backup branch only
   fires if a foreign drop-in happened to already live at the same
   path. See login_banner_created_marker_motd_config above. #}
login_banner_created_marker_sshd_dropin:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/{{ _sshd_dropin_base }}.created &&
        chmod 0600 {{ _backup_dir }}/{{ _sshd_dropin_base }}.created
    - onlyif: test ! -e {{ _sshd_banner_dropin }} -a ! -L {{ _sshd_banner_dropin }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _sshd_dropin_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
    - require_in:
        - file: login_banner_sshd_banner_dropin

{# Back up the sshd drop-in file if one already exists. `onlyif`
   guards against the common case of a fresh install (drop-in is not
   yet on disk), and `unless` makes the backup one-shot-per-minion. #}
login_banner_backup_sshd_dropin:
  cmd.run:
    - name: cp -P -- {{ _sshd_banner_dropin }} {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak
    - onlyif: test -e {{ _sshd_banner_dropin }} -o -L {{ _sshd_banner_dropin }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _sshd_dropin_base }}.created
    - require:
        - file: login_banner_backup_dir_motd
        - cmd: login_banner_created_marker_sshd_dropin
    - require_in:
        - file: login_banner_sshd_banner_dropin

login_banner_backup_sshd_dropin_latest:
  file.symlink:
    - name: {{ _backup_dir }}/{{ _sshd_dropin_base }}.latest.bak
    - target: {{ _sshd_dropin_base }}.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/{{ _sshd_dropin_base }}.pristine.bak
    - require:
        - cmd: login_banner_backup_sshd_dropin
{% endif %}

{# Refuse to overwrite an existing drop-in that does not carry our
   `# Managed by motd` marker. Without this guard a
   pillar typo on `login_banner:sshd:banner_dropin` (e.g. pointing at
   /etc/ssh/sshd_config.d/10-allow-root-password-login.conf) would
   silently replace the cloud-init / distro drop-in with our Banner
   directive — `sshd -t` accepts the file because the directive is
   syntactically valid, and on the next reboot the host loses whatever
   the original drop-in was guaranteeing.

   The `unless` test is positive: the cmd.run runs (and aborts the
   highstate via `false`) only when the file exists AND lacks the
   marker. A fresh install (no file yet) and an idempotent re-apply
   (file exists with marker) both skip the abort. The check is
   independent of the pristine backup — even on a host with no backup
   directory, a foreign drop-in is rejected. There is intentionally no
   `force` escape hatch on the Salt side: pillar typos cannot be
   "yes-I-meant-it" handled, the operator must clean up the foreign
   drop-in manually before re-applying state. #}
login_banner_sshd_dropin_safety_check:
  cmd.run:
    - name: |
        set -e
        echo "ERROR: {{ _sshd_banner_dropin }} exists and is not managed by motd" >&2
        echo "       refusing to overwrite a foreign sshd_config drop-in" >&2
        echo "       inspect the file, then either remove it or move it out of sshd_config.d/" >&2
        false
    - onlyif:
        - test -e {{ _sshd_banner_dropin }}
        - "! grep -qF '# Managed by motd' {{ _sshd_banner_dropin }}"
    - require_in:
        - file: login_banner_sshd_banner_dropin

{# Drop-in that activates `Banner /etc/issue.net`. Living under
   /etc/ssh/sshd_config.d/ means we never touch the package-managed
   sshd_config — `Include /etc/ssh/sshd_config.d/*.conf` has been the
   OpenSSH default since 8.2 (Ubuntu 20.04+). The `require` on
   login_banner_net makes the issue.net file a hard precondition: a
   broken banner.sls render will short-circuit before sshd ever sees a
   Banner directive that points at a non-existent file. The cross-state
   require works because Salt state IDs are unique across the compiled
   highstate, not per file.

   Note: this whole section is additionally gated on `_banner_enabled`
   because init.sls only includes banner.sls when the banner is
   enabled, and a `require` on a non-existent state ID would compile-
   error under `banner_enabled=false` + `sshd:banner_manage=true`. #}
login_banner_sshd_banner_dropin:
  file.managed:
    - name: {{ _sshd_banner_dropin }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by motd (https://github.com/EXT-IT/motd) — do not edit.
        # This drop-in enables the /etc/issue.net pre-auth SSH banner.
        Banner /etc/issue.net
    - require:
        - file: login_banner_net

{# `sshd -t -f <candidate>` on a synthetic main config that Includes our
   freshly-written drop-in. A plain `sshd -t` (no -f) tests the LIVE
   sshd_config, which means an unrelated second drop-in that is already
   broken would fail this state and block our reload — while our own
   new drop-in is perfectly fine. Mirroring install.sh's candidate-
   based validation closes that split-state window.

   The candidate file here is the drop-in Salt just wrote, not a
   separate dotfile: Salt does not have a natural "hidden candidate"
   artefact in its state model without significant glue. We accept
   that the drop-in is briefly on disk under its real name before
   validation — the price we pay for staying in pure state-land. A
   concurrent sshd reload in that tiny window would pick up the new
   drop-in directly; if it is broken, sshd keeps running under its
   previous in-memory config until an explicit reload. Both install.sh
   and this Salt path converge on "reload never runs against a broken
   drop-in" as the invariant. #}
login_banner_sshd_validate:
  cmd.run:
    - name: |
        set -e
        _tmp="$(mktemp)"
        trap 'rm -f "$_tmp"' EXIT
        cat /etc/ssh/sshd_config > "$_tmp"
        printf '\nInclude %s\n' {{ _sshd_banner_dropin }} >> "$_tmp"
        sshd -t -f "$_tmp"
    - onchanges:
        - file: login_banner_sshd_banner_dropin

{% if _sshd_reload_toggle %}
login_banner_sshd_reload:
  cmd.run:
    - name: systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    - onchanges:
        - file: login_banner_sshd_banner_dropin
    - require:
        - cmd: login_banner_sshd_validate
{% endif %}
{% endif %}
