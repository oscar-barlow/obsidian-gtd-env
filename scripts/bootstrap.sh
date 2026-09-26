#!/usr/bin/env bash
#
# This is what goes in the Claude Code (web) environment's *Setup script*
# field — not scripts/setup-script.sh itself. It resolves the latest
# `live-YYYY-MM-DD` tag in this repo and fetches + runs scripts/setup-script.sh
# as of that tag, so:
#   - master can move freely (WIP, review, whatever) without touching what
#     new environments build from.
#   - "deploy" is a deliberate act: cut a `live-YYYY-MM-DD` tag (e.g.
#     `git tag live-$(date +%F) && git push origin live-$(date +%F)`) once a
#     change has been reviewed/merged and you actually want it live. The next
#     environment build then picks it up automatically — no paste into the
#     web UI, no edit to this file.
#   - lexicographic sort works here because YYYY-MM-DD is fixed-width and
#     zero-padded, so plain `sort`/`tail -1` finds the newest date correctly.
#     Same-day re-releases (`make tag-live`) add a zero-padded `.02`, `.03`, ...
#     suffix, which sorts after the bare tag and before the next day's, so
#     this still picks the newest -- see scripts/tag-live.sh.
#
# `git ls-remote` (not the GitHub API) so this needs no auth on a public repo
# and isn't subject to the API's tighter unauthenticated rate limit.
set -euo pipefail
REPO_URL="https://github.com/oscar-barlow/obsidian-gtd-env.git"
TAG="$(git ls-remote --tags --refs "${REPO_URL}" 'live-*' \
  | sed 's#.*refs/tags/##' \
  | sort \
  | tail -1)"
if [ -z "${TAG}" ]; then
  echo "bootstrap: no live-YYYY-MM-DD tag found in ${REPO_URL} -- cut one first (git tag live-\$(date +%F) && git push origin live-\$(date +%F))." >&2
  exit 1
fi
echo "bootstrap: pinned to tag ${TAG}"
curl -fsSL "https://raw.githubusercontent.com/oscar-barlow/obsidian-gtd-env/${TAG}/scripts/setup-script.sh" \
  -o /tmp/obsidian-gtd-setup-script.sh
bash /tmp/obsidian-gtd-setup-script.sh
