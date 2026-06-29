#!/usr/bin/env bash
#
# Stop hook: push vault changes back to Obsidian Sync before the container is
# reclaimed, so the weekly-review note and task edits aren't lost. Safety net —
# a review should still end with an explicit `ob sync`.
#
# Requires the same session secrets as the SessionStart hook (SECRET_EMAIL,
# SECRET_PASSWORD, optional SECRET_MFA) and the network egress policy to allow
# *.obsidian.md (login is api.obsidian.md; data sync is sync-NN.obsidian.md).
#
set -uo pipefail

VAULT_DIR="/home/obs/vault"

command -v ob >/dev/null 2>&1 || exit 0          # nothing to do without the CLI
[ -d "$VAULT_DIR" ] || exit 0
if [ -z "${SECRET_EMAIL:-}" ]; then
  echo "stop-sync: SECRET_EMAIL not set; skipping vault sync." >&2
  exit 0
fi

dbus-run-session -- bash -c '
  echo "" | gnome-keyring-daemon --unlock >/dev/null 2>&1 || true
  MFA_ARG=(); [ -n "${SECRET_MFA:-}" ] && MFA_ARG=(--mfa "$SECRET_MFA")
  ob login --email "$SECRET_EMAIL" --password "$SECRET_PASSWORD" "${MFA_ARG[@]}" >/dev/null 2>&1
  ob sync --path "'"$VAULT_DIR"'"
' || echo "stop-sync: vault sync failed (see above)." >&2
