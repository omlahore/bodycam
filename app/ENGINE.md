# How the app talks to the bodycam engine

The menu bar app drives the same `bodycam` binary as the command line. Recording needs root (Apple's
`eslogger`), so the app starts the engine through the standard macOS administrator prompt:

```
do shell script "'<app>/Contents/MacOS/bodycam' --quiet --owner <uid> \
  --events '<home>/Library/Logs/bodycam/events.jsonl' \
  --run-file '<home>/Library/Logs/bodycam/.recording' \
  --parent-pid <app pid> --agent sketchy-agent \
  > /dev/null 2>> '<home>/Library/Logs/bodycam/engine.log' &" with administrator privileges
```

- `--owner uid`: the user whose home holds the reports and events file (root has no SUDO_UID here).
- `--run-file path`: the app creates this file before starting; the engine keeps recording while it
  exists, and finishes every open session and exits within about a second after it is deleted.
  This is how the app stops recording without another password prompt.
- `--parent-pid pid`: the engine also stops when this process exits, so quitting the app stops it.
- `--events path`: the engine appends one JSON object per line. The app tails this file.

## Events (one JSON object per line, appended)

```json
{"type":"status","time":"2026-10-16T02:35:08Z","state":"recording","version":"0.2.0","pid":4242}
{"type":"status","time":"...","state":"error","error":"macOS didn't let bodycam read Endpoint Security events","hint":"full_disk_access"}
{"type":"status","time":"...","state":"stopped"}
{"type":"start","time":"...","session":"1792098908-42826","agent":"claude","pid":42826,"project":"~/code/invoice-api","late":false}
{"type":"event","time":"...","session":"1792098908-42826","who":"node","verb":"read","what":".env","note":"an .env file","flag":true}
{"type":"event","time":"...","session":"1792098908-42826","who":"claude","verb":"edit","what":"src/config.js","note":"","flag":false}
{"type":"end","time":"...","session":"1792098908-42826","agent":"claude","pid":42826,"project":"~/code/invoice-api",
 "seconds":10,"findings":[{"label":"read an .env file","what":".env","who":["node","claude","bat"],"count":6}],
 "commands":56,"changed":1,"changed_outside":0,"deleted":0,"reads":197,"reads_outside":21,"connections":3,
 "dropped":0,"report":"/Users/om/Library/Logs/bodycam/2026-10-16-023507-claude-42826.md"}
```

- `verb` is one of `start`, `run`, `new`, `edit`, `delete`, `read`, `flag`, `net`.
- `flag` is true for anything that is one of the "things to look at". `note` says why
  (`outside the project` marks a change outside the project folder, which is shown but not a flag).
- `hint` values: `full_disk_access` (give the app Full Disk Access), `eslogger_missing` (macOS older than 13).
- A session can end without its `end` line if the engine is killed; treat a `stopped` status as the end
  of every open session.
- `bodycam --replay saved.jsonl --events out.jsonl` writes the same lines from a saved log, which is
  how test and snapshot data is made.
