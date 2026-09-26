REPO_URL := https://github.com/oscar-barlow/obsidian-gtd-env.git
TAG := live-$(shell date +%F)

.PHONY: tag-live latest-tag

# Tag the current commit as live and push it -- this is what a fresh
# environment build actually picks up (see scripts/bootstrap.sh). Refuses to
# run off master: tagging the wrong commit as live is exactly the mistake
# this exists to prevent.
tag-live:
	@if [ "$$(git rev-parse --abbrev-ref HEAD)" != "master" ]; then \
		echo "refusing: not on master (on $$(git rev-parse --abbrev-ref HEAD))" >&2; \
		exit 1; \
	fi
	git tag $(TAG)
	git push origin $(TAG)

# Show which live-YYYY-MM-DD tag scripts/bootstrap.sh would currently
# resolve to, without cutting a new one.
latest-tag:
	@git ls-remote --tags --refs $(REPO_URL) 'live-*' | sed 's#.*refs/tags/##' | sort | tail -1
