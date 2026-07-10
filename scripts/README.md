# scripts/

## `setup-script.sh`

The environment **Setup script** for the Claude Code (web) environment, kept here under
version control. It installs Obsidian + the Dataview/Charts plugins and the `obsidian-up`
helper (session-time vault sync + headless launch); the SessionStart hook runs
`obsidian-up` each session.

This file is **not** run from the repo — it takes effect only when its contents are
pasted into the **Setup script** field of the Claude environment config. It has already
been pasted there. So the workflow is: edit here → commit → paste the updated contents
back into the web environment.
