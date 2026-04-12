{#-
  motd — Salt formula entry point.

  Thin include wrapper. Conditionally pulls in the two sub-states based on
  pillar flags `login_banner:banner_enabled` and `login_banner:motd_enabled`,
  both of which default to True. A minimal pillar therefore gets both the
  pre-auth login banner (banner.sls) and the post-login dynamic MOTD
  (motd.sls).

  Set `login_banner:motd_enabled: false` for a banner-only deployment
  (paranoid mode) or `login_banner:banner_enabled: false` for a MOTD-only
  deployment.

  When a sub-state is not included, none of its state IDs are present in
  the compiled highstate, so a partial deployment applies cleanly without
  triggering "state ID not found" errors.

  Top-level pillar namespace `login_banner:` is intentionally retained for
  backwards compatibility with v1 adopters even though the project has been
  renamed to `motd`. Renaming the namespace would break every existing tree.

  License:    Apache-2.0
  Copyright:  (c) 2026 EXT IT GmbH
  Repository: https://github.com/EXT-IT/motd
-#}

{%- set _banner_enabled = salt['pillar.get']('login_banner:banner_enabled', True) %}
{%- set _motd_enabled   = salt['pillar.get']('login_banner:motd_enabled', True) %}

{%- if not _banner_enabled and not _motd_enabled %}
  {{ raise('motd: both banner_enabled and motd_enabled are False — refusing to apply an empty formula') }}
{%- endif %}

include:
{%- if _banner_enabled %}
  - .banner
{%- endif %}
{%- if _motd_enabled %}
  - .motd
{%- endif %}
