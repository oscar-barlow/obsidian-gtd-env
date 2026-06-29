#!/usr/bin/env bash
#
# SessionStart hook: bring Obsidian up for this session (sync vault, launch the
# headless GUI + CLI, load plugins). The heavy, secret-free install lives in the
# environment's Setup-script field (setup-obsidian.sh), which installs the
# `obsidian-up` command this hook calls.
#
set -uo pipefail

if ! command -v obsidian-up >/dev/null 2>&1; then
  echo "session-start: 'obsidian-up' not found — paste setup-obsidian.sh into the" \
       "environment's Setup script field, then start a new session." >&2
  exit 0   # don't block the session
fi

obsidian-up
