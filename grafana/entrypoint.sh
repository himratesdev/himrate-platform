#!/bin/sh
# BUG-010 PR1 hotfix #7: Grafana entrypoint env mapping.
#
# Reason: Kamal `clear:` env block writes literal strings — `$VAR` syntax NOT
# expanded (Kamal не делает shell substitution). My deploy.yml had:
#   GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $GRAFANA_OIDC_CLIENT_ID
# This sets literal string "$GRAFANA_OIDC_CLIENT_ID" в container env, NOT actual value.
#
# Solution: pass GRAFANA_* secrets через `secret:` block (Kamal substitutes properly),
# then этот script maps GRAFANA_* → GF_* env names before exec'ing grafana.
# Grafana reads GF_* env vars natively per its config conventions.

set -e

# Map repo-secret names → Grafana-native env var names
export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER}"
export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"
export GF_AUTH_GENERIC_OAUTH_CLIENT_ID="${GRAFANA_OIDC_CLIENT_ID}"
export GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${GRAFANA_OIDC_CLIENT_SECRET}"

# Hand off к original Grafana entrypoint
exec /run.sh
