{#-
  motd — Salt sub-state for the pre-auth login banner
         (/etc/issue + /etc/issue.net).

  Purpose: generate a pre-auth warning banner (local console + SSH) from pillar
           data, with zero tenant branding baked into the state. Works on
           Debian/Ubuntu and RHEL family; assumes OpenSSH with pam_motd hooked
           into /etc/pam.d/sshd for local terminals.

  This file is included by init.sls when `login_banner:banner_enabled` is True
  (default). The companion sub-state motd.sls handles the post-login dynamic
  MOTD; both share the same `login_banner:` pillar namespace.

  License:    Apache-2.0
  Copyright:  (c) 2026 EXT IT GmbH
  Repository: https://github.com/EXT-IT/motd

  Pillar schema — see pillar.example.sls for the full documented version.

  login_banner:
    company_name: "Managed Server"
    contact: ""
    language: en                # en|de
    style: double               # double|single|ascii
    min_width: 56
    statute: "§202a StGB"
    statute_ascii: "section 202a StGB"
    issue_file: /etc/issue
    issue_net_file: /etc/issue.net
    clear_motd: true
    sshd_reload: true
    warning_lines_override: []

  Design notes (from the change-safety baseline):
    - BOX_WIDTH is derived from one constant + a `_boxline` macro. Never
      hand-count spaces; an off-by-two shipped that way once.
    - Jinja uses `{%- ... -%}` dash-form with 8-space indent, because Salt
      renders with trim_blocks=False by default. Without the dash you get
      blank lines inside `contents: |` block scalars.
    - The sshd reload watches the issue.net file only and uses `onchanges`,
      so an idempotent `state.apply` is silent.
    - A broken banner must not break sshd: the reload state `require`s the
      file state so a render failure short-circuits before the daemon reloads.

  Top-level pillar namespace `login_banner:` is intentionally retained for
  backwards compatibility with v1 adopters even though the project has been
  renamed to `motd`. Renaming the namespace would break every existing tree.
-#}

{#- =========================================================================
    1. Pillar intake + input sanitation
    ========================================================================= -#}

{%- set _company_raw    = salt['pillar.get']('login_banner:company_name', 'Managed Server') %}
{%- set _contact_raw    = salt['pillar.get']('login_banner:contact', '') %}
{%- set _language       = salt['pillar.get']('login_banner:language', 'en') %}
{%- set _style          = salt['pillar.get']('login_banner:style', 'double') %}
{%- set _min_width      = salt['pillar.get']('login_banner:min_width', 56) | int %}
{%- set _statute_u      = salt['pillar.get']('login_banner:statute', '§202a StGB') %}
{%- set _statute_a      = salt['pillar.get']('login_banner:statute_ascii', 'section 202a StGB') %}
{%- set _issue_file     = salt['pillar.get']('login_banner:issue_file', '/etc/issue') %}
{%- set _issue_net_file = salt['pillar.get']('login_banner:issue_net_file', '/etc/issue.net') %}
{%- set _clear_motd     = salt['pillar.get']('login_banner:clear_motd', True) %}
{%- set _sshd_reload    = salt['pillar.get']('login_banner:sshd_reload', True) %}
{%- set _override       = salt['pillar.get']('login_banner:warning_lines_override', []) %}

{#- Pristine-backup feature: parity with install.sh's `backup_file`. The
    first state.apply captures the pre-install state of every managed
    file into a `<basename>.pristine.bak` under `backup:dir`, and never
    overwrites it on subsequent applies. Disabled by default because
    Salt ran for years without it — flipping the default would produce
    backup dirs on every minion in the fleet. Operators who want
    reversible installs set `login_banner:backup:enabled: True` in
    pillar; `backup:dir` (default /var/backups/motd) must live outside
    world-writable paths and is validated below.
    The standalone install.sh uses the same directory layout and file
    naming so an operator who switches from Salt to install.sh (or vice
    versa) can restore from either side's uninstaller. -#}
{%- set _backup_enabled = salt['pillar.get']('login_banner:backup:enabled', False) %}
{%- set _backup_dir     = salt['pillar.get']('login_banner:backup:dir', '/var/backups/motd') %}

{#- Path validator: the backup cp -P commands embed these pillar values
    in a shell command, so we reject whitespace, shell metacharacters,
    control characters, and relative paths up front. A tainted pillar
    value would otherwise escape into the shell. Called on every path
    pillar key used below.

    Character set kept in lockstep with install.sh's `_validate_abs_path` +
    `_reject_shell_meta`. `|` mirrors install.sh's sed-delimiter reject
    for MOTD_CONFIG_PATH rendering (schema parity). `&` is a real
    shell-injection vector here because cmd.run interpolates the pillar
    value into an unquoted `cp -P --` command: `/foo/bad&path` would
    background `cp -P -- /foo/bad` and execute `path /foo/backup/…` as a
    second statement. -#}
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

{{- _check_path('issue_file',     _issue_file)     -}}
{{- _check_path('issue_net_file', _issue_net_file) -}}

{%- if _backup_enabled %}
  {%- if _backup_dir.startswith('/tmp/') or _backup_dir.startswith('/var/tmp/') or _backup_dir.startswith('/dev/shm/') %}
    {{ raise('motd: backup:dir must not live under /tmp, /var/tmp, or /dev/shm — world-writable paths are an LPE vector') }}
  {%- endif %}
  {{- _check_path('backup:dir', _backup_dir) -}}
{%- endif %}

{#- Reject control characters / ANSI escapes and cap length. Every banner
    string ends up on the pre-auth TTY (/etc/issue + /etc/issue.net), so a
    tampered pillar value could emit OSC / CSI escape sequences — terminal
    injection without authentication. Every text field (company_name,
    contact, statute, statute_ascii, and every warning_lines_override
    element) runs through `_check_text_field` before render; a pillar of
    e.g. `warning_lines_override: ["line\x1b[31m"]` is rejected instead
    of shipping a pre-auth ANSI escape to every minion.

    Length caps are kept in lockstep with install.sh:
      company_name   — 64  (MAX_COMPANY_LEN)
      contact        — 128 (MAX_CONTACT_LEN — email addresses can be long)
      statute        — 128
      statute_ascii  — 128
      warning line   — 128 (MAX_WARNING_LINE_LEN)

    `_check_text_field` is the Jinja counterpart of install.sh's
    `_validate_text_field`. It accepts an empty string so the caller can
    decide whether empty is legal (statute, statute_ascii, override lines
    all accept empty and default to the language preset). -#}
{%- set _MAX_COMPANY_LEN      = 64  %}
{%- set _MAX_CONTACT_LEN      = 128 %}
{%- set _MAX_STATUTE_LEN      = 128 %}
{%- set _MAX_WARNING_LINE_LEN = 128 %}

{#- Control-character scan: iterate character-by-character because neither
    Salt nor stock Jinja ship a regex-reject filter here. The UTF-8 byte
    check mirrors install.sh's `_is_printable_safe`: anything below 0x20
    (C0 control) or exactly 0x7F (DEL) is rejected. Multi-byte UTF-8
    sequences are passed through — the non-ASCII bytes are all ≥ 0x80 so
    they never match the control-char predicate.

    Also reject Unicode C1 control codepoints (U+0080–U+009F). Their
    UTF-8 encoding is 0xC2 0x80 to 0xC2 0x9F, so `_bytes[0]` is always
    0xC2 (= 194) and never trips the C0/DEL filter above. The second
    branch matches any 2-byte sequence whose first byte is 0xC2 and
    whose second byte is in the C1 range. 0x9B is the 8-bit CSI
    starter — terminal injection on terminals where allowC1Printable
    is true. Mirror of the iconv round-trip in install.sh
    `_is_printable_safe` and the matching guard in motd.sls `_check`. -#}
{%- macro _check_text_field(name, value, max_len) -%}
{%- if value | length > max_len -%}
{{ raise('motd: ' ~ name ~ ' exceeds ' ~ max_len ~ ' characters') }}
{%- endif -%}
{%- for _ch in value -%}
{%- set _bytes = _ch.encode('utf-8') -%}
{%- set _o = _bytes[0] if _bytes | length == 1 else 255 -%}
{%- if _o < 32 or _o == 127 -%}
{{ raise('motd: ' ~ name ~ ' contains a control character or ANSI escape') }}
{%- endif -%}
{%- if _bytes | length == 2 and _bytes[0] == 0xC2 and _bytes[1] >= 0x80 and _bytes[1] <= 0x9F -%}
{{ raise('motd: ' ~ name ~ ' contains a C1 control codepoint (U+0080–U+009F) — terminal-injection vector on banners') }}
{%- endif -%}
{%- endfor -%}
{%- endmacro %}

{{- _check_text_field('company_name',  _company_raw, _MAX_COMPANY_LEN) -}}
{{- _check_text_field('contact',       _contact_raw, _MAX_CONTACT_LEN) -}}
{{- _check_text_field('statute',       _statute_u,   _MAX_STATUTE_LEN) -}}
{{- _check_text_field('statute_ascii', _statute_a,   _MAX_STATUTE_LEN) -}}
{%- if _override is iterable and _override is not string and _override is not mapping -%}
{%- for _line in _override -%}
{{- _check_text_field('warning_lines_override[' ~ loop.index0 ~ ']', _line | string, _MAX_WARNING_LINE_LEN) -}}
{%- endfor %}
{%- elif _override %}
  {{ raise('motd: warning_lines_override must be a list, got ' ~ _override | type_debug) }}
{%- endif %}

{%- if _style not in ['double', 'single', 'ascii'] %}
  {{ raise('motd: style must be one of double|single|ascii, got ' ~ _style) }}
{%- endif %}
{%- if _language not in ['en', 'de'] %}
  {{ raise('motd: language must be one of en|de, got ' ~ _language) }}
{%- endif %}

{%- set company_name = _company_raw %}
{%- set contact      = _contact_raw %}

{#- =========================================================================
    2. Warning line composition
    ========================================================================= -#}

{#- Presets for /etc/issue.net (Unicode safe). -#}
{%- set _presets = {
      'en': [
        'WARNING: Authorized access only.',
        'This system is property of ' ~ company_name ~ '.',
        'Unauthorized access is strictly prohibited.',
        'All connections are monitored and logged.',
      ],
      'de': [
        'WARNUNG: Nur autorisierter Zugriff.',
        'Dieses System ist Eigentum von ' ~ company_name ~ '.',
        'Unbefugter Zugriff ist strikt untersagt.',
        'Alle Verbindungen werden überwacht und protokolliert.',
      ],
} %}
{#- Presets for /etc/issue (pure ASCII — boot console may not have a UTF-8
    font loaded). German umlauts are transliterated (ü→ue, ö→oe, ä→ae, ß→ss). -#}
{%- set _presets_ascii = {
      'en': _presets['en'],
      'de': [
        'WARNUNG: Nur autorisierter Zugriff.',
        'Dieses System ist Eigentum von ' ~ company_name ~ '.',
        'Unbefugter Zugriff ist strikt untersagt.',
        'Alle Verbindungen werden ueberwacht und protokolliert.',
      ],
} %}

{%- if _override and _override | length > 0 %}
  {%- set _warning_lines_u = _override %}
  {%- set _warning_lines_a = _override %}
{%- else %}
  {%- set _warning_lines_u = _presets[_language] %}
  {%- set _warning_lines_a = _presets_ascii[_language] %}
{%- endif %}

{#- Contact line rendered only if non-empty. Statute is always appended last.
    The ASCII variant always uses the English prosecution prefix so /etc/issue
    stays 7-bit safe regardless of `language`. -#}
{%- set _prosecuted_en = 'Violations prosecuted under ' %}
{%- set _prosecuted_de = 'Verstöße werden verfolgt nach ' %}
{%- if _language == 'de' and not _override %}
  {%- set _prose_prefix_u = _prosecuted_de %}
{%- else %}
  {%- set _prose_prefix_u = _prosecuted_en %}
{%- endif %}
{%- set _statute_line_u = _prose_prefix_u ~ _statute_u ~ '.' %}
{%- set _statute_line_a = _prosecuted_en ~ _statute_a ~ '.' %}

{%- set _text_lines_unicode = [] %}
{%- set _text_lines_ascii   = [] %}
{%- for _l in _warning_lines_u %}
  {%- do _text_lines_unicode.append(_l) %}
{%- endfor %}
{%- for _l in _warning_lines_a %}
  {%- do _text_lines_ascii.append(_l) %}
{%- endfor %}
{#- Contact label is localised: "Kontakt" on a German banner, "Contact"
    elsewhere. Both labels are 7-bit safe so the ASCII variant mirrors
    the Unicode one. -#}
{%- if _language == 'de' and not _override %}
  {%- set _contact_label = 'Kontakt' %}
{%- else %}
  {%- set _contact_label = 'Contact' %}
{%- endif %}
{%- if contact | length > 0 %}
  {%- do _text_lines_unicode.append(_contact_label ~ ': ' ~ contact) %}
  {%- do _text_lines_ascii.append(_contact_label ~ ': ' ~ contact) %}
{%- endif %}
{%- do _text_lines_unicode.append(_statute_line_u) %}
{%- do _text_lines_ascii.append(_statute_line_a) %}

{#- =========================================================================
    3. BOX_WIDTH — derive from longest line, with bounds
    ========================================================================= -#}

{%- set _MAX_BOX_WIDTH = 120 %}
{#- Jinja scope escape: a plain `{% set %}` inside a for-loop is loop-local
    and does not persist. `namespace()` is the documented idiom. -#}
{%- set _ns = namespace(longest=0) %}
{%- for _l in _text_lines_unicode + _text_lines_ascii %}
  {%- if _l | length > _ns.longest %}
    {%- set _ns.longest = _l | length %}
  {%- endif %}
{%- endfor %}
{%- set _grown    = _ns.longest + 4 %}
{%- set _floor    = [_min_width, _grown] | max %}
{%- set BOX_WIDTH = [_floor, _MAX_BOX_WIDTH] | min %}

{#- =========================================================================
    4. Box character selection
    ========================================================================= -#}

{%- set _corners = {
      'double': ['╔', '╗', '╚', '╝'],
      'single': ['┌', '┐', '└', '┘'],
      'ascii':  ['+', '+', '+', '+'],
} %}
{%- set _horiz = {'double': '═', 'single': '─', 'ascii': '='} %}
{%- set _vert  = {'double': '║', 'single': '│', 'ascii': '|'} %}

{%- set _tl = _corners[_style][0] %}
{%- set _tr = _corners[_style][1] %}
{%- set _bl = _corners[_style][2] %}
{%- set _br = _corners[_style][3] %}
{%- set _h  = _horiz[_style] %}
{%- set _v  = _vert[_style] %}

{%- set _hbar = _h * BOX_WIDTH %}

{#- ASCII ruler is always '=' regardless of style (matches the standalone shell). -#}
{%- set _ruler_ascii = '=' * BOX_WIDTH %}

{#- =========================================================================
    5. _boxline macro — one padding codepath, no hand-counted spaces
    ========================================================================= -#}

{%- macro _boxline(text) -%}
{%- set _pad = BOX_WIDTH - 2 - (text | length) -%}
{%- if _pad < 0 -%}
{%- set _pad = 0 -%}
{%- endif -%}
{{ _v }}{{ '  ' ~ text ~ (' ' * _pad) }}{{ _v }}
{%- endmacro %}

{#- =========================================================================
    6. State declarations
    ========================================================================= -#}

{#- basename helpers for the pristine-backup cmd.run guards. Jinja has no
    native `basename` filter; the split/last idiom is the idiomatic workaround. -#}
{%- set _issue_base = _issue_file.split('/') | last %}
{%- set _issue_net_base = _issue_net_file.split('/') | last %}

{% if _backup_enabled %}
{#- Backup directory. 0700 root:root so only root can enumerate the
    pristine artefacts — some of them may contain operator-written
    content from before the install (e.g. a previous vendor's banner). -#}
login_banner_backup_dir_banner:
  file.directory:
    - name: {{ _backup_dir }}
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True

{# cmd.run instead of file.copy because:
   1. file.copy's underlying shutil.copy follows symlinks by default
      (no follow_symlinks flag exposed through the state runner), which
      would dereference /etc/motd -> /run/motd.dynamic and back up the
      wrong artefact — exactly the C1 symlink bug that install.sh's
      backup_file guards against. `cp -P` preserves the link itself.
   2. `unless` + explicit cp gives us the pristine-only semantics
      without the force/preserve argument dance.
   3. The one-shot copy is idempotent by construction: `unless`
      short-circuits every run after the first, so Salt reports
      "clean" on a second state.apply instead of a spurious Changed.
   The paths embedded below are validated by _check_path at the top
   of this file — no whitespace, no shell metacharacters, no control
   bytes — so the unquoted substitution is safe for this specific set
   of inputs. A future change that widens the accepted pillar shape
   MUST re-audit the shell-injection surface here. #}
{# Distinguish "pre-existing operator file we backed up" from "file we
   created from nothing". Parity with install.sh's backup_file().
   Without this marker, a second state.apply with a changed pillar
   would see the file that *we* wrote on the first apply, capture it as
   "pristine", and leave uninstall with no way to reach the true
   pre-install state. The uninstaller relies on <basename>.created
   markers under BACKUP_DIR to know "this file was motd-created, remove
   it rather than restore".

   The marker state runs only if:
     - the target file does not exist on disk (onlyif)
     - AND neither a pristine.bak nor a .created marker is already
       present in BACKUP_DIR (unless)
   Both conditions mirror install.sh exactly. The cmd.run creates an
   empty marker file + 0600 root:root perms to match install.sh's
   marker layout, so an operator who switches between Salt and
   standalone install.sh never ends up with a marker in the wrong
   state. #}
login_banner_created_marker_issue:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/{{ _issue_base }}.created &&
        chmod 0600 {{ _backup_dir }}/{{ _issue_base }}.created
    - onlyif: test ! -e {{ _issue_file }} -a ! -L {{ _issue_file }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _issue_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _issue_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _issue_base }}.created
    - require:
        - file: login_banner_backup_dir_banner
    - require_in:
        - file: login_banner

login_banner_backup_issue:
  cmd.run:
    - name: cp -P -- {{ _issue_file }} {{ _backup_dir }}/{{ _issue_base }}.pristine.bak
    - onlyif: test -e {{ _issue_file }} -o -L {{ _issue_file }}
    {# Refuse to capture pristine when the .created marker is present:
       the file on disk is our own output from a previous apply, not
       an operator artefact. #}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _issue_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _issue_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _issue_base }}.created
    - require:
        - file: login_banner_backup_dir_banner
        - cmd: login_banner_created_marker_issue
    - require_in:
        - file: login_banner

{# .latest.bak symlink — parity with the standalone install.sh and
   uninstall.sh. The standalone uninstaller follows .latest.bak exactly
   one level to find the most recent pristine backup; the symlink lets
   external tooling (operator scripts, audit pipelines) discover the
   freshest backup without grep'ing names.
   Salt's file.symlink stores the literal target string — relative is
   fine here because the symlink lives next to its target. force: True
   handles the edge case of a pre-existing regular file at the same
   name (rare; standalone uses `ln -sfn` for the same reason).
   onlyif gates against the rare case where the source file did not
   exist on disk: the cmd.run above would have skipped, and we should
   not leave a dangling symlink behind. #}
login_banner_backup_issue_latest:
  file.symlink:
    - name: {{ _backup_dir }}/{{ _issue_base }}.latest.bak
    - target: {{ _issue_base }}.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/{{ _issue_base }}.pristine.bak
    - require:
        - cmd: login_banner_backup_issue

{# Same pattern as login_banner_created_marker_issue, for /etc/issue.net. #}
login_banner_created_marker_issue_net:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/{{ _issue_net_base }}.created &&
        chmod 0600 {{ _backup_dir }}/{{ _issue_net_base }}.created
    - onlyif: test ! -e {{ _issue_net_file }} -a ! -L {{ _issue_net_file }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _issue_net_base }}.created
    - require:
        - file: login_banner_backup_dir_banner
    - require_in:
        - file: login_banner_net

login_banner_backup_issue_net:
  cmd.run:
    - name: cp -P -- {{ _issue_net_file }} {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak
    - onlyif: test -e {{ _issue_net_file }} -o -L {{ _issue_net_file }}
    - unless: >-
        test -e {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak -o
        -L {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak -o
        -e {{ _backup_dir }}/{{ _issue_net_base }}.created
    - require:
        - file: login_banner_backup_dir_banner
        - cmd: login_banner_created_marker_issue_net
    - require_in:
        - file: login_banner_net

login_banner_backup_issue_net_latest:
  file.symlink:
    - name: {{ _backup_dir }}/{{ _issue_net_base }}.latest.bak
    - target: {{ _issue_net_base }}.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/{{ _issue_net_base }}.pristine.bak
    - require:
        - cmd: login_banner_backup_issue_net

{% if _clear_motd %}
{# Marker parity for /etc/motd. On most Debian/Ubuntu installs
   /etc/motd is a symlink to /run/motd.dynamic owned by base-files, so
   the -L test correctly reports pre-existing state and the marker
   branch never fires. The guard is retained for the rare case where
   an operator deleted /etc/motd before first state.apply — the marker
   then tells uninstall.sh to remove the blank file instead of leaving
   our empty stub on disk. #}
login_banner_created_marker_motd:
  cmd.run:
    - name: >-
        : > {{ _backup_dir }}/motd.created &&
        chmod 0600 {{ _backup_dir }}/motd.created
    - onlyif: test ! -e /etc/motd -a ! -L /etc/motd
    - unless: >-
        test -e {{ _backup_dir }}/motd.pristine.bak -o
        -L {{ _backup_dir }}/motd.pristine.bak -o
        -e {{ _backup_dir }}/motd.created
    - require:
        - file: login_banner_backup_dir_banner
    - require_in:
        - file: login_banner_static_motd_clear

login_banner_backup_motd:
  cmd.run:
    - name: cp -P -- /etc/motd {{ _backup_dir }}/motd.pristine.bak
    - onlyif: test -e /etc/motd -o -L /etc/motd
    - unless: >-
        test -e {{ _backup_dir }}/motd.pristine.bak -o
        -L {{ _backup_dir }}/motd.pristine.bak -o
        -e {{ _backup_dir }}/motd.created
    - require:
        - file: login_banner_backup_dir_banner
        - cmd: login_banner_created_marker_motd
    - require_in:
        - file: login_banner_static_motd_clear

login_banner_backup_motd_latest:
  file.symlink:
    - name: {{ _backup_dir }}/motd.latest.bak
    - target: motd.pristine.bak
    - force: True
    - onlyif: test -e {{ _backup_dir }}/motd.pristine.bak
    - require:
        - cmd: login_banner_backup_motd
{% endif %}
{% endif %}

login_banner:
  file.managed:
    - name: {{ _issue_file }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        {{ _ruler_ascii }}
        {%- for _l in _text_lines_ascii %}
        {{ '  ' ~ _l }}
        {%- endfor %}
        {{ _ruler_ascii }}

login_banner_net:
  file.managed:
    - name: {{ _issue_net_file }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        {{ _tl }}{{ _hbar }}{{ _tr }}
        {%- for _l in _text_lines_unicode %}
        {{ _boxline(_l) }}
        {%- endfor %}
        {{ _bl }}{{ _hbar }}{{ _br }}

{% if _clear_motd %}
{#- Renamed from `login_banner_motd_clear` to make the scope unambiguous when
    motd.sls is also active. This state only blanks the static /etc/motd file;
    the dynamic MOTD script lives under /etc/update-motd.d/ and is owned by
    motd.sls. Both can co-exist.
    Note: like install.sh, this state will clobber a /etc/motd symlink (the
    Debian/Ubuntu pam_motd default) and replace it with an empty regular
    file. Enable `login_banner:backup:enabled` to capture the symlink via
    `cp -P` into the pristine backup directory first. -#}
login_banner_static_motd_clear:
  file.managed:
    - name: /etc/motd
    - user: root
    - group: root
    - mode: '0644'
    - contents: ''
{% endif %}

{% if _sshd_reload %}
{#- Validate the LIVE sshd_config before reloading on banner changes.
    Without a `sshd -t` guard a broken drop-in in an unrelated file
    elsewhere in sshd_config.d/ would take effect on reload even though
    the banner change itself was fine. Running `sshd -t` on the live
    config here is weaker than install.sh's candidate-based validation
    (we cannot test the issue.net file in isolation — it's already
    referenced by a drop-in sshd currently loads), but it does catch the
    "second drop-in broken, banner change would trigger a reload into a
    broken config" regression.
    Renamed from `login_banner_sshd_reload` to avoid an ID collision with
    the sshd reload state in motd.sls (which reloads on changes to the
    sshd_config drop-in). Both reload states are gated by `onchanges`
    against different files, so they fire independently and never
    duplicate work. -#}
login_banner_net_sshd_validate:
  cmd.run:
    - name: sshd -t
    - onchanges:
        - file: login_banner_net
    - require:
        - file: login_banner_net

login_banner_net_sshd_reload:
  cmd.run:
    - name: systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    - onchanges:
        - file: login_banner_net
    - require:
        - cmd: login_banner_net_sshd_validate
{% endif %}
