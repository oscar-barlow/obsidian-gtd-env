REPO_URL := https://github.com/oscar-barlow/obsidian-gtd-env.git

.PHONY: tag-live latest-tag

# Tag the current commit as the next live release and push it -- this is what
# a fresh environment build actually picks up (see scripts/bootstrap.sh).
# First release of the day is live-YYYY-MM-DD, then .02, .03, ... (see
# scripts/tag-live.sh for why the suffix is zero-padded). Refuses to run off
# master, or when HEAD is already the live release: tagging the wrong commit
# as live is exactly the mistake this exists to prevent.
tag-live:
	@scripts/tag-live.sh

# Show which live tag scripts/bootstrap.sh would currently resolve to,
# without cutting a new one.
latest-tag:
	@git ls-remote --tags --refs $(REPO_URL) 'live-*' | sed 's#.*refs/tags/##' | sort | tail -1
