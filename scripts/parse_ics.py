#!/usr/bin/env python3
"""Parse an ICS file and list VEVENTs within a date window, expanding RRULEs.

Written for the weekly-review calendar check (see CLAUDE.md: "Calendar (Proton)"):
fetch the Proton "share with anyone" ICS link with curl, then run this over it to
get a flat, chronological list of occurrences in the +/-2 week review window,
with RRULE/EXDATE/RDATE and RECURRENCE-ID overrides all correctly expanded
(an override replaces the corresponding master occurrence rather than
duplicating it).

Usage:
    python3 parse_ics.py CAL.ics [--start YYYY-MM-DD] [--end YYYY-MM-DD]

Defaults to today -14 / +14 days if --start/--end are omitted.

Depends on python-dateutil for RRULE expansion and timezone handling (installed
by scripts/setup-script.sh); falls back to single-occurrence-only handling if
it isn't available.
"""
import argparse
import re
import sys
from datetime import datetime, date, timedelta

try:
    from dateutil.rrule import rrulestr
    from dateutil import tz
    HAVE_DATEUTIL = True
except ImportError:
    HAVE_DATEUTIL = False

LOCAL_TZ = tz.tzlocal() if HAVE_DATEUTIL else None


def unfold_lines(raw):
    """Unfold ICS lines: a line starting with space/tab continues the previous line."""
    lines = raw.split("\r\n") if "\r\n" in raw else raw.split("\n")
    unfolded = []
    for line in lines:
        if line.startswith(" ") or line.startswith("\t"):
            if unfolded:
                unfolded[-1] += line[1:]
            else:
                unfolded.append(line[1:])
        else:
            unfolded.append(line)
    return unfolded


def parse_prop_line(line):
    """Split a content line into (name, params_dict, value)."""
    if ":" not in line:
        return None, {}, None
    head, value = line.split(":", 1)
    parts = head.split(";")
    name = parts[0].upper()
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v
    return name, params, value


