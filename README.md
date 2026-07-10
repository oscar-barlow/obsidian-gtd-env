# obsidian-gtd-env

Claude Code environment for running GTD weekly reviews against an Obsidian vault. The
repo provides the `.claude/` hooks; the canonical vault lives elsewhere and syncs via
Obsidian Sync at session start (see `CLAUDE.md`).

## `scripts/setup-script.sh`

The environment **Setup script** for the Claude Code (web) environment, kept here under
version control. It installs Obsidian + the Dataview/Charts plugins and the `obsidian-up`
helper (session-time vault sync + headless launch); the SessionStart hook runs
`obsidian-up` each session.

This file is **not** run from the repo — it takes effect only when its contents are
pasted into the **Setup script** field of the Claude environment config. It has already
been pasted there. So the workflow is: edit `scripts/setup-script.sh` → commit → paste
the updated contents back into the web environment.
