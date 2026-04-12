# =============================================================================
# motd — minimal pillar example
# -----------------------------------------------------------------------------
# Mirrors examples/config-minimal.conf at the standalone repo root: the
# handful of fields most operators actually want to set, with everything
# else falling back to a sensible default.
#
# Banner: ASCII /etc/issue + Unicode /etc/issue.net with the EN warning
#         lines and the §202a StGB statute.
# MOTD:   default branding (" · Managed Server" subtitle), services /
#         updates / recent-logins all on, motd:verbose off (kernel and
#         public IP hidden — CIS L1 §1.7.x).
# sshd:   drop-in writes Banner /etc/issue.net under sshd_config.d/.
#
# CLI parity (standalone installer):
#     sudo ./install.sh --config examples/config-minimal.conf
# =============================================================================

login_banner:
  company_name: "Acme Corp"
  contact: "ops@acme.example"
