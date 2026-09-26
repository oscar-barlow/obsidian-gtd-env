# obsidian-gtd-env

Claude Code environment for running GTD weekly reviews against an Obsidian vault. The
repo provides the `.claude/` hooks; the canonical vault lives elsewhere and syncs via
Obsidian Sync at session start (see `CLAUDE.md`).

## `scripts/parse_ics.py`

Parses an ICS file and lists `VEVENT`s within a date window, correctly expanding
`RRULE`/`EXDATE`/`RDATE` and `RECURRENCE-ID` overrides. Used by the weekly review's
calendar check (see `CLAUDE.md`) instead of parsing the raw ICS inline — RRULE
expansion is easy to get subtly wrong and burns a lot of context done by hand.
Depends on `python-dateutil`, installed by `scripts/setup-script.sh`.

```
python3 scripts/parse_ics.py cal.ics [--start YYYY-MM-DD] [--end YYYY-MM-DD]
```

## `scripts/setup-script.sh`

The environment **Setup script** for the Claude Code (web) environment, kept here under
version control. It installs Obsidian + the Dataview/Charts plugins and the `obsidian-up`
helper (session-time vault sync + headless launch); the SessionStart hook runs
`obsidian-up` each session. It also installs `obx`, a lightweight client for the running
app's CLI socket (use it instead of the stock `obsidian <args>` client; see `CLAUDE.md`),
and `as-obs`, which launches the app as `obs` with core dumps enabled so crashes leave
evidence in `/home/obs/crash/`.

The Claude environment config's **Setup script** field itself holds only
`scripts/bootstrap.sh` — a few lines that resolve the latest `live-YYYY-MM-DD` tag and
`curl` `scripts/setup-script.sh` as of that tag, then run it. (This only needs setting up
once — see `scripts/bootstrap.sh` for the exact contents to paste into that field.)

`master` can move freely — WIP, review, whatever — without affecting what new
environments build from. Going live is a deliberate act: once a change is merged and you
actually want it live, cut a dated tag from `master`:

```
make tag-live
```

The first release of the day is `live-YYYY-MM-DD`; later ones the same day get
`live-YYYY-MM-DD.02`, `.03`, … (zero-padded so the bootstrap's plain `sort` still ranks
them correctly — `.10` would otherwise sort before `.2`). It refuses to run off `master`
or when `HEAD` is already the live release; `DRY_RUN=1 make tag-live` shows the tag it
would cut, and `make latest-tag` shows what the bootstrap currently resolves to.

The next environment build picks it up automatically — no paste into the web UI, no edit
to `bootstrap.sh`. If no `live-*` tag exists yet, the bootstrap script fails loudly
rather than silently doing nothing.
