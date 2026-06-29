# GTD Vault — working agreement

## Where the real data lives
- **Canonical vault: `/home/obs/vault`** (synced via Obsidian Sync at session start).
- This repo exists only to provide the `.claude/` hooks. Any `GTD/`, `Templates/`,
  or note files *in the repo* are template/scaffold — **never read them as live data
  or edit them during a review.** All GTD work happens in `/home/obs/vault`.
- If the vault hasn't synced (files missing under `/home/obs/vault/GTD`), say so and
  stop — don't fall back to repo template data.

## Key files (all under `/home/obs/vault`)
- `GTD/Inbox.md` — unprocessed capture.
- `GTD/Tasks.md` — all next actions (one Markdown task per line).
- `GTD/Tickler.md` — date-deferred items.
- `GTD/Projects/` and `GTD/Goals/` — one note each; frontmatter has `activationDate`
  / `completionDate`; `Archive/` subfolders for done. **These files are the source of
  truth.**
- `Templates/Weekly Review.md` — the weekly review template.
- `GTD/Meta/Weekly Reviews/` — completed reviews, named `Weekly Review <D.M.YY>.md`.
- `GTD/Meta/Analytics.md` -- charts about recent activity. Must be parsed through 
   dataview.
- `GTD/Meta/Urgent-Important.md` -- classic Eisenhower matrix.

> **`List.md` and `GTD/Meta/Review.md` are Dataview dashboards.** They render only in
> the Obsidian GUI (and this vault has `enableDataviewJs: false`, so the `dataviewjs`
> blocks don't even render there) — from the filesystem you just see query code. To get
> *results*, query the Dataview API through the Obsidian CLI (see below). `Review.md`
> still encodes the useful definition of a *neglected* project (active with no open next
> action, or no completed task in ~2 weeks) — **apply that logic** via the API.

## Driving Obsidian via its CLI
A headless Obsidian GUI runs at session start with a CLI socket. Invoke it as the
`obs` user against display `:99`:
```
obs() { sudo -u obs -- env DISPLAY=:99 obsidian "$@"; }   # ignore the harmless dbus warning
```
This is the **preferred** way to read live state and make changes (the running app
owns the vault, so edits reconcile cleanly). Useful commands:
- `obs read path=<p>` · `obs search query=<text>` · `obs files` · `obs tasks` (filter!).
- `obs create path=<p> content=<text>` · `obs append file=<n> content=<text>`.
- `obs property:read file=<n> key=<k>` · `obs property:set file=<n> key=<k> value=<v>`.
- `obs task ref=<path:line>` — show/update a single task (e.g. mark done).
- `obs template:read file="Weekly Review"` — read a template.
- **`obs eval code='<js>'`** — run JS in the renderer; this is how you reach Dataview:
  ```
  obs eval code='const dv=app.plugins.plugins.dataview.api;
    JSON.stringify(dv.pages(`"GTD/Projects"`)
      .where(p=>p.activationDate&&!p.completionDate&&p.activationDate<=dv.date("now"))
      .map(p=>p.file.name).array())'
  ```
  Task fields are first-class: `t.project`, `t.context`, `t.timescale`, `t.completed`.
  Quote `code=` in single quotes and use backticks for the inner Dataview source string.

## Syncing
Changes live in the container and are lost unless pushed to Obsidian Sync.
**Always `ob sync --path /home/obs/vault` at the end of a review/session** so the new
review note and task edits upload. (The startup hook handles the initial pull.)

## Calendar (Proton)
The review's calendar check reads a **Proton "share with anyone"** ICS link — read-only,
revocable, *no Proton account credentials* — from the `SECRET_PROTON_CAL_ICS` env secret.
Fetch and parse it inline (no script, no deps): `curl -fsS "$SECRET_PROTON_CAL_ICS"`, then
read the `VEVENT`s directly — filter to ±2 weeks of today and expand any recurring
(`RRULE`) events into that window. Requires the egress policy to allow `calendar.proton.me`.
If the fetch fails (secret missing / host not allowlisted), fall back to asking me to
check my calendar manually.

## Linear & Notion
Linear and Notion are available over MCP. Data about what work has recently been done
also live in there. Consequently, when forming a view about neglected projects,
or whether there are any goals that haven't had work done against them, check
These 2 data sources. Names won't match up so you'll have to figure it out. 
Linear is more useful than Notion in this respect - you can see tasks completed in it,
whereas you have to infer work done and associated project/goal by looking at activity
logs in Notion. Linear tracks work, Notion has evidence of work done. 

## Task format (match exactly when adding/completing)
```
- [ ] <action> [project:: [[Project Name]]] - [context:: <context>] - [timescale:: <next | waiting | YYYY-MM-DD>]
```
- Completed tasks: change `[ ]` → `[x]` and append `[completion:: YYYY-MM-DD]`.
- Common timescales: `next` (do soon), `waiting` (delegated/blocked), or a date.

---

# Running the weekly GTD review

Trigger: "let's do the weekly review" (or similar). Two gears — **process first,
then review** — kept deliberately separate. Run it **conversationally**: one thing
at a time, listen, follow up, write my answers into the note in my voice. Never
invent answers; if I skip something, leave it blank.

1. **Open/create the note.** From `Templates/Weekly Review.md`, create
   `GTD/Meta/Weekly Reviews/Weekly Review <D.M.YY>.md` and set `date:` (YYYY-MM-DD).
   If one already exists for today, open it rather than overwriting.

2. **Work the template top-to-bottom, strictly in order.** Don't reorder, skip, or
   inject sections — the template evolves deliberately, together (see below).
   Capture each answer under its heading. While on the relevant headings:
   - **Mental health (1–10)** comes first — also set the `mentalHealth` frontmatter.
     Compare to last review's score for trend.
   - **Projects** → render the active project list via `eval`.
   - **Neglected projects** → apply `Review.md`'s neglect logic via `eval`. Every
     active project must have ≥1 open next action; for anything stalled, agree a
     concrete next action (or defer/drop). Surface `timescale: waiting` tasks here
     and nudge me on stale ones.
   - **Calendar ±2 weeks** → `curl -fsS "$SECRET_PROTON_CAL_ICS"` and parse the iCal
     inline (filter to the window, expand recurring events); review it with me (fall
     back to asking me to check manually if it errors).

3. **Update the system from what we discussed** (Obsidian CLI preferred): add new
   tasks in the house format; mark finished ones done with today's `[completion::]`;
   complete/activate/archive projects as agreed (set `completionDate`, move to
   `Archive/`).

4. **Close out per the template.** Offer a one-line **Work Log** entry; flag
   anything worth promoting to the **Brag Doc**. **Then `ob sync`** to push
   everything back to Obsidian and confirm what changed. (A `Stop` hook runs
   `ob sync` as a safety net, but don't rely on it.)

## Evolving the review template
Change `Templates/Weekly Review.md` only by agreement, never mid-review. Pending
ideas we've agreed to add when we next touch it:
- A **Someday/Maybe** prompt (scan dormant/inactive projects — anything to revive?).
- A **Goals review** section that appears **every 4th review** (do active projects
  still serve my goals? any goal with no active project?).
