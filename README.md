# obsidian-gtd-env

Claude Code environment for running GTD weekly reviews against an Obsidian vault. The
repo provides the `.claude/` hooks; the canonical vault lives elsewhere and syncs via
Obsidian Sync at session start (see `CLAUDE.md`).

## `scripts/setup-script.sh`

The environment **Setup script** for the Claude Code (web) environment, kept here under
version control. It installs Obsidian + the Dataview/Charts plugins and the `obsidian-up`
helper (session-time vault sync + headless launch); the SessionStart hook runs
`obsidian-up` each session.

The Claude environment config's **Setup script** field itself holds only
`scripts/bootstrap.sh` — a few lines that resolve the latest `live-YYYY-MM-DD` tag and
`curl` `scripts/setup-script.sh` as of that tag, then run it. (This only needs setting up
once — see `scripts/bootstrap.sh` for the exact contents to paste into that field.)

`master` can move freely — WIP, review, whatever — without affecting what new
environments build from. Going live is a deliberate act: once a change is merged and you
actually want it live, cut a dated tag:

```
git tag "live-$(date +%F)" && git push origin "live-$(date +%F)"
```

The next environment build picks it up automatically — no paste into the web UI, no edit
to `bootstrap.sh`. If no `live-*` tag exists yet, the bootstrap script fails loudly with
that same command rather than silently doing nothing.
