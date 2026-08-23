#!/usr/bin/env python3
"""
check_log_latch.py - Nagios plugin: detect regex in appended log lines and keep CRITICAL latched until reset.

Typical:
  check_log_latch.py -F /var/log/myapp/app.log -p 'FATAL|panic' -t myapp

Reset:
  check_log_latch.py -F /var/log/myapp/app.log -t myapp --reset
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import sys
import time
from pathlib import Path
from typing import Any, BinaryIO, Iterator, NamedTuple, NoReturn

VERSION = "0.1.1"

OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3

STATUS_NAMES = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}

DEFAULT_STATE_DIR = "/var/spool/nagios/check_log_latch"
STATE_DIR_MODE = 0o750
STATE_FILE_MODE = 0o600

# Leading bytes hashed to recognize a log file across device renumbering (reboot,
# LVM/dm remap, NFS remount) without mistaking a rotated file for the previous one.
FINGERPRINT_BYTES = 256

# How long a run waits for the one in front of it before reporting instead of being killed.
DEFAULT_LOCK_TIMEOUT = 10.0
LOCK_POLL_SECONDS = 0.05

# How long the scan itself may take before the same thing happens. Generous next to any real
# scan -- 40 MB of log matches in well under a second -- and short next to the timeout a
# monitoring system gives a plugin.
DEFAULT_SCAN_TIMEOUT = 30.0

# Escape sequences and stray control bytes have no business reaching a terminal or a web
# console, whatever a log line or a hand-edited state file has to say about it.
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")

# Colour, and everything else a terminal reads as an instruction rather than as text. Rust
# and Go loggers colour their levels, and a log redirected to a file keeps the colour with
# nothing left to render it, so the sequences arrive here as content nobody meant to write.
# Dropping each one whole -- rather than blanking the ESC and leaving "[31m" behind -- is
# what lets a pattern see the line the way the log means it to be read.
#
# Whole means the payload too. The string controls carry one as far as their terminator,
# and a terminal displays none of it, so leaving it behind would offer a pattern text that
# no one reading the log could ever see.
ANSI_ESCAPES = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"              # CSI: colour, cursor movement, erase
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?"  # OSC: window titles and friends, BEL- or ST-terminated
    r"|\x1b[P^_X][^\x1b]*(?:\x1b\\)?"       # DCS, PM, APC, SOS: the other strings, ST-terminated
    r"|\x1b[@-Z\\-_]"                       # the two-character escapes
    r"|\x1b"                                # an ESC that begins none of the above
)

# The appended part of a log is matched in pieces of this size, so that the memory a run
# needs follows the longest log line rather than how much the log grew since the last one.
CHUNK_BYTES = 1024 * 1024


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def strip_escapes(text: str) -> str:
    """
    Drop terminal escape sequences from log text.

    This runs before a line is matched, not only before it is reported. A pattern written
    against what the log looks like -- "^ERROR", or "ERROR myapp" reaching across the reset
    code that follows the level -- would otherwise be defeated by the colour around the
    word, which is a hard failure to see from the outside.

    The guard keeps the cost off logs that carry no escapes at all: one substring search per
    line instead of a substitution, on what is the whole file for most hosts.
    """
    return ANSI_ESCAPES.sub("", text) if "\x1b" in text else text


def sanitize_output(message: str) -> str:
    """
    Make a message safe to hand to Nagios.

    Nagios cuts plugin output at the first "|" and reads everything after it as performance
    data, and a newline starts the long-output section. Log lines are quoted into these
    messages, so neither character may survive into one.

    Every other control character goes too. Matched lines are already quoted through repr(),
    which escapes them, but the state file also carries text into these messages, and a
    plugin does not get to hand an escape sequence to whatever renders its output.
    """
    return CONTROL_CHARACTERS.sub(" ", message.replace("|", "/"))


def perfdata(scanned: int, matches: int, latched: bool) -> dict[str, str]:
    """The same labels on every exit that measured something, so the graphs do not gap."""
    return {
        "scanned_bytes": f"{scanned}B",
        "matches": str(matches),
        "latched": "1" if latched else "0",
    }


def nagios_exit(code: int, message: str, perf: dict[str, str] | None = None) -> NoReturn:
    message = sanitize_output(message)
    if perf:
        message = f"{message} | " + " ".join(f"{k}={v}" for k, v in perf.items())
    try:
        print(message)
        sys.stdout.flush()
    except OSError:
        # There is no stdout left to report on -- a closed pipe, a full disk. Coming back
        # through here to say so would fail in exactly the same way, and the exit code
        # reaches the monitoring system regardless, so leave without touching the stream.
        os._exit(code)
    raise SystemExit(code)


def safe_name(value: str) -> str:
    """
    Turn a tag into a file name, one tag to one name.

    Folding everything outside the allowed set to "_" on its own would map "app/one" and
    "app one" to the same state file, and hand two services one shared latch. A tag that had
    to be folded therefore carries a digest of what it was before the folding.
    """
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._-")
    if name == value:
        return name
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()[:8]
    return f"{name}_{digest}" if name else digest


def default_state_file(path: str, tag: str | None, state_dir: Path) -> Path:
    if tag:
        name = safe_name(tag)
    else:
        digest = hashlib.sha1(os.path.abspath(path).encode("utf-8")).hexdigest()[:16]
        name = f"log_{digest}"
    return state_dir / f"{name}.json"


def open_nofollow(path: Path, flags: int, mode: int = STATE_FILE_MODE) -> int:
    """Open a state-directory entry, refusing to traverse a symlink planted at the final component."""
    return os.open(str(path), flags | os.O_NOFOLLOW, mode)


def ensure_state_dir(path: Path) -> None:
    """Create the state directory, then refuse to use one an untrusted user could control."""
    # mkdir(mode=...) applies to the final component only; any parent it has to create would
    # land at 0777 minus whatever umask the caller happened to have. Restrict both here.
    previous_umask = os.umask(0o777 & ~STATE_DIR_MODE)
    try:
        path.mkdir(mode=STATE_DIR_MODE, parents=True, exist_ok=True)
    except OSError as e:
        nagios_exit(UNKNOWN, f"UNKNOWN - cannot create state directory {path}: {e}")
    finally:
        os.umask(previous_umask)

    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        nagios_exit(UNKNOWN, f"UNKNOWN - state directory is a symlink: {path}")
    if info.st_uid not in (0, os.geteuid()):
        nagios_exit(UNKNOWN, f"UNKNOWN - state directory {path} is owned by uid {info.st_uid}")
    if info.st_mode & stat.S_IWOTH:
        nagios_exit(UNKNOWN, f"UNKNOWN - state directory is world-writable: {path}")
    if info.st_mode & stat.S_IWGRP:
        # Anyone in the group could swap the state file and clear a latch behind our back.
        nagios_exit(UNKNOWN, f"UNKNOWN - state directory is group-writable: {path}")


def load_state(path: Path, discard_invalid: bool = False) -> dict[str, Any]:
    """
    Read the state file.

    With discard_invalid, an unreadable or unparsable state file starts over from an empty
    state instead of failing. --reset overwrites the file anyway, and a latch that only a
    reset can clear must not become unclearable because the file behind it got corrupted.
    """
    try:
        fd = open_nofollow(path, os.O_RDONLY)
    except FileNotFoundError:
        return {}
    except OSError as e:
        if discard_invalid:
            return {}
        nagios_exit(UNKNOWN, f"UNKNOWN - cannot read state file {path}: {e}")

    try:
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            obj = json.load(f)
    except OSError as e:
        # A directory, or an I/O error part-way through the read.
        if discard_invalid:
            return {}
        nagios_exit(UNKNOWN, f"UNKNOWN - cannot read state file {path}: {e}")
    except ValueError as e:
        # Malformed JSON (JSONDecodeError) or bytes that are not UTF-8 (UnicodeDecodeError).
        if discard_invalid:
            return {}
        nagios_exit(UNKNOWN, f"UNKNOWN - invalid state file {path}: {e}")

    if not isinstance(obj, dict):
        # Valid JSON, but not a state: a list, a number, a bare string. Reading it as an
        # empty state would start over from EOF and drop a latch nobody cleared, so this
        # counts as a state file that could not be read at all.
        if discard_invalid:
            return {}
        nagios_exit(UNKNOWN, f"UNKNOWN - invalid state file {path}: not a JSON object")
    return obj


def save_state(path: Path, state: dict[str, Any]) -> None:
    """
    Replace the state file with `state`, atomically.

    Raises OSError, rather than exiting: a full disk must not clear a latch, and only the
    caller knows whether one is held.
    """
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        # Remove any leftover or planted entry (unlink does not follow symlinks) so the
        # O_EXCL below cannot be satisfied by an attacker-controlled target.
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)

        fd = open_nofollow(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            # The mode passed to open() is masked by the umask; set it explicitly instead.
            # After the fdopen() rather than before, so that a failure here closes the
            # descriptor with the rest. The umask can only ever have narrowed the mode the
            # open asked for, so nothing is exposed in between.
            os.fchmod(f.fileno(), STATE_FILE_MODE)
            json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    except OSError:
        # A full disk, a quota, a failed rename: do not leave a half-written temporary file
        # behind for the next run, and let the caller decide how to report it.
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def lock_state(lock_path: Path, timeout: float) -> int | None:
    """
    Take the state lock, or give up after `timeout` seconds and return None.

    A blocking flock would sit here until the monitoring system kills the check, and a killed
    check reports nothing at all -- the same reason a fifo is never opened blocking. Waiting
    with a deadline turns "the run in front of me is still going" into something the plugin
    can say out loud.

    Raises OSError when the lock file cannot be used at all -- a symlink planted at its name,
    a directory gone read-only. That is for the caller to report against the state file's
    latch, so that a lock file nobody can open cannot clear an alert either.
    """
    fd = open_nofollow(lock_path, os.O_CREAT | os.O_RDWR)

    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError as e:
            if e.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(fd)
                raise
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(LOCK_POLL_SECONDS)


def status_for_missing(mode: str) -> int:
    return {"ok": OK, "warning": WARNING, "critical": CRITICAL, "unknown": UNKNOWN}[mode]


def open_log(log_path: Path) -> BinaryIO:
    """
    Open the log file for reading, without ever blocking on it.

    A fifo or a device node at this path would otherwise stall open() until the monitoring
    system kills the check. O_NONBLOCK returns immediately, and the file type is then judged
    on the descriptor itself, so the answer cannot change between the check and the read.
    """
    fd = os.open(str(log_path), os.O_RDONLY | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(errno.EINVAL, "not a regular file", str(log_path))
    return os.fdopen(fd, "rb")


def decode_line(raw: bytes) -> str:
    r"""
    Turn the bytes of one line into text.

    Lines are cut on "\n" and on nothing else. str.splitlines() would also break on \x0b,
    \x0c, \x1c-\x1e, \x85 and U+2028, none of which end a line for the byte-level offset
    accounting, so a pattern spanning one of them would silently stop matching. A trailing
    "\r" is dropped instead, so that a CRLF log still anchors at the end of its lines.
    """
    line = raw.decode("utf-8", errors="replace")
    return line[:-1] if line.endswith("\r") else line


class MatchSummary(NamedTuple):
    count: int
    first: tuple[str, str] | None
    latest: tuple[str, str] | None


def match_lines(
    f: BinaryIO,
    start: int,
    end: int,
    patterns: list[re.Pattern[str]],
    drop_first_line: bool,
) -> tuple[int, MatchSummary]:
    """
    Match every complete line in [start, end), and report where the last one ended.

    The range is read in chunks, and only the line being assembled is held, so a burst of
    log volume cannot cost memory in proportion to itself. Only the number of matches and
    the two end points are kept, for the same reason.

    An incomplete trailing line is deliberately left unconsumed, so that a pattern split
    across two check intervals is evaluated once the line has been completed.
    """
    count = 0
    first: tuple[str, str] | None = None
    latest: tuple[str, str] | None = None
    consumed = start
    pending = b""

    f.seek(start)
    remaining = end - start
    while remaining > 0:
        chunk = f.read(min(CHUNK_BYTES, remaining))
        if not chunk:
            break
        remaining -= len(chunk)
        pending += chunk

        # Walk the chunk by index; slicing the buffer per line would copy the rest of it
        # every time, which turns a chunk full of short lines into quadratic work.
        line_start = 0
        while True:
            newline = pending.find(b"\n", line_start)
            if newline < 0:
                break
            raw = pending[line_start:newline]
            consumed += newline - line_start + 1
            line_start = newline + 1

            if drop_first_line:
                drop_first_line = False
                continue

            line = strip_escapes(decode_line(raw))
            for regex in patterns:
                if regex.search(line):
                    count += 1
                    if first is None:
                        first = (regex.pattern, line)
                    latest = (regex.pattern, line)
                    break
        pending = pending[line_start:]

    return consumed, MatchSummary(count, first, latest)


def read_prefix(f: BinaryIO) -> bytes:
    """The leading bytes every fingerprint in one run is taken from, read once."""
    f.seek(0)
    return f.read(FINGERPRINT_BYTES)


def prefix_digest(prefix: bytes, length: int) -> str | None:
    """
    Hash of the file's first `length` bytes, or None when the file does not hold that many.

    Fingerprinting only files that reach the full FINGERPRINT_BYTES would leave short logs
    with nothing but their inode to go on, and an inode survives being truncated in place --
    a rewritten short log would read as a plain append and its new lines would be skipped.
    Hashing however much there is, and recording how much that was, covers those too.

    None for a file that has grown shorter than the length its fingerprint was taken at: it
    cannot be the file that fingerprint came from, and None never compares equal to a digest.
    """
    if length <= 0 or len(prefix) < length:
        return None
    return hashlib.sha1(prefix[:length]).hexdigest()


def same_inode(prev_identity: Any, identity: list[int], *, if_unknown: bool) -> bool:
    """
    Compare inode numbers only.

    st_dev is unstable across reboots, LVM/dm remaps and NFS remounts, so it cannot take
    part in this comparison.

    A state file without a usable pair says nothing, so the caller supplies the answer for
    that case: alongside a matching fingerprint there is other evidence that this is the
    same file, and without one there is none at all.
    """
    if not (isinstance(prev_identity, list) and len(prev_identity) == 2):
        return if_unknown
    return prev_identity[1] == identity[1]


class ScanTimeout(Exception):
    """The scan did not finish inside the time it was given."""


@contextlib.contextmanager
def scan_deadline(seconds: float) -> Iterator[None]:
    """
    Raise ScanTimeout if the body is still running after `seconds`, or never with 0.

    Nothing here blocks, but a pattern can still take unbounded time: `(a+)+` and friends
    backtrack for longer than any monitoring system waits, and a check that gets killed
    reports nothing at all -- the one outcome this plugin exists to avoid. CPython polls for
    signals from inside the regex engine's own matching loop, so the alarm lands even in the
    middle of one.
    """
    if not seconds:
        yield
        return

    def on_alarm(signum: int, frame: Any) -> NoReturn:
        raise ScanTimeout

    # ITIMER_REAL is taken outright rather than saved and restored: this runs as a plugin,
    # once, from __main__, and there is no outer timer of its own to put back. An alarm that
    # lands between the body finishing and the timer being cleared raises out of the finally
    # and is caught by the same handler as any other timeout -- one run reported as UNKNOWN
    # instead of OK, which the next check corrects.
    previous = signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


class ScanResult(NamedTuple):
    scanned_bytes: int
    next_offset: int
    identity: list[int]
    fingerprint: str | None
    fingerprint_bytes: int
    rotated: bool
    limited_by_max_bytes: bool
    initialized_at_eof: bool
    matches: MatchSummary


def scan_log(
    log_path: Path,
    state: dict[str, Any],
    patterns: list[re.Pattern[str]],
    from_start: bool,
    max_bytes: int | None,
) -> ScanResult:
    """
    Match the log lines appended since the previous run.
    """
    prev_identity = state.get("identity")
    prev_offset = state.get("offset")
    prev_fingerprint = state.get("fingerprint")
    # State files written before fingerprints had a length always hashed the full 256 bytes.
    prev_fingerprint_bytes = state.get("fingerprint_bytes", FINGERPRINT_BYTES)
    first_run = prev_identity is None and prev_offset is None

    rotated = False
    initialized_at_eof = False

    with open_log(log_path) as f:
        # Stat the open descriptor, not the path: a rotation between stat() and open()
        # would otherwise pair the old file's identity and size with the new file's bytes.
        info = os.fstat(f.fileno())
        identity = [info.st_dev, info.st_ino]
        current_size = info.st_size

        # Hash exactly the bytes that were read, however many that turned out to be, so the
        # digest and the length it belongs to can never disagree.
        prefix = read_prefix(f)
        fingerprint_bytes = len(prefix)
        fingerprint = prefix_digest(prefix, fingerprint_bytes)

        if first_run:
            # Do not alert on old history unless explicitly requested.
            start = 0 if from_start else current_size
            initialized_at_eof = not from_start
        else:
            comparable = isinstance(prev_fingerprint, str) and isinstance(prev_fingerprint_bytes, int)
            if comparable:
                # Re-hash the same leading bytes the stored digest was taken from. Survives
                # device renumbering, and still spots in-place replacement -- including a
                # short log truncated and rewritten, which keeps its inode.
                #
                # The inode has to agree as well: a rotated file that opens with the same
                # banner would otherwise be read from the stale offset, skipping the lines
                # in front of it.
                same_content = prefix_digest(prefix, prev_fingerprint_bytes) == prev_fingerprint
                same_file = same_content and same_inode(prev_identity, identity, if_unknown=True)
            else:
                # An empty file leaves nothing to hash, so the inode is all there is. st_dev
                # stays out of this comparison here as well: a reboot that renumbers the
                # device must not turn a quiet little log file into a rotation and re-latch
                # its history.
                #
                # With no inode to compare against either, there is nothing left to go on,
                # and reading from the start is the side to err on: re-reading a line costs
                # a CRITICAL that --reset clears, while trusting a stale offset would skip
                # the line that the check exists to find.
                same_file = same_inode(prev_identity, identity, if_unknown=False)

            if same_file and isinstance(prev_offset, int):
                start = prev_offset
                if start > current_size:
                    # Same file, smaller than before: truncation.
                    start = 0
                    rotated = True
            else:
                # A different file now lives at this path: likely log rotation.
                # We can only read the new file via this path, so scan it from the start.
                start = 0
                rotated = True

        limited_by_max_bytes = False
        if max_bytes and current_size - start > max_bytes:
            start = max(0, current_size - max_bytes)
            limited_by_max_bytes = True

        # Half a line is not a log line: an anchored pattern would match text that never was
        # at the start of one. The byte in front says whether this offset is a line boundary,
        # so a line that happens to begin exactly here is not thrown away.
        #
        # Asked on every resume, not only right after the cap moved the offset. The cap lands
        # wherever the arithmetic puts it, and when the bytes it left behind hold no newline
        # at all, nothing is consumed and that mid-line offset is what the next run resumes
        # from -- with no cap of its own to tell it so.
        drop_first_line = False
        if start > 0:
            f.seek(start - 1)
            drop_first_line = f.read(1) != b"\n"

        next_offset, matches = match_lines(f, start, current_size, patterns, drop_first_line)

    return ScanResult(
        next_offset - start,
        next_offset,
        identity,
        fingerprint,
        fingerprint_bytes,
        rotated,
        limited_by_max_bytes,
        initialized_at_eof,
        matches,
    )


def compile_patterns(patterns: list[str], ignore_case: bool) -> list[re.Pattern[str]]:
    flags = re.IGNORECASE if ignore_case else 0
    compiled: list[re.Pattern[str]] = []
    for pattern in patterns:
        try:
            compiled.append(re.compile(pattern, flags))
        except re.error as e:
            nagios_exit(UNKNOWN, f"UNKNOWN - invalid regex {pattern!r}: {e}")
    return compiled


def clip(s: str, limit: int) -> str:
    s = s.replace("\t", " ").strip()
    s = re.sub(r"\s+", " ", s)
    return s if len(s) <= limit else s[: limit - 1] + "…"


def condition_suffix(*notes: str | None) -> str:
    present = [note for note in notes if note]
    return f" ({'; '.join(present)})" if present else ""


def latch_of(state: dict[str, Any]) -> dict[str, Any] | None:
    """
    The latch held by this state, or None when there is none.

    A "latch" that is not an object still says a match was seen once, and only --reset gets
    to take that back. What it cannot say is when, or what matched, so it comes back empty
    and the message reports those as unknown. Treating it as no latch at all would turn a
    hand-edited or half-written state file into a recovery notification nobody earned.
    """
    if "latch" not in state:
        return None
    latch = state["latch"]
    return latch if isinstance(latch, dict) else {}


def is_count(value: Any) -> bool:
    """
    Whether this is a tally this plugin could have written.

    bool is an int to Python, and `True + 1` is 2; a count below zero is not a number of
    matches at all. Either one means a state file that was edited or damaged, not a tally.
    """
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def latch_count(latch: dict[str, Any]) -> int:
    """The tally so far, counting anything this plugin could not have written as nothing."""
    return latch["count"] if is_count(latch.get("count")) else 0


def latch_message(latch: dict[str, Any], suffix: str) -> str:
    """
    Report a held latch.

    Every field is checked before it is printed rather than trusted: a state file damaged
    enough to hold a latch that is not an object can just as easily hold a "since" that is
    not a date. What cannot be read out is reported as unknown, which is the one thing that
    is certainly true about it.

    The matched line is stripped again on the way out. It was stripped on the way in, but a
    latch written by an older version, or by a hand that edited the file, is a latch this
    one still has to report, and only --reset would otherwise be rid of the escapes in it.
    """
    since = latch.get("since")
    latest = latch.get("latest_match")
    count = latch.get("count")
    return (
        f"CRITICAL - log pattern latched since {since if isinstance(since, str) else 'unknown'}; "
        f"count={count if is_count(count) else 'unknown'}; "
        f"latest={(strip_escapes(latest) if isinstance(latest, str) else 'unknown')!r}; "
        f"clear with --reset{suffix}"
    )


def exit_latched_or(
    state: dict[str, Any],
    note: str,
    code: int,
    message: str,
    perf: dict[str, str] | None = None,
) -> NoReturn:
    """
    Exit CRITICAL when a latch is held, and with the state the caller asked for otherwise.

    Only --reset clears a latch. Everything else a run can walk into -- the log file gone, or
    unreadable, another run still holding the lock, a lock file that will not open, a state
    file that will not write -- is a note on that CRITICAL, never a replacement for it.
    Reporting UNKNOWN instead would let a chmod, a full disk, or a slow neighbour downgrade
    an alert nobody has acknowledged.
    """
    latch = latch_of(state)
    if latch is not None:
        nagios_exit(CRITICAL, latch_message(latch, condition_suffix(note)), perfdata(0, 0, latched=True))
    nagios_exit(code, message, perf)


def previous_file_note(state: dict[str, Any], log_path: Path) -> str | None:
    """
    Say so when this state was last used for a different log file.

    Usually a -F that does not match the one the state file was created with, and worth
    seeing: a --reset aimed at the wrong path records the wrong position, and the next real
    check then reads its log as rotated and re-latches its history.
    """
    previous = state.get("file")
    if isinstance(previous, str) and previous != str(log_path):
        return f"state last used for a different log file: {previous}"
    return None


def record_position(state: dict[str, Any], log_path: Path) -> str | None:
    """
    Point the state at the current end of file, so old lines are not re-detected.

    Returns a note when there was no end of file to point at, for the caller to report.
    """
    try:
        with open_log(log_path) as f:
            # Same reason as in scan_log(): identity, size and fingerprint have to describe
            # one and the same file.
            info = os.fstat(f.fileno())
            prefix = read_prefix(f)
    except OSError as e:
        # There is no end of file to seek to, so drop the position entirely: the next run
        # starts as a first run and initializes at the EOF of whatever appears here, rather
        # than scanning a freshly created log from the start and latching again at once.
        #
        # Every unopenable log is treated this way -- missing, unreadable, replaced by a
        # directory -- because a reset that fails leaves a latch nothing can ever clear.
        state.pop("identity", None)
        state.pop("fingerprint", None)
        state.pop("fingerprint_bytes", None)
        state.pop("offset", None)
        if isinstance(e, FileNotFoundError):
            return None
        return f"log file could not be read, position dropped: {e}"

    state["identity"] = [info.st_dev, info.st_ino]
    state["offset"] = info.st_size
    state["fingerprint"] = prefix_digest(prefix, len(prefix))
    state["fingerprint_bytes"] = len(prefix)
    return None


def save_state_or_exit(path: Path, state: dict[str, Any]) -> None:
    """Write the state file, and report a failure to write it without dropping the latch."""
    try:
        save_state(path, state)
    except OSError as e:
        exit_latched_or(
            state,
            f"state file cannot be written: {e}",
            UNKNOWN,
            f"UNKNOWN - cannot write state file {path}: {e}",
        )


class NagiosArgumentParser(argparse.ArgumentParser):
    """
    An argument parser that reports a usage error the way a Nagios plugin has to.

    argparse exits 2 on a bad command line, and Nagios reads 2 as CRITICAL: a typo in a
    command definition, or an $ARGn$ that never got filled in, would raise an alert about a
    log file that was never even opened. A run that could not parse its own arguments
    measured nothing, and that is UNKNOWN.
    """

    def error(self, message: str) -> NoReturn:
        nagios_exit(UNKNOWN, f"UNKNOWN - {message}")


def parse_args() -> argparse.Namespace:
    p = NagiosArgumentParser(description="Nagios plugin: latched log regex checker")
    p.add_argument("-V", "--version", action="version", version=f"%(prog)s {VERSION}")
    p.add_argument("-F", "--file", required=True, help="log file to check")
    p.add_argument("-p", "--pattern", action="append", help="critical regex; may be repeated; not required with --reset")
    # The Nagios plugin guidelines reserve -t for a timeout. The two waits this plugin has
    # are bounded under their own long names, --lock-timeout and --scan-timeout, and neither
    # is typed often; -t stays with the option operators type on every line.
    p.add_argument("-t", "--tag", help="stable name for the state file; recommended")
    p.add_argument("-s", "--state-dir", default=DEFAULT_STATE_DIR, help=f"state directory (default: {DEFAULT_STATE_DIR})")
    p.add_argument("--state-file", help="explicit state file path; overrides --state-dir and --tag")
    p.add_argument("-i", "--ignore-case", action="store_true", help="case-insensitive regex matching")
    p.add_argument("--from-start", action="store_true", help="on first run, scan existing file from the beginning")
    p.add_argument("--reset", action="store_true", help="clear the latch and seek to the current end of file")
    p.add_argument("--missing", choices=["ok", "warning", "critical", "unknown"], default="unknown", help="state when log file is missing and no latch is held")
    p.add_argument("--max-bytes", type=int, help="maximum bytes to scan in one run; older unscanned bytes are skipped")
    p.add_argument("--max-output", type=int, default=120, help="maximum characters of matched line shown")
    p.add_argument("--lock-timeout", type=float, default=DEFAULT_LOCK_TIMEOUT, help=f"seconds to wait for a concurrent run (default: {DEFAULT_LOCK_TIMEOUT:g})")
    p.add_argument("--scan-timeout", type=float, default=DEFAULT_SCAN_TIMEOUT, help=f"seconds the scan may take before giving up; 0 means no limit (default: {DEFAULT_SCAN_TIMEOUT:g})")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    if not args.reset and not args.pattern:
        nagios_exit(UNKNOWN, "UNKNOWN - -p/--pattern is required unless --reset is given")

    if args.max_output < 1:
        nagios_exit(UNKNOWN, "UNKNOWN - --max-output must be at least 1")

    if args.max_bytes is not None and args.max_bytes < 0:
        nagios_exit(UNKNOWN, "UNKNOWN - --max-bytes must not be negative (0 means no cap)")

    # Written as a range so that nan fails it: a nan deadline is never reached, and the wait
    # this option exists to bound would go on until the monitoring system stepped in. inf
    # would do the same, on purpose but no less fatally.
    if not (0 <= args.lock_timeout < float("inf")):
        nagios_exit(UNKNOWN, "UNKNOWN - --lock-timeout must be a finite, non-negative number of seconds")

    if not (0 <= args.scan_timeout < float("inf")):
        nagios_exit(UNKNOWN, "UNKNOWN - --scan-timeout must be a finite, non-negative number of seconds")

    log_path = Path(args.file)
    state_file = (
        Path(args.state_file)
        if args.state_file
        else default_state_file(args.file, args.tag, Path(args.state_dir))
    )
    ensure_state_dir(state_file.parent)

    lock_path = state_file.with_suffix(state_file.suffix + ".lock")
    lock_fd = None
    lock_note = None
    try:
        lock_fd = lock_state(lock_path, args.lock_timeout)
        if lock_fd is None:
            # Someone else is in front of us and is not done. save_state() lands its file
            # with os.replace(), so a reader without the lock sees either the whole previous
            # version or the whole next one. Enough to keep a latch from being downgraded by
            # a run that never got in.
            exit_latched_or(
                load_state(state_file, discard_invalid=True),
                f"another run still holds the lock on {state_file}",
                UNKNOWN,
                f"UNKNOWN - another run still holds the lock on {state_file} after {args.lock_timeout:g}s",
            )
    except OSError as e:
        # The lock file cannot be used at all, as opposed to being held: a symlink planted at
        # its name, a state directory gone read-only. Waiting would not help, since every
        # run after this one arrives at the same place.
        if not args.reset:
            exit_latched_or(
                load_state(state_file, discard_invalid=True),
                f"lock file cannot be used: {e}",
                UNKNOWN,
                f"UNKNOWN - cannot use lock file {lock_path}: {e}",
            )
        # A reset goes ahead without the lock. Serializing against a concurrent run is worth
        # less than the guarantee that a latch can always be cleared -- refusing here would
        # leave one that nothing short of deleting the state file could clear.
        #
        # The note says what that costs: a run that took the lock before it broke is still
        # holding the old state, and whatever it writes when it finishes lands on top of
        # this. Rare -- a lock file only breaks if something replaces it -- but the operator
        # is the one who can check, so the operator gets told.
        lock_note = f"cleared without the lock, a concurrent run could undo this: {e}"

    try:
        state = load_state(state_file, discard_invalid=args.reset)
        carried_over = previous_file_note(state, log_path)

        # Reset runs before the patterns are compiled: a regex that no longer compiles
        # must not make an existing latch impossible to clear.
        if args.reset:
            note = record_position(state, log_path)
            state.pop("latch", None)
            state["file"] = str(log_path)
            state["last_reset"] = now_iso()
            save_state_or_exit(state_file, state)
            message = f"OK - latch cleared for {log_path}{condition_suffix(carried_over, note, lock_note)}"
            nagios_exit(OK, message, perfdata(0, 0, latched=False))

        compiled = compile_patterns(args.pattern, args.ignore_case)

        if not log_path.exists():
            code = status_for_missing(args.missing)
            exit_latched_or(
                state,
                f"log file currently missing: {log_path}",
                code,
                f"{STATUS_NAMES[code]} - log file missing: {log_path}",
                perfdata(0, 0, latched=False),
            )

        try:
            with scan_deadline(args.scan_timeout):
                scan = scan_log(log_path, state, compiled, args.from_start, args.max_bytes)
        except ScanTimeout:
            # Nothing is saved: the scan stopped part-way through, and the offset it would
            # leave behind is not one any line ended at. The next run reads the same bytes
            # again, which is what a pattern that has to be fixed should keep saying.
            exit_latched_or(
                state,
                f"scan did not finish within {args.scan_timeout:g}s",
                UNKNOWN,
                f"UNKNOWN - scan of {log_path} did not finish within {args.scan_timeout:g}s",
            )
        except OSError as e:
            # Unreadable, vanished between the check above and now, or not a regular file:
            # a plugin has to report that as UNKNOWN rather than die with a traceback.
            exit_latched_or(
                state,
                f"log file cannot be read: {e}",
                UNKNOWN,
                f"UNKNOWN - cannot read log file {log_path}: {e}",
            )

        state["file"] = str(log_path)
        state["identity"] = scan.identity
        state["fingerprint"] = scan.fingerprint
        state["fingerprint_bytes"] = scan.fingerprint_bytes
        state["offset"] = scan.next_offset
        state["last_check"] = now_iso()

        latch = latch_of(state)
        first_hit, latest_hit = scan.matches.first, scan.matches.latest
        if first_hit and latest_hit:
            if not latch:
                # No latch at all, or one whose contents did not survive whatever happened
                # to the state file. Either way this match is the one it now stands on.
                latch = {
                    "since": now_iso(),
                    "first_pattern": first_hit[0],
                    "first_match": clip(first_hit[1], args.max_output),
                }
            latch["last_seen"] = now_iso()
            latch["latest_pattern"] = latest_hit[0]
            latch["latest_match"] = clip(latest_hit[1], args.max_output)
            latch["count"] = latch_count(latch) + scan.matches.count
            state["latch"] = latch

        save_state_or_exit(state_file, state)

        scanned = scan.scanned_bytes
        latch = latch_of(state)
        perf = perfdata(scanned, scan.matches.count, latched=latch is not None)
        suffix = condition_suffix(
            carried_over,
            "rotation/truncation detected" if scan.rotated else None,
            "scan limited by --max-bytes" if scan.limited_by_max_bytes else None,
        )

        if latch is not None:
            nagios_exit(CRITICAL, latch_message(latch, suffix), perf)

        if scan.initialized_at_eof:
            nagios_exit(OK, f"OK - initialized at EOF (offset={scan.next_offset}){suffix}", perf)

        nagios_exit(OK, f"OK - no matching log lines; scanned_bytes={scanned}{suffix}", perf)

    finally:
        # Closing releases the flock, and so would process exit: failures here change nothing.
        if lock_fd is not None:
            with contextlib.suppress(OSError):
                os.close(lock_fd)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A plugin that dies with a traceback exits 1, which Nagios reads as WARNING: the
        # wrong severity, for a run that in truth measured nothing. Report it as UNKNOWN.
        #
        # Exception, not BaseException: SystemExit is how every ordinary exit leaves here,
        # and a KeyboardInterrupt means someone stopped this run rather than that the check
        # could not measure anything. Both keep their own exit.
        nagios_exit(UNKNOWN, f"UNKNOWN - unhandled {type(e).__name__}: {e}")
