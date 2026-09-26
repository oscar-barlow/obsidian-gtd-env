#!/usr/bin/env bash
#
# Cut the next live tag for HEAD and push it (run via `make tag-live`).
#
# Tag scheme, several releases a day allowed:
#   live-YYYY-MM-DD      first release of the day
#   live-YYYY-MM-DD.02   second
#   live-YYYY-MM-DD.03   third ... up to .99
# The suffix is zero-padded on purpose: scripts/bootstrap.sh (pasted into the
# environment's Setup script field, so changing it means re-pasting) picks the
# newest tag with a plain lexicographic `sort | tail -1`. Unpadded, `.10` would
# sort before `.2` and a busy day would silently deploy the wrong release;
# padded, bare < .02 < ... < .99 < the next day's tags, so the existing
# bootstrap keeps working unchanged.
#
# DRY_RUN=1 prints the tag it would cut without creating or pushing it.
set -euo pipefail

REMOTE="${REMOTE:-origin}"
TODAY="$(date +%F)"

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "master" ]; then
  echo "refusing: not on master (on ${branch})" >&2
  exit 1
fi

# The remote is the source of truth: a tag cut from another checkout must
# count, and a stale local tag list must not.
remote_tags="$(git ls-remote --tags --refs "${REMOTE}" 'live-*')"

# Releasing the commit that's already live is a no-op that just burns a number.
latest="$(printf '%s\n' "${remote_tags}" | sed -n 's#.*refs/tags/##p' | sort | tail -1)"
if [ -n "${latest}" ] && \
   [ "$(printf '%s\n' "${remote_tags}" | awk -v t="refs/tags/${latest}" '$2 == t {print $1}')" = "$(git rev-parse HEAD)" ]; then
  echo "refusing: HEAD is already live as ${latest}" >&2
  exit 1
fi

today_tags="$(printf '%s\n' "${remote_tags}" | sed -n "s#.*refs/tags/\(live-${TODAY}\(\.[0-9][0-9]\)\{0,1\}\)\$#\1#p")"
if [ -z "${today_tags}" ]; then
  tag="live-${TODAY}"
else
  # The bare tag counts as release 1; otherwise take the highest suffix.
  n="$(printf '%s\n' "${today_tags}" | sed -n 's#.*\.\([0-9][0-9]\)$#\1#p' | sort | tail -1)"
  n=$((10#${n:-01} + 1))
  if [ "${n}" -gt 99 ]; then
    echo "refusing: already 99 releases today" >&2
    exit 1
  fi
  tag="$(printf 'live-%s.%02d' "${TODAY}" "${n}")"
fi

if [ -n "${DRY_RUN:-}" ]; then
  echo "would tag $(git rev-parse --short HEAD) as ${tag}"
  exit 0
fi
git tag "${tag}"
git push "${REMOTE}" "${tag}"
echo "tagged $(git rev-parse --short HEAD) as ${tag}"
