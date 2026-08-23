# check_log_latch

[![CI](https://github.com/ryochin/check_log_latch/actions/workflows/ci.yml/badge.svg)](https://github.com/ryochin/check_log_latch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

English | [Japanese](README.ja.md)

A Nagios plugin that scans newly appended log lines for a regex and **keeps returning
CRITICAL until a human clears it** with `--reset`.

```text
CRITICAL - log pattern latched since 2026-07-08T10:00:00+09:00; count=1; latest='FATAL database connection failed'; clear with --reset | scanned_bytes=123B matches=1 latched=1
```

## Why not `check_log`?

The standard `check_log` detects the *difference* between runs. That makes it an event
detector, not a state monitor:

```text
1. A check finds the target string
2. It returns CRITICAL
3. oldlog / state is updated
4. On the next check that line is already known
5. It goes back to OK
```

With a 5-minute check interval, the CRITICAL lasts exactly one check. If the requirement is

```text
Go CRITICAL when a string appears in the log
Stay CRITICAL until a human acknowledges it
Do not re-detect old lines after clearing
```

then a *latching* plugin is a better fit than `check_log`.

## Features

- Watches a single file and matches new lines against one or more regexes
- Persists a **latch** once a match is found
- Stays `CRITICAL` while latched, even with no new matches
- Stays `CRITICAL` while latched, even if the log file disappears or stops being readable
- Cleared manually with `--reset`, which also seeks to the current EOF
- Clearing needs neither the regex, nor a readable log file, nor an intact state file, nor
  even a usable lock file, so a latch can never become unclearable
- Nothing short of `--reset` clears it: not a full disk, not a damaged state file, not a
  `chmod`, not a runaway pattern
- Absorbs log rotation and truncation
- Strips terminal escape sequences, so a coloured log reads — and matches — as plain text
- Never lets a log line forge plugin output or performance data
- Returns standard Nagios exit codes, including for unexpected failures and for a bad
  command line
- Never blocks: neither on the log file, nor on a concurrent run of the same check

```text
0 = OK
1 = WARNING
2 = CRITICAL
3 = UNKNOWN
```

## Requirements

- Python 3.8 or later
- A POSIX platform (the plugin uses `fcntl` and `O_NOFOLLOW`)
- No third-party dependencies

## Installation

```sh
install -o root -g wheel -m 0755 check_log_latch.py /usr/local/libexec/nagios/check_log_latch

install -d -o nagios -g nagios -m 0750 \
  /var/spool/nagios/check_log_latch
```

On Linux there may be no `wheel` group; substitute `root` or whatever suits the host.

## Quick start

```sh
sudo -u nagios /usr/local/libexec/nagios/check_log_latch \
  -F /var/log/myapp/app.log \
  -p 'FATAL|panic|connection refused' \
  -t myapp \
  -s /var/spool/nagios/check_log_latch
```

The first run normally ignores existing history and starts watching from EOF:

```text
OK - initialized at EOF (offset=0) | scanned_bytes=0B matches=0 latched=0
```

Once a matching line is appended, the check goes CRITICAL and stays there until reset.

Clearing the latch:

```sh
sudo -u nagios /usr/local/libexec/nagios/check_log_latch \
  -F /var/log/myapp/app.log \
  -t myapp \
  -s /var/spool/nagios/check_log_latch \
  --reset
```

```text
OK - latch cleared for /var/log/myapp/app.log | scanned_bytes=0B matches=0 latched=0
```

`-p` is not needed for a reset — only `-F` plus the options that identify the state file
(`-t` / `-s`, or `--state-file`) matter.

## Behavior

### First run

Existing content is skipped and the offset is set to the current EOF.

```text
OK - initialized at EOF (offset=316) | scanned_bytes=0B matches=0 latched=0
```

This wording appears only on the initializing run. From the second run onwards, a quiet
check prints `OK - no matching log lines`, so "just initialized" is distinguishable from
"running normally with nothing to report".

Pass `--from-start` to scan pre-existing content on the first run. That is treated as a
normal scan rather than an initialization, so the message above is not printed.

### A new line matches

```text
CRITICAL - log pattern latched since ...; count=1; latest='FATAL ...'; clear with --reset
```

The latch is written to the state file at the same time.

### Subsequent runs

While the latch exists, the check stays CRITICAL even with no new matches.

```text
CRITICAL - log pattern latched since ...
```

### The log file disappears while latched

The latch outlives the file it watches, so a rotation window or a redeploy that removes
the file does not clear it.

```text
CRITICAL - log pattern latched since ...; clear with --reset (log file currently missing: /var/log/myapp/app.log)
```

`--missing` only applies when no latch is held. Otherwise `--missing ok` would fire a
spurious recovery notification the moment the file vanished, defeating the point of
latching.

### Manual reset

`--reset` drops the latch and advances the read offset to the current EOF, so the lines
that caused the alert are not immediately re-detected. The stored `fingerprint` is
refreshed from the current file as well.

If the log file cannot be opened at reset time there is no EOF to seek to, so the stored
position is dropped instead. Whatever file appears at that path next is treated as a first
run and initialized at its EOF, rather than scanned from the start — otherwise a redeploy
that recreated the log with content in it would re-latch immediately.

That applies to *every* log file a reset cannot open — missing, unreadable, replaced by a
directory — because a reset that fails would leave a latch nothing could ever clear. The
reset succeeds and says what it gave up:

```text
OK - latch cleared for /var/log/myapp/app.log (log file could not be read, position dropped: [Errno 13] Permission denied: '/var/log/myapp/app.log')
```

A state file that no longer parses is discarded by `--reset` for the same reason.

### The log file cannot be read

A log file that exists but cannot be read — no permission, replaced by a directory, gone
between the existence check and the read — is reported as UNKNOWN rather than crashing:

```text
UNKNOWN - cannot read log file /var/log/myapp/app.log: [Errno 13] Permission denied: '/var/log/myapp/app.log'
```

Only regular files are read. A fifo or a device node at the watched path is rejected the
same way instead of blocking the check until the monitoring system kills it:

```text
UNKNOWN - cannot read log file /var/log/myapp/app.log: [Errno 22] not a regular file: '/var/log/myapp/app.log'
```

A held latch comes first here, exactly as it does when the file is missing. Otherwise a
`chmod`, or a redeploy that left a directory at the path, would downgrade a CRITICAL nobody
has cleared:

```text
CRITICAL - log pattern latched since ...; clear with --reset (log file cannot be read: [Errno 13] Permission denied: '/var/log/myapp/app.log')
```

Anything else that goes wrong unexpectedly is reported as UNKNOWN too. A plugin that died
with a traceback would exit `1`, and Nagios would read that as WARNING — the wrong severity
for a run that in truth measured nothing.

An unusable command line is UNKNOWN for the same reason. `argparse` exits `2` on a usage
error by itself, and Nagios reads `2` as CRITICAL, so a typo in a command definition or an
`$ARGn$` that never got filled in would alert on a log file that was never opened:

```text
UNKNOWN - the following arguments are required: -F/--file
```

## Options

| Option | Description |
|---|---|
| `-F`, `--file` | Log file to watch. Required. |
| `-p`, `--pattern` | Regex that triggers CRITICAL. Repeatable; any match is enough. Required unless `--reset`. |
| `-t`, `--tag` | Stable identifier used for the state file name. Recommended. |
| `-s`, `--state-dir` | Directory holding state files. Default `/var/spool/nagios/check_log_latch`. |
| `--state-file` | Explicit state file path. Overrides `--state-dir` and `--tag`. |
| `-i`, `--ignore-case` | Case-insensitive matching. |
| `--missing` | State when the log file is absent: `ok` / `warning` / `critical` / `unknown`. Default `unknown`. Ignored while latched. |
| `--max-bytes` | Maximum bytes scanned per run. Unset or `0` means no cap. |
| `--max-output` | Maximum characters of a matched line shown. Default `120`, minimum `1`. |
| `--lock-timeout` | Seconds to wait for a concurrent run of the same check. Default `10`. |
| `--scan-timeout` | Seconds the scan may take before giving up. Default `30`, `0` means no limit. |
| `--from-start` | On the first run, scan the existing file from the beginning. |
| `--reset` | Clear the latch and seek to the current EOF. |
| `-V`, `--version` | Print the version and exit. |

The Nagios plugin guidelines reserve `-t` for a timeout. This plugin has two waits, and both
are bounded under their own long names — `--lock-timeout` and `--scan-timeout` — neither of
which gets typed often. So `-t` is given to the option that is typed on every command line
instead.

### `-p`, `--pattern`

```sh
-p 'FATAL|panic|connection refused'
```

or, equivalently:

```sh
-p 'FATAL' -p 'panic' -p 'connection refused'
```

### `-t`, `--tag`

When one log file is watched under several conditions, give each condition its own tag:

```text
myapp-fatal
myapp-timeout
myapp-auth
```

A tag becomes a file name, so anything outside `A-Za-z0-9_.-` is folded to `_`. Two tags that
differ only in the folded characters would otherwise share one state file — and one latch —
so a tag that had to be folded also carries a short digest of what it was:

```text
myapp-fatal   ->  myapp-fatal.json
app/one       ->  app_one_196083a4.json
app one       ->  app_one_15f75da5.json
```

### `-s`, `--state-dir`

Must be writable by the Nagios user. **Never point it at a world-writable directory such
as `/tmp` or `/var/tmp`.** The plugin refuses to run (`UNKNOWN`) when the state directory:

```text
is a symlink
is owned by neither root nor the effective user
is group-writable
is world-writable
```

`--state-file` is held to the same standard: the directory the file sits in is checked
exactly as `--state-dir` would be, so `--state-file /tmp/myapp.json` is refused too.

### `--max-bytes`

Caps how much is scanned in a single run, so a sudden burst of log volume cannot stall the
check.

```sh
--max-bytes 5242880
```

There is no cap by default, and `0` says the same thing explicitly. Nothing is skipped
unless you ask for it: the appended part is matched in 1 MiB pieces, so the memory a run
needs follows the longest line in the log rather than how much the log grew since the last
check, and an uncapped run of any size stays affordable.

When the cap is hit, the start offset jumps to `current size - max-bytes`; **older
unscanned bytes are discarded without being examined.** That is a deliberate trade of
coverage for load protection, so leave generous headroom. Runs that hit the cap say so:

```text
OK - no matching log lines; scanned_bytes=5242880 (scan limited by --max-bytes)
```

The cap lands wherever the arithmetic puts it, so the scan resumes at the first line
boundary at or after it. Half a line is not a log line, and feeding one to an anchored
pattern like `^ERROR` would match text that never was at the start of a line.

That question is asked on every run, not only on the one the cap moved. When the bytes a
cap left behind hold no newline at all — a single line longer than `--max-bytes` — the run
completes no line and the stored offset stays in the middle of one. The next run has no cap
of its own to warn it, so the check is made from the byte in front of the offset instead.

### `--lock-timeout`

Runs of the same check are serialized on a lock file, so two of them cannot both read from
the same offset and count one line twice. A run that finds the lock held waits for it, and
gives up after `--lock-timeout` seconds:

```text
UNKNOWN - another run still holds the lock on /var/spool/nagios/check_log_latch/myapp.json after 10s
```

Waiting forever would end with the monitoring system killing the check, which reports
nothing at all. Keep the timeout below `service_check_timeout` so this message, rather than
that silence, is what a stuck neighbour produces. A held latch still wins here too: giving
up on the lock is a note on the CRITICAL, not a replacement for it.

A lock file that cannot be *used* at all — a symlink planted at its name, a state directory
gone read-only — is a different case from one that is merely held, and waiting would not
help. Without a latch that is UNKNOWN; with one it stays CRITICAL. `--reset` is the
exception: it goes ahead without the lock and says so, because a latch that only `--reset`
can clear must not be held hostage by the lock file either.

```text
OK - latch cleared for /var/log/myapp/app.log (cleared without the lock, a concurrent run could undo this: [Errno 62] Too many levels of symbolic links: '...')
```

That note is the trade being made. A run that took the lock *before* it broke still holds
the state as it was, and whatever it writes when it finishes lands on top of the reset —
so the latch can come back on the next check. Fix the lock file and confirm the reset took.

### `--scan-timeout`

Nothing in this plugin blocks, but a *pattern* can still take unbounded time. Nested
quantifiers like `(a+)+` or `(\w+)*` backtrack catastrophically: on a line of a few dozen
characters that cannot match, one `re.search` runs for longer than any monitoring system
waits, and a killed check reports nothing at all.

So the scan itself has a deadline, 30 seconds by default:

```text
UNKNOWN - scan of /var/log/myapp/app.log did not finish within 30s
```

That is generous next to any real scan — 40 MB of log matches in well under a second — so
hitting it means the pattern needs fixing, not that the limit is too low. Nothing is saved
when it fires: the scan stopped part-way through, so the next run reads the same bytes and
reports the same thing until the pattern is corrected. A held latch wins here as well.

`0` disables the deadline. Keep the value below `service_check_timeout` either way.

## Performance data

Every exit that measured something emits the same three labels, so a graph does not gap
when a check happens to reset, or to find the log file missing:

```text
scanned_bytes  bytes of complete lines scanned in this run
matches        lines that matched in this run
latched        1 while the latch is held, 0 otherwise
```

Exits that measured nothing carry no performance data: an unreadable log, a broken state
file, a bad command line. Two things keep the labels anyway. A *missing* log file is a
measurement, of zero, so those exits carry the labels whatever `--missing` was set to. And
any exit that reports a held latch emits `latched=1` with zeros beside it, so the graph
shows the alert standing even on a run that could not read anything.

Plugin output is also sanitized. Nagios cuts output at the first `|` and reads the rest as
performance data, so a matched log line that contains a `|` — pipe-separated logs are
common — would otherwise truncate the message and corrupt the graph. Any `|` in a message
becomes `/`:

```text
2026-07-08 | FATAL | disk full     ->     latest='2026-07-08 / FATAL / disk full'
```

Control characters become spaces for the same reason — a newline would start the
long-output section. Matched lines are additionally quoted through `repr()`, which escapes
them rather than dropping them.

Terminal escape sequences are removed whole, and earlier: a log line is stripped of them as
soon as it is read, before any pattern is applied to it. Rust and Go loggers colour their
levels, and a log redirected to a file keeps the colour with nothing left to render it:

```text
\x1b[31mERROR\x1b[0m db down     ->     latest='ERROR db down'
```

This matters to more than the display. Patterns see the stripped line, so `-p '^ERROR'`
anchors to the word rather than to the colour in front of it, and `-p 'ERROR db'` is not
defeated by the reset code in between. `--max-output` counts the characters that are shown
for the same reason.

What reaches the state file is the line after that: the escapes gone, runs of whitespace
collapsed to a single space, and `--max-output` applied. A `|`, and any control character
that is not whitespace, is recorded as it stood and neutralized only on the way out.

## Nagios configuration

### Command definition

```nagios
define command {
  command_name  check_log_latch
  command_line  $USER1$/check_log_latch -F '$ARG1$' -p '$ARG2$' -t '$ARG3$' -s /var/spool/nagios/check_log_latch
}
```

### Service definition

```nagios
define service {
  use                   generic-service
  host_name             myapp-host
  service_description   MyApp latched error log
  check_command         check_log_latch!/var/log/myapp/app.log!FATAL|panic|connection refused!myapp

  normal_check_interval 5
  retry_check_interval  1
  max_check_attempts    1

  notification_options  c,r
}
```

### `max_check_attempts`

Use `1`. Log detection is inherently event-like: with `max_check_attempts 3`, a plain
`check_log` turns the first CRITICAL into a soft state, and the retry may return OK before
anything is notified. This plugin would hold CRITICAL through the retries anyway, but
going hard on the first check keeps the behavior obvious.

### `notification_options`

With a latching check, recovery notifications carry real meaning:

```nagios
notification_options c,r
```

After `--reset`, the next check returns OK and a recovery notification is sent. With a
plain `check_log` the state returns to OK by itself five minutes later, so `r` is mostly
noise there and is usually dropped:

```nagios
notification_options c
```

## Design note: what can clear a latch

Only `--reset`. Everything else a run can walk into is reported *alongside* the CRITICAL,
never instead of it — otherwise a full disk or a `chmod` would silently retire an alert
nobody acknowledged:

| Situation | Without a latch | With a latch |
|---|---|---|
| Log file missing | `--missing` (default UNKNOWN) | CRITICAL |
| Log file unreadable, or not a regular file | UNKNOWN | CRITICAL |
| Another run holds the lock | UNKNOWN | CRITICAL |
| Lock file unusable at all | UNKNOWN | CRITICAL |
| State file cannot be written | UNKNOWN | CRITICAL |
| Scan hit `--scan-timeout` | UNKNOWN | CRITICAL |
| `latch` present but damaged | — | CRITICAL, details unknown |
| State file unreadable or not an object | UNKNOWN | UNKNOWN |

The last row is the one place a latch does not survive, and it is not a downgrade to OK: a
state file that cannot be read holds no latch to honour and no offset to trust, so the run
reports that instead of guessing. `--reset` recovers it.

`--reset` itself is never blocked by any of the above. It needs no regex, no readable log
file, no intact state file, and no usable lock file.

## Design note: the offset advances even while latched

The single most important property of this plugin is that **the read offset keeps moving
forward while CRITICAL is latched.** Without that:

```text
1. An error line is detected, CRITICAL
2. The latch is set
3. A human checks and resets
4. The offset is still back at the old position
5. The same error line is detected again
6. CRITICAL again, immediately
```

— which is a check that can never be cleared. So every run reads the log and advances the
offset; only the latch state persists, and old lines are never re-matched.

## State file

The state file stores the read position and the latch. It is written with mode `0600`,
independent of the umask.

```json
{
  "file": "/var/log/myapp/app.log",
  "fingerprint": "1ff7e57112eec4b23ed2cf53a795c82689ebdd1d",
  "fingerprint_bytes": 256,
  "identity": [
    16777232,
    149095429
  ],
  "last_check": "2026-07-08T10:00:00+09:00",
  "latch": {
    "count": 1,
    "first_match": "FATAL database connection failed",
    "first_pattern": "FATAL|panic",
    "last_seen": "2026-07-08T10:00:00+09:00",
    "latest_match": "FATAL database connection failed",
    "latest_pattern": "FATAL|panic",
    "since": "2026-07-08T10:00:00+09:00"
  },
  "offset": 339
}
```

The plugin returns CRITICAL for as long as `latch` is present — *present*, not well-formed.
A `latch` whose contents did not survive whatever happened to the file still says a match
was seen once, and only `--reset` gets to take that back. What such a latch cannot say is
when, or what matched, so the message reports those as unknown:

```text
CRITICAL - log pattern latched since unknown; count=unknown; latest='unknown'; clear with --reset
```

If the file is damaged past the point where even that can be read — valid JSON that is not
an object, malformed JSON, bytes that are not UTF-8 — there is no latch to find and no
position to trust, and the run is UNKNOWN rather than a silent fresh start:

```text
UNKNOWN - invalid state file /var/spool/nagios/check_log_latch/myapp.json: not a JSON object
```

`--reset` discards such a file and starts over, so this cannot become a dead end either.

### File identity

Two signals decide whether this is still the same file:

```text
identity           the (st_dev, st_ino) pair
fingerprint        SHA-1 of the leading bytes
fingerprint_bytes  how many bytes went into it, at most 256
```

An inode number alone is not unique across filesystems, hence the pairing with `st_dev`.
But `st_dev` itself can change across a reboot, an LVM/dm remap, or an NFS remount.
Deciding on `identity` alone would read those as a rotation, restart from the beginning of
the file, and **raise CRITICAL on an error line from days ago**.

So when both sides have a fingerprint, the decision is made on the fingerprint and the
inode, leaving `st_dev` out of it:

```text
fingerprint and inode both match     same file; continue from offset
either one differs                   different file; treat as rotation and read from the start
```

The inode has to agree as well because a fingerprint is only the leading bytes. A log that
opens with a fixed banner produces the same fingerprint after every rotation, and on the
fingerprint alone the new file would be read from the previous file's offset — silently
skipping everything in front of it.

A file with fewer than 256 bytes in it is fingerprinted over however many it has, and
`fingerprint_bytes` records how many that was, so the next run can hash exactly the same
leading bytes and compare like with like. Fingerprinting only files that reach the full 256
would leave a short log with nothing but its inode to go on — and an inode survives being
truncated in place, so a rewritten short log would read as an ordinary append and the lines
that replaced its contents would never be scanned.

A file that has since grown *shorter* than the length its fingerprint was taken at cannot
be the file that fingerprint came from, and is treated as a rotation.

Only an empty file has nothing to hash. There the inode alone decides — `st_dev` stays out
of that comparison too, for exactly the reason above: a quiet little log file must not be
re-read from the start, and re-latch its history, because a reboot renumbered the device it
lives on. If there is no stored inode either, the offset has nothing behind it and the file
is read from the start: re-reading a line costs a CRITICAL that `--reset` clears, while
trusting an unbacked offset would skip the line the check exists to find.

What remains uncovered is a log that is truncated, refilled past the stored offset, and
happens to reproduce its own first 256 bytes — a fixed banner, rewritten in place. The
inode is unchanged and the fingerprint matches, so that reads as an append.

## Comparison with `check_log`

| | `check_log` | check_log_latch |
|---|---|---|
| Detects new log lines | yes | yes |
| Next check | back to OK | stays CRITICAL |
| Manual clear | none | `--reset` |
| Recovery notification | tends to be noise | meaningful |
| Persisted state | offset only | offset + latch |
| General-purpose monitoring | weak | strong |

## Operational notes

### Operational flow

```text
Check the log diff every 5 minutes
↓
A matching line appears
↓
CRITICAL notification
↓
The latch is saved to the state file
↓
CRITICAL persists on later checks
↓
A human investigates the log and the cause
↓
--reset clears the latch
↓
The next check is OK / recovery notification
```

### Pair it with a freshness check

This plugin reports only what it reads. With no latch held, a log that has stopped being
written produces no matching lines, so the check returns the same OK it returns when the
application is healthy. A process that died before it could log anything, a logger left
holding the handle of a file that was rotated away, a filesystem remounted read-only — none
of them show up here. A missing file is UNKNOWN by default (`--missing`, ignored while
latched), but a file that merely stopped growing looks exactly like a quiet one.

So watch the file's age alongside it. `check_file_age` ships with monitoring-plugins and
goes WARNING, then CRITICAL, once a file has not been modified for a given number of
seconds:

```nagios
define command {
  command_name  check_file_age
  command_line  $USER1$/check_file_age -f '$ARG1$' -w $ARG2$ -c $ARG3$
}
```

```nagios
define service {
  use                   generic-service
  host_name             myapp-host
  service_description   MyApp log freshness
  check_command         check_file_age!/var/log/myapp/app.log!900!3600

  normal_check_interval 5
  max_check_attempts    3
}
```

Set the thresholds above the log's quietest normal stretch, or a service that goes idle
overnight will alert every night. A log too sparse for any threshold — one that gets a line
only when something goes wrong — is better left to this plugin alone.

The freshness check needs no latch of its own: staleness persists by itself until writing
resumes, and clears the moment it does. Between the two, each covers what the other cannot
see — check_log_latch says the application reported something bad, `check_file_age` says
the application is still reporting at all.

### State directory permissions

```sh
install -d -o nagios -g nagios -m 0750 /var/spool/nagios/check_log_latch
```

Do not use a directory anyone can write to. Where another user can pre-create a directory
of the same name, they could swap out the state file — clearing the latch behind your
back, or planting arbitrary content.

The plugin checks the state directory's owner and its group- and world-write bits, and
opens the state file, temporary file, and lock file without following symlinks. Directories
it has to create itself — including intermediate ones — are created at `0750` regardless of
the umask in force. That still assumes the parent directory was set up correctly.

### Keep tags unique

Sharing a tag between services makes their state files collide, and with them their latches.

Bad:

```text
service A: -t app
service B: -t app
```

Good:

```text
service A: -t app-fatal
service B: -t app-timeout
```

### Point `--reset` at the log the state belongs to

A state file remembers which log file it was last used for, and says so when that changes:

```text
OK - no matching log lines; scanned_bytes=0 (state last used for a different log file: /var/log/myapp/old.log)
```

Usually that means a `-F` that does not match the rest of the service definition. It matters
most on `--reset`, which records a position from whatever `-F` names: aim it at the wrong
path and the next real check reads its own log as rotated, scans it from the start, and
re-latches its history. The note clears itself on the following run.

### Escape your regexes

To look for a literal `[ERROR]`, escape the brackets:

```sh
-p '\[ERROR\]'
```

### Write patterns against the log as you read it

Terminal escape sequences are stripped before matching, so a coloured line is matched as
though it had never been coloured. There is no need to allow for the colour in a pattern,
and no way to match it.

### Avoid nested quantifiers

A quantifier inside a quantified group — `(a+)+`, `(\w+)*`, `(.*,)*` — backtracks
catastrophically on input that almost matches, and a few dozen characters are enough to
run for hours. `--scan-timeout` keeps that from silently eating the check, but the run
still reports UNKNOWN and scans nothing until the pattern is fixed. Prefer one quantifier
per group, and anchor what you can.

### Do not scan history on the first run

Starting from EOF is the safer default. Scanning existing content can raise a CRITICAL for
an error that happened days ago.

## Development

```sh
task lint    # ruff on the plugin, shellcheck on the test script
task test    # tests/run_tests.sh
task check   # both
```

Linting runs [ruff](https://docs.astral.sh/ruff/) through [Task](https://taskfile.dev/) and
[uv](https://docs.astral.sh/uv/). The ruff version is pinned in `Taskfile.yml` and the rule
set lives in `ruff.toml`, so results do not drift between machines. `task lint:fix` applies
ruff's safe autofixes.

`tests/run_tests.sh` drives the plugin end to end in throwaway directories and needs nothing
but `bash` and the interpreter under test. Point `PYTHON` at another interpreter to check it:

```sh
PYTHON=python3.8 bash tests/run_tests.sh
```

GitHub Actions runs the same lint, and the tests on Python 3.8, 3.11 and 3.14 on Linux plus
Python 3.14 on macOS — see `.github/workflows/ci.yml`.

## License

[MIT](LICENSE)
