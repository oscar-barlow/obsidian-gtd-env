#!/usr/bin/env bash
#
# This is what goes in the Claude Code (web) environment's *Setup script*
# field — not scripts/setup-script.sh itself. It fetches and runs the real
# setup script from this repo's default branch on every environment build,
# so editing scripts/setup-script.sh here (commit + merge to master) is
# enough; there's no separate paste-it-into-the-web-UI step anymore.
#
# Trade-off: this floats on master. A broken commit there breaks the next
# environment build until fixed, same as any other push-to-deploy setup.
# Pin to a tag/commit in the URL below instead if you'd rather update
# deliberately.
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/oscar-barlow/obsidian-gtd-env/master/scripts/setup-script.sh \
  -o /tmp/obsidian-gtd-setup-script.sh
bash /tmp/obsidian-gtd-setup-script.sh