def unescape_text(s):
    return (s.replace("\\n", "\n").replace("\\N", "\n")
             .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def parse_datetime(value, params):
    """Parse a DATE or DATE-TIME value, return (dt_or_date, is_date_only, tzid)."""
    value = value.strip()
    tzid = params.get("TZID")
    if params.get("VALUE") == "DATE" or (len(value) == 8 and "T" not in value):
        d = datetime.strptime(value, "%Y%m%d").date()
        return d, True, None
    # DATE-TIME
    is_utc = value.endswith("Z")
    v = value.rstrip("Z")
    dt = datetime.strptime(v, "%Y%m%dT%H%M%S")
    if is_utc:
        if HAVE_DATEUTIL:
            dt = dt.replace(tzinfo=tz.tzutc())
        return dt, False, "UTC"
    elif tzid:
        if HAVE_DATEUTIL:
            zone = tz.gettz(tzid)
            if zone:
                dt = dt.replace(tzinfo=zone)
        return dt, False, tzid
    else:
        return dt, False, None


def parse_ics(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    lines = unfold_lines(raw)

    events = []
    current = None
    for line in lines:
        if not line:
            continue
        if line.strip() == "BEGIN:VEVENT":
            current = {"rdate": [], "exdate": []}
            continue
        if line.strip() == "END:VEVENT":
            if current is not None:
                events.append(current)
            current = None
            continue
        if current is None:
            continue
        name, params, value = parse_prop_line(line)
        if name is None:
            continue
        if name == "DTSTART":
            current["dtstart"] = parse_datetime(value, params)
        elif name == "DTEND":
            current["dtend"] = parse_datetime(value, params)
        elif name == "DURATION":
            current["duration"] = value
        elif name == "RRULE":
            current["rrule"] = value
        elif name == "RDATE":
            for v in value.split(","):
                current["rdate"].append(parse_datetime(v, params))
        elif name == "EXDATE":
            for v in value.split(","):
                current["exdate"].append(parse_datetime(v, params))
        elif name == "SUMMARY":
            current["summary"] = unescape_text(value)
        elif name == "LOCATION":
            current["location"] = unescape_text(value)
        elif name == "UID":
            current["uid"] = value
        elif name == "RECURRENCE-ID":
            current["recurrence_id"] = parse_datetime(value, params)
        elif name == "STATUS":
            current["status"] = value
    return events


def parse_iso_duration(s):
    """Very small ISO-8601 duration parser (PnDTnHnMnS)."""
    m = re.match(
        r"^([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", s
    )
    if not m:
        return timedelta()
    sign = -1 if m.group(1) == "-" else 1
    weeks, days, hours, minutes, seconds = (int(x) if x else 0 for x in m.groups()[1:])
    return sign * timedelta(weeks=weeks, days=days, hours=hours, minutes=minutes, seconds=seconds)


def to_naive_for_compare(d):
    """Convert date/datetime to a naive datetime for comparison purposes."""
    if isinstance(d, datetime):
        if d.tzinfo is not None:
            if HAVE_DATEUTIL:
                d = d.astimezone(LOCAL_TZ)
            return d.replace(tzinfo=None)
        return d
    elif isinstance(d, date):
        return datetime(d.year, d.month, d.day)
    return d


def expand_event(ev, window_start_dt, window_end_dt):
    """Return list of (start_dt_or_date, end_dt_or_date, is_date_only) occurrences in window."""
    occurrences = []
    dtstart_val, is_date_only, tzid = ev.get("dtstart", (None, False, None))
    if dtstart_val is None:
        return occurrences

    # compute duration
    duration = None
    if "dtend" in ev:
        dtend_val, _, _ = ev["dtend"]
        if isinstance(dtstart_val, datetime) and isinstance(dtend_val, datetime):
            duration = dtend_val - dtstart_val
        elif isinstance(dtstart_val, date) and isinstance(dtend_val, date):
            duration = dtend_val - dtstart_val
    elif "duration" in ev:
        duration = parse_iso_duration(ev["duration"])
    else:
        duration = timedelta(days=1) if is_date_only else timedelta(0)

    exdates = set()
    for exv, _, _ in ev.get("exdate", []):
        exdates.add(to_naive_for_compare(exv))

    rrule_str = ev.get("rrule")
    if rrule_str and HAVE_DATEUTIL:
        try:
            # rrulestr needs a datetime dtstart
            if is_date_only:
                dtstart_for_rule = datetime(dtstart_val.year, dtstart_val.month, dtstart_val.day)
            else:
                dtstart_for_rule = dtstart_val
            rule = rrulestr(f"RRULE:{rrule_str}", dtstart=dtstart_for_rule)
            # window bounds as naive datetimes matching dtstart_for_rule tz-awareness
            if dtstart_for_rule.tzinfo is not None:
                w_start = window_start_dt.replace(tzinfo=dtstart_for_rule.tzinfo)
                w_end = window_end_dt.replace(tzinfo=dtstart_for_rule.tzinfo)
            else:
                w_start = window_start_dt
                w_end = window_end_dt
            for occ in rule.between(w_start - timedelta(days=2), w_end + timedelta(days=2), inc=True):
                occ_naive = to_naive_for_compare(occ)
                if occ_naive in exdates:
                    continue
                if is_date_only:
                    start = occ.date()
                    end = start + duration if duration else start
                else:
                    start = occ
                    end = occ + duration if duration else occ
                occurrences.append((start, end, is_date_only))
        except Exception as e:
            sys.stderr.write(f"RRULE expansion failed for UID {ev.get('uid')}: {e}\n")
            # fall back to single occurrence
            end = dtstart_val + duration if duration else dtstart_val
            occurrences.append((dtstart_val, end, is_date_only))
    else:
        # single occurrence event (possibly with RDATEs)
        occ_naive = to_naive_for_compare(dtstart_val)
        if occ_naive not in exdates:
            end = dtstart_val + duration if duration else dtstart_val
            occurrences.append((dtstart_val, end, is_date_only))
        for rv, r_is_date, _ in ev.get("rdate", []):
            rv_naive = to_naive_for_compare(rv)
            if rv_naive in exdates:
                continue
            end = rv + duration if duration else rv
            occurrences.append((rv, end, r_is_date))

    # filter to window
    filtered = []
    for start, end, dateonly in occurrences:
        start_naive = to_naive_for_compare(start)
        if window_start_dt <= start_naive <= window_end_dt:
            filtered.append((start, end, dateonly))
    return filtered


def fmt_time(dt):
    if HAVE_DATEUTIL and dt.tzinfo is not None:
        dt = dt.astimezone(LOCAL_TZ)
    return dt.strftime("%H:%M")


def is_junk(summary):
    if not summary:
        return True
    return summary.lower() in ("test", "test event", "placeholder", "junk", "xxx", "n/a")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("ics_path", help="Path to the .ics file to parse")
    p.add_argument("--start", type=str, default=None, help="Window start, YYYY-MM-DD (default: today - 14 days)")
    p.add_argument("--end", type=str, default=None, help="Window end, YYYY-MM-DD, inclusive (default: today + 14 days)")
    return p.parse_args()


def main():
    args = parse_args()
    today = date.today()
    window_start = datetime.strptime(args.start, "%Y-%m-%d").date() if args.start else today - timedelta(days=14)
    window_end = datetime.strptime(args.end, "%Y-%m-%d").date() if args.end else today + timedelta(days=14)

    events = parse_ics(args.ics_path)
    window_start_dt = datetime(window_start.year, window_start.month, window_start.day)
    window_end_dt = datetime(window_end.year, window_end.month, window_end.day, 23, 59, 59)

    # Group by UID to correctly handle RECURRENCE-ID overrides: an override
    # replaces the corresponding single occurrence generated by the master's
    # RRULE, rather than adding a duplicate.
    by_uid = {}
    for ev in events:
        by_uid.setdefault(ev.get("uid", id(ev)), []).append(ev)

    results = []
    skipped_junk = 0
    skipped_cancelled = 0

    for uid, group in by_uid.items():
        masters = [e for e in group if "recurrence_id" not in e]
        overrides = [e for e in group if "recurrence_id" in e]

        override_dates = set()
        for ov in overrides:
            rid_val, _, _ = ov["recurrence_id"]
            override_dates.add(to_naive_for_compare(rid_val))

        # Expand master(s), excluding any occurrence overridden below.
        for master in masters:
            summary = master.get("summary", "").strip()
            status = master.get("status", "").upper()
            occs = expand_event(master, window_start_dt, window_end_dt)
            for start, end, dateonly in occs:
                if to_naive_for_compare(start) in override_dates:
                    continue  # replaced by an override VEVENT below
                if status == "CANCELLED":
                    skipped_cancelled += 1
                    continue
                if is_junk(summary):
                    skipped_junk += 1
                    continue
                results.append({
                    "start": start, "end": end, "dateonly": dateonly,
                    "summary": summary, "location": master.get("location", "").strip(),
                })

        # Include each override occurrence at its own (possibly moved) time.
        for ov in overrides:
            summary = ov.get("summary", "").strip()
            status = ov.get("status", "").upper()
            if status == "CANCELLED":
                skipped_cancelled += 1
                continue
            if is_junk(summary):
                skipped_junk += 1
                continue
            occs = expand_event(ov, window_start_dt, window_end_dt)
            # override events carry their own DTSTART (no RRULE of their own
            # normally), so this just filters to the window.
            for start, end, dateonly in occs:
                results.append({
                    "start": start, "end": end, "dateonly": dateonly,
                    "summary": summary, "location": ov.get("location", "").strip(),
                })

    def sort_key(r):
        return to_naive_for_compare(r["start"])

    results.sort(key=sort_key)

    print(f"Total VEVENTs parsed: {len(events)} ({len(by_uid)} unique UIDs)")
    print(f"Skipped as junk/no-title: {skipped_junk}, skipped as cancelled: {skipped_cancelled}")
    print(f"Occurrences in window {window_start} to {window_end}: {len(results)}")
    print("---")
    for r in results:
        start = r["start"]
        end = r["end"]
        if r["dateonly"]:
            date_str = start.strftime("%Y-%m-%d (%a)")
            time_str = "all-day"
            if end and end != start:
                time_str = f"all-day thru {end.strftime('%Y-%m-%d')}"
        else:
            date_str = start.strftime("%Y-%m-%d (%a)")
            start_t = fmt_time(start)
            end_t = fmt_time(end) if end and isinstance(end, datetime) and end != start else None
            time_str = f"{start_t}-{end_t}" if end_t else start_t
        loc_raw = r["location"]
        if loc_raw:
            # Compress long video-call URLs to a short marker for terseness;
            # keep physical addresses/venue names as-is.
            parts = [p.strip() for p in re.split(r"[;\n]", loc_raw) if p.strip()]
            compressed = []
            for p in parts:
                if re.search(r"(meet\.google\.com|calendly\.com|zoom\.us|teams\.microsoft)", p, re.I):
                    compressed.append("(video call)")
                else:
                    compressed.append(p)
            # dedupe consecutive identical markers
            seen = []
            for c in compressed:
                if not seen or seen[-1] != c:
                    seen.append(c)
            loc = " @ " + "; ".join(seen)
        else:
            loc = ""
        print(f"{date_str} {time_str} - {r['summary']}{loc}")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.stderr.close()
