# gobo-core

The sync engine behind Gobo, a Mac menu bar app that
mirrors busy blocks from personal calendars into a work calendar — locally,
through the macOS calendar database, with no servers, no OAuth, and no network
access at all.

This repository is public so that the app's central claim is checkable: an app
asking for full calendar access should let you read its engine, confirm there
is no network call in it, and then decide whether to trust the packaging.

## What it does

One-way mirroring. Events from source calendars (say, iCloud Personal +
Medical) become opaque "Busy" blocks on a target calendar (say, an Exchange
work calendar), so colleagues using free/busy lookups stop booking over your
life. Mirrors carry **no title, location, notes, or attendees** from the
source — only a hashed identity marker.

- The event's own **Busy/Free flag is the opt-in filter**: events marked Free
  are not mirrored. Apple's Calendar app no longer exposes that switch for
  iCloud events on the Mac, so `GoboKit` also provides the one deliberate
  write Gobo ever makes to a source calendar: `setAvailability`, which flips
  the flag on the user's own event (and nothing else — it refuses mirrors and
  carries no content).
- Travel buffers are baked into the single block, optionally only for events
  with a location.
- Mirrors are identified by a `busysync:v1:<hash>` marker line in notes. The
  engine **never touches an unmarked event** on the target calendar, including
  events you titled "Busy" yourself — not even during a full purge.
- Applying the same plan twice produces zero changes; idempotence is enforced
  by a property test.

## Layout

| Target | Contents |
|---|---|
| `GoboCore` | Pure sync logic: models, filters, marker identity, `SyncEngine.plan`/`apply`. **No EventKit import.** |
| `GoboKit` | `CalendarStore` implemented over EventKit, plus permission helpers. |
| `gobo-cli` | Test harness for running the engine against your real calendar database from a terminal. |

`GoboCore` talks to calendars only through the `CalendarStore` protocol, so
the engine is tested exhaustively against an in-memory fake — reconciliation,
recurrence, buffers, orphan cleanup, DST transitions, and loop prevention all
run in CI with no calendar database at hand.

```
swift test
```

## CLI harness

```
swift run gobo-cli calendars          # list calendars + identifiers
swift run gobo-cli plan --rule r.json # dry run: print what a sync would do
swift run gobo-cli sync --rule r.json # apply
swift run gobo-cli purge --calendar <id> [--confirm]
```

A rule file looks like:

```json
{
  "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "name": "Personal into Work",
  "sourceCalendars": [{ "id": "<calendar-id>", "titleHint": "Personal" }],
  "targetCalendar": { "id": "<calendar-id>", "titleHint": "Work" },
  "mirrorTitle": "Busy",
  "windowDaysBack": 1,
  "windowDaysAhead": 90
}
```

The first run prompts for calendar access (granted to your terminal, not to
this tool). `plan` never writes; `sync` writes only marked mirror events to
the target calendar.

## License

[MPL-2.0](LICENSE). File-level copyleft: improvements to this engine stay
open; linking it into a closed app (as Gobo itself does) is permitted.
