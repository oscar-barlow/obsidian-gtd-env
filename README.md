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
`scripts/bootstrap.sh` — a few lines that `curl` this file from the repo's `master`
branch and run it. So the workflow is: edit `scripts/setup-script.sh` → commit → merge to
`master`; the next environment build picks it up automatically, with no separate paste
into the web UI. (This only needs setting up once — see `scripts/bootstrap.sh` for the
exact contents to paste into that field, and note it floats on `master`, so a broken
commit there breaks the next build until fixed.)
