#!/usr/bin/env bash
#
# Regression tests for check_log_latch.py.
#
#   task test           # from the repository root
#   bash tests/run_tests.sh
#
# Every case runs the plugin as a subprocess in a throwaway directory and checks the
# Nagios exit code and the plugin output.

set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin="$here/../check_log_latch.py"
python=${PYTHON:-python3}

pass=0
fail=0
out=""
rc=0
expect=0
work=""
log=""
state=""

workroot=$(mktemp -d "${TMPDIR:-/tmp}/check_log_latch_tests.XXXXXX")

cleanup() {
  [ -n "${workroot:-}" ] && [ -d "$workroot" ] || return 0
  # A case deliberately makes a log file unreadable; restore access before removing.
  chmod -R u+rwX "$workroot" 2>/dev/null || true
  rm -rf -- "$workroot"
}
trap cleanup EXIT

note() { printf '\n== %s\n' "$1"; }
ok() { printf '  PASS %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL %s\n' "$1"
  printf '       exit=%s output=%s\n' "$rc" "$out"
  fail=$((fail + 1))
}

# workspace -> a fresh $work with an empty $state directory and $log unset on disk
workspace() {
  work=$(mktemp -d "$workroot/case.XXXXXX")
  log="$work/app.log"
  state="$work/state"
  # Explicitly 0700: the plugin refuses a group- or world-writable state directory, so
  # without this the whole suite would fail under a permissive umask and blame the plugin.
  mkdir -m 700 "$state"
}

# run <plugin args...> -> $out, $rc
run() {
  out=$("$python" "$plugin" "$@" 2>&1)
  rc=$?
}

# check <name> <plugin args...>, the expected exit code comes from $expect
check() {
  local name=$1
  shift
  run "$@"
  if [ "$rc" = "$expect" ]; then ok "$name"; else ng "$name (expected exit $expect)"; fi
}

expect_output() { # <name> <substring>
  case "$out" in
  *"$2"*) ok "$1" ;;
  *) ng "$1 (output does not contain '$2')" ;;
  esac
}

refute_output() { # <name> <substring>
  case "$out" in
  *"$2"*) ng "$1 (output unexpectedly contains '$2')" ;;
  *) ok "$1" ;;
  esac
}

# check_deadline <name> <seconds> <plugin args...>, the expected exit code comes from $expect
# A plugin that blocks would otherwise hang the whole suite; kill it and let the case fail.
check_deadline() {
  local name=$1 limit=$2 pid
  shift 2
  "$python" "$plugin" "$@" >"$work/deadline.out" 2>&1 &
  pid=$!
  # The watchdog polls and retires on its own once the plugin has been reaped below. Killing
  # it from here instead would make the shell announce a "Terminated" job on every good run.
  (
    while [ "$limit" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      limit=$((limit - 1))
    done
    [ "$limit" -gt 0 ] || kill -9 "$pid" 2>/dev/null
  ) &
  wait "$pid"
  rc=$?
  out=$(cat "$work/deadline.out")
  if [ "$rc" = "$expect" ]; then ok "$name"; else ng "$name (expected exit $expect)"; fi
}

# assert <name> <actual> <expected>
assert() {
  out="$2"
  rc=0
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (expected '$3')"; fi
}

file_mode() { # <path> - octal permission bits on both BSD and GNU stat
  # GNU has to come first. Its -f is --file-system, so `stat -f '%Lp' path` reads '%Lp'
  # as a second file rather than as a format: it fails on that one, prints the file
  # system of path on stdout anyway, and exits non-zero -- reaching the fallback with
  # output already emitted, and returning both concatenated. BSD stat has no -c at all,
  # so it fails cleanly and leaves stdout untouched.
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

write_banner_log() { # <path> <banner character> <trailing text>
  "$python" -c 'import sys; open(sys.argv[1], "w").write(sys.argv[2] * 256 + "\n" + sys.argv[3])' "$1" "$2" "$3"
}

bump_state_dev() { # <state file> - a device renumbering, as a reboot or an NFS remount does it
  "$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["identity"][0] += 1
json.dump(state, open(sys.argv[1], "w"))' "$1"
}

latch_count() { # <state file>
  "$python" -c 'import json, sys; print(json.load(open(sys.argv[1]))["latch"]["count"])' "$1"
}

state_offset() { # <state file>
  "$python" -c 'import json, sys; print(json.load(open(sys.argv[1]))["offset"])' "$1"
}

byte_size() { # <path>
  wc -c <"$1" | tr -d ' '
}

# hold_lock <lock file> <seconds> -> $holder, and returns once the lock is really held
hold_lock() {
  local waited=0
  rm -f "$work/held"
  "$python" -c 'import fcntl, sys, time
fd = open(sys.argv[1], "r+")
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[3], "w").close()
time.sleep(float(sys.argv[2]))' "$1" "$2" "$work/held" &
  holder=$!
  # Bounded: a holder that dies before taking the lock -- no lock file, a missing
  # interpreter -- would otherwise leave this spinning until CI's own timeout.
  while [ ! -e "$work/held" ]; do
    if [ "$waited" -ge 100 ]; then
      printf '  FAIL hold_lock did not take %s within 10s\n' "$1"
      fail=$((fail + 1))
      return 1
    fi
    waited=$((waited + 1))
    sleep 0.1
  done
}

release_lock() {
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rm -f "$work/held"
}

note "first run starts at EOF and ignores existing history"
workspace
printf 'ERROR from last week\n' >"$log"
expect=0 check "first run is OK" -F "$log" -p ERROR -s "$state" -t app
expect_output "first run reports initialization" "initialized at EOF"

note "--from-start scans existing history instead"
workspace
printf 'ERROR from last week\n' >"$log"
expect=2 check "--from-start latches on history" -F "$log" -p ERROR -s "$state" -t app --from-start
refute_output "--from-start is not an initialization" "initialized at EOF"

note "a new matching line latches and stays latched"
workspace
printf 'boot\n' >"$log"
expect=0 check "initialize" -F "$log" -p 'FATAL|panic' -s "$state" -t app
printf 'nothing to see\n' >>"$log"
expect=0 check "quiet run stays OK" -F "$log" -p 'FATAL|panic' -s "$state" -t app
expect_output "quiet run is distinguishable from initialization" "no matching log lines"
printf 'FATAL database connection failed\n' >>"$log"
expect=2 check "new match latches" -F "$log" -p 'FATAL|panic' -s "$state" -t app
expect_output "latch names the matched line" "FATAL database connection failed"
expect=2 check "latch persists without new matches" -F "$log" -p 'FATAL|panic' -s "$state" -t app
expect_output "perfdata reports the latch" "latched=1"

note "the latch outlives the log file and overrides --missing"
rm "$log"
expect=2 check "missing log stays CRITICAL while latched" -F "$log" -p 'FATAL|panic' -s "$state" -t app --missing ok
expect_output "missing log is reported" "log file currently missing"

note "--reset clears the latch and does not re-detect the old lines"
printf 'FATAL database connection failed\nrecovered\n' >"$log"
expect=0 check "reset succeeds without -p" -F "$log" -s "$state" -t app --reset
expect_output "reset reports the cleared latch" "latch cleared"
expect=0 check "next check is OK" -F "$log" -p 'FATAL|panic' -s "$state" -t app
printf 'panic later\n' >>"$log"
expect=2 check "genuinely new lines latch again" -F "$log" -p 'FATAL|panic' -s "$state" -t app

note "--reset works even when -p would not compile"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
expect=3 check "a broken regex is UNKNOWN" -F "$log" -p '[' -s "$state" -t app
expect=0 check "reset ignores the broken regex" -F "$log" -p '[' -s "$state" -t app --reset

note "--reset while the log file is missing does not re-latch afterwards"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
rm "$log"
expect=0 check "reset without a log file" -F "$log" -s "$state" -t app --reset
printf 'ERROR already in the recreated log\n' >"$log"
expect=0 check "the recreated log starts at EOF" -F "$log" -p ERROR -s "$state" -t app
printf 'ERROR appended after that\n' >>"$log"
expect=2 check "lines appended later still latch" -F "$log" -p ERROR -s "$state" -t app

note "an unusable log file is UNKNOWN, not a traceback"
workspace
mkdir "$log"
expect=3 check "a directory is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "cannot read log file"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP unreadable log file (running as root)\n'
else
  workspace
  printf 'line\n' >"$log"
  chmod 000 "$log"
  expect=3 check "an unreadable log file is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app
  expect_output "the reason is reported" "Permission denied"
fi

note "the latch outlives a log file that cannot be read"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP unreadable log file while latched (running as root)\n'
else
  workspace
  printf 'ERROR boom\n' >"$log"
  expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
  chmod 000 "$log"
  expect=2 check "an unreadable log stays CRITICAL while latched" -F "$log" -p ERROR -s "$state" -t app
  expect_output "the reason is reported" "log file cannot be read"
  expect_output "perfdata reports the latch" "latched=1"
  chmod 644 "$log"
fi
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
rm "$log"
mkdir "$log"
expect=2 check "a log path replaced by a directory stays CRITICAL while latched" \
  -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "log file cannot be read"

note "rotation, truncation and appends are told apart"
workspace
write_banner_log "$log" A "$(printf 'old filler\nold filler\n')"
expect=0 check "initialize behind the banner" -F "$log" -p ERROR -s "$state" -t app
printf 'still quiet\n' >>"$log"
expect=0 check "a plain append stays OK" -F "$log" -p ERROR -s "$state" -t app
refute_output "an append is not a rotation" "rotation/truncation detected"
# A rotated file whose first 256 bytes are identical must not be read from the stale offset.
write_banner_log "$work/rotated" A "$(printf 'ERROR in front of the old offset\n')"
"$python" -c 'import sys; open(sys.argv[1], "a").write("padding past the old offset\n" * 10)' "$work/rotated"
mv "$work/rotated" "$log"
expect=2 check "rotation behind an identical banner is caught" -F "$log" -p ERROR -s "$state" -t app
expect_output "rotation is reported" "rotation/truncation detected"
workspace
write_banner_log "$log" A "$(printf 'old filler\nold filler\n')"
expect=0 check "initialize before truncation" -F "$log" -p ERROR -s "$state" -t app
# Truncated and refilled past the old offset: too long for the size to give it away, so the
# fingerprint has to.
write_banner_log "$log" B "$(printf 'ERROR after truncate\n')"
"$python" -c 'import sys; open(sys.argv[1], "a").write("padding past the old offset\n" * 10)' "$log"
expect=2 check "truncation is caught" -F "$log" -p ERROR -s "$state" -t app
expect_output "truncation is reported" "rotation/truncation detected"
workspace
printf 'quiet and long enough to shrink below\n' >"$log"
expect=0 check "initialize before shrinking" -F "$log" -p ERROR -s "$state" -t app
printf 'ERROR\n' >"$log"
expect=2 check "a file shorter than the offset is caught" -F "$log" -p ERROR -s "$state" -t app
expect_output "shrinking is reported" "rotation/truncation detected"

note "a partial trailing line is only evaluated once it is complete"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
printf 'ERROR without a newline yet' >>"$log"
expect=0 check "an unterminated line is not matched yet" -F "$log" -p ERROR -s "$state" -t app
printf '\n' >>"$log"
expect=2 check "the completed line matches" -F "$log" -p ERROR -s "$state" -t app

note "pattern options"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p FATAL -p panic -s "$state" -t app
printf 'kernel panic\n' >>"$log"
expect=2 check "any of several -p matches" -F "$log" -p FATAL -p panic -s "$state" -t app
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p fatal -i -s "$state" -t app
printf 'FATAL upper case\n' >>"$log"
expect=2 check "-i matches case-insensitively" -F "$log" -p fatal -i -s "$state" -t app
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p fatal -s "$state" -t app
printf 'FATAL upper case\n' >>"$log"
expect=0 check "without -i the case matters" -F "$log" -p fatal -s "$state" -t app

note "--missing without a latch follows the requested state"
workspace
expect=3 check "default is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app
expect=1 check "--missing warning" -F "$log" -p ERROR -s "$state" -t app --missing warning
expect=0 check "--missing ok" -F "$log" -p ERROR -s "$state" -t app --missing ok
expect=2 check "--missing critical" -F "$log" -p ERROR -s "$state" -t app --missing critical

note "--max-bytes caps the scan and says so"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
"$python" -c 'import sys; open(sys.argv[1], "a").write("ERROR beyond the cap\n" + "x" * 4096 + "\n")' "$log"
expect=0 check "old bytes past the cap are skipped" -F "$log" -p ERROR -s "$state" -t app --max-bytes 1024
expect_output "the cap is reported" "scan limited by --max-bytes"

note "--max-output is validated"
workspace
printf 'ERRORabcdef\n' >"$log"
expect=3 check "--max-output 0 is rejected" -F "$log" -p ERROR -s "$state" -t app --from-start --max-output 0
expect=3 check "a negative --max-output is rejected" -F "$log" -p ERROR -s "$state" -t app --from-start --max-output -5
expect=2 check "--max-output 1 is accepted" -F "$log" -p ERROR -s "$state" -t app --from-start --max-output 1

note "state file and state directory hygiene"
workspace
printf 'quiet\n' >"$log"
(umask 000 && "$python" "$plugin" -F "$log" -p ERROR -s "$state" -t app >/dev/null 2>&1)
mode=$(file_mode "$state/app.json")
out="mode=$mode"
rc=0
if [ "$mode" = "600" ]; then ok "the state file is 0600 even under umask 000"; else ng "state file mode"; fi
expect=0 check "an explicit --state-file is used" -F "$log" -p ERROR --state-file "$work/explicit.json"
if [ -f "$work/explicit.json" ]; then ok "the explicit state file exists"; else ng "explicit state file"; fi
workspace
printf 'quiet\n' >"$log"
chmod 0770 "$state"
expect=3 check "a group-writable state directory is refused" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "group-writable"
chmod 0707 "$state"
expect=3 check "a world-writable state directory is refused" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "world-writable"

note "a state file that cannot be written is UNKNOWN, not a traceback"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP unwritable state directory (running as root)\n'
else
  workspace
  printf 'quiet\n' >"$log"
  expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
  chmod 0500 "$state"
  expect=3 check "an unwritable state directory is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app
  expect_output "the reason is reported" "cannot write state file"
  chmod 0700 "$state"
fi

note "the latch outlives a state file that cannot be written"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP unwritable state directory while latched (running as root)\n'
else
  workspace
  printf 'ERROR boom\n' >"$log"
  expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
  # A full disk or a quota looks like this from here. It must not clear an alert: the lock
  # file already exists, so the run gets that far and only the write fails.
  chmod 0500 "$state"
  expect=2 check "an unwritable state file stays CRITICAL while latched" -F "$log" -p ERROR -s "$state" -t app
  expect_output "the reason is reported" "state file cannot be written"
  expect_output "perfdata reports the latch" "latched=1"
  chmod 0700 "$state"
fi

note "different tags keep separate state"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize tag one" -F "$log" -p ERROR -s "$state" -t app-one
expect=0 check "initialize tag two" -F "$log" -p FATAL -s "$state" -t app-two
printf 'ERROR only\n' >>"$log"
expect=2 check "tag one latches" -F "$log" -p ERROR -s "$state" -t app-one
expect=0 check "tag two is unaffected" -F "$log" -p FATAL -s "$state" -t app-two

note "-p is required unless --reset is given"
workspace
printf 'quiet\n' >"$log"
expect=3 check "a missing -p is UNKNOWN" -F "$log" -s "$state" -t app

note "a usage error is UNKNOWN, not CRITICAL"
# argparse exits 2 by itself, and Nagios reads 2 as CRITICAL: a typo in a command definition
# would alert on a log file that was never opened.
workspace
printf 'quiet\n' >"$log"
expect=3 check "a missing -F is UNKNOWN" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "the following arguments are required"
expect=3 check "an unknown --missing value is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app --missing bogus
expect=3 check "a non-numeric --max-bytes is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app --max-bytes abc
expect=3 check "an unrecognized option is UNKNOWN" -F "$log" -p ERROR -s "$state" -t app --no-such-option

note "a log line cannot forge Nagios performance data"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
printf 'ts=1 | level=ERROR | msg=disk full\n' >>"$log"
expect=2 check "a line containing a pipe still latches" -F "$log" -p ERROR -s "$state" -t app
expect_output "the pipe is neutralized" "latest='ts=1 / level=ERROR / msg=disk full'"
assert "only the perfdata separator is left" "$(printf '%s' "$out" | tr -cd '|')" "|"

note "every exit that measured something reports the same perfdata labels"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
expect_output "a quiet run" "| scanned_bytes=0B matches=0 latched=0"
expect=0 check "reset" -F "$log" -s "$state" -t app --reset
expect_output "a reset" "| scanned_bytes=0B matches=0 latched=0"
rm "$log"
expect=0 check "a missing log without a latch" -F "$log" -p ERROR -s "$state" -t app --missing ok
expect_output "a missing log" "| scanned_bytes=0B matches=0 latched=0"

note "--reset clears the latch whatever state the log file is in"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP reset with an unreadable log file (running as root)\n'
else
  workspace
  printf 'ERROR boom\n' >"$log"
  expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
  chmod 000 "$log"
  expect=0 check "reset with an unreadable log file" -F "$log" -s "$state" -t app --reset
  expect_output "the dropped position is reported" "position dropped"
  chmod 644 "$log"
  expect=0 check "the latch is really gone" -F "$log" -p ERROR -s "$state" -t app
fi
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
rm "$log"
mkdir "$log"
expect=0 check "reset when the log path became a directory" -F "$log" -s "$state" -t app --reset
expect_output "the dropped position is reported" "position dropped"

note "an unusable state file is UNKNOWN, not a traceback"
workspace
printf 'quiet\n' >"$log"
mkdir "$state/dir.json"
expect=3 check "a state file that is a directory" -F "$log" -p ERROR --state-file "$state/dir.json"
expect_output "the reason is reported" "cannot read state file"
"$python" -c 'import sys; open(sys.argv[1], "wb").write(b"{\"offset\": 1, \"x\": \"\xff\"}")' "$state/binary.json"
expect=3 check "a state file that is not UTF-8" -F "$log" -p ERROR --state-file "$state/binary.json"
expect_output "the reason is reported" "invalid state file"
printf 'not json at all' >"$state/broken.json"
expect=3 check "a state file that is not JSON" -F "$log" -p ERROR --state-file "$state/broken.json"
expect_output "the reason is reported" "invalid state file"

note "a damaged latch still holds the CRITICAL"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
# Not an object any more. Whatever it was, a match was seen once, and only --reset takes
# that back -- reading it as "no latch" would send a recovery notification nobody earned.
"$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["latch"] = True
json.dump(state, open(sys.argv[1], "w"))' "$state/app.json"
expect=2 check "a latch that is not an object stays CRITICAL" -F "$log" -p ERROR -s "$state" -t app
expect_output "the details it can no longer give are named" "latched since unknown"
expect_output "perfdata reports the latch" "latched=1"
expect=0 check "--reset clears it all the same" -F "$log" -s "$state" -t app --reset
expect=0 check "the latch is really gone" -F "$log" -p ERROR -s "$state" -t app
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
# An object this time, but with nothing in it that can be read out. Printing these as they
# are would put a list where a date belongs, and a dict where a log line belongs.
"$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["latch"] = {"since": ["not a date"], "count": "not a number", "latest_match": {"not": "a line"}}
json.dump(state, open(sys.argv[1], "w"))' "$state/app.json"
expect=2 check "fields of the wrong type stay CRITICAL" -F "$log" -p ERROR -s "$state" -t app
expect_output "the date is not printed as a list" "latched since unknown"
expect_output "the count is not printed as text" "count=unknown"
expect_output "the line is not printed as an object" "latest='unknown'"

note "a state file that is valid JSON but not an object is UNKNOWN, not a fresh start"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
printf '[]' >"$state/app.json"
expect=3 check "a JSON array is refused" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "not a JSON object"
refute_output "it is not read as an initialization" "initialized at EOF"
expect=0 check "--reset recovers it" -F "$log" -s "$state" -t app --reset

note "a latch count that is not a number does not break the next match"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
"$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["latch"]["count"] = "not a number"
json.dump(state, open(sys.argv[1], "w"))' "$state/app.json"
printf 'ERROR again\n' >>"$log"
expect=2 check "the new match still latches" -F "$log" -p ERROR -s "$state" -t app
assert "the tally starts over from what can be counted" "$(latch_count "$state/app.json")" "1"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
# A number, but not a number of matches: carrying it forward would report a tally smaller
# than the matches actually seen, or a negative one.
"$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["latch"]["count"] = -5
json.dump(state, open(sys.argv[1], "w"))' "$state/app.json"
printf 'ERROR again\n' >>"$log"
expect=2 check "a negative count does not carry forward" -F "$log" -p ERROR -s "$state" -t app
assert "the tally starts over from zero" "$(latch_count "$state/app.json")" "1"

note "a lock file that cannot be used never clears a latch, and never blocks one from being cleared"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
ln -sf "$work/no/such/path" "$state/app.json.lock"
expect=3 check "an unusable lock file is UNKNOWN without a latch" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "cannot use lock file"
rm -f "$state/app.json.lock"
printf 'ERROR boom\n' >>"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app
ln -sf "$work/no/such/path" "$state/app.json.lock"
expect=2 check "an unusable lock file stays CRITICAL while latched" -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "lock file cannot be used"
expect_output "perfdata reports the latch" "latched=1"
# A latch that only --reset can clear must not be held hostage by the lock file either.
expect=0 check "--reset goes ahead without the lock" -F "$log" -s "$state" -t app --reset
expect_output "the missing lock is reported" "cleared without the lock"
rm -f "$state/app.json.lock"
expect=0 check "the latch is really gone" -F "$log" -p ERROR -s "$state" -t app

note "--reset recovers a state file that no longer parses"
expect=0 check "reset discards the unparsable state" -F "$log" -s "$state" -t app --state-file "$state/broken.json" --reset
expect=0 check "the next check works again" -F "$log" -p ERROR --state-file "$state/broken.json"

note "--max-bytes never cuts a line in half"
workspace
# 33 bytes of prefix, then ERRORS: an anchored pattern must not match the tail of this line.
printf 'INFO nothing here that mentions ERRORS later on\n' >"$log"
"$python" -c 'import sys; open(sys.argv[1], "a").write("y" * 50 + "\n")' "$log"
expect=0 check "a cut mid-line does not fabricate a line start" \
  -F "$log" -p '^ERROR' -s "$state" -t app --from-start --max-bytes 67
expect_output "the cap is reported" "scan limited by --max-bytes"
workspace
printf 'aaaa\nERROR at a clean boundary\n' >"$log"
expect=2 check "a line starting exactly at the cap is kept" \
  -F "$log" -p '^ERROR' -s "$state" -t app --from-start --max-bytes 26
workspace
printf 'quiet\n' >"$log"
expect=3 check "a negative --max-bytes is rejected" -F "$log" -p ERROR -s "$state" -t app --max-bytes -1
expect_output "the reason is reported" "must not be negative"
expect=0 check "--max-bytes 0 disables the cap" -F "$log" -p ERROR -s "$state" -t app --from-start --max-bytes 0
refute_output "an uncapped scan is not reported as capped" "scan limited by --max-bytes"

note "a capped run that consumed nothing does not fabricate a line start on the next run"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p '^ERROR' -s "$state" -t app
# Filler, then ERROR mid-line, then more filler, and no trailing newline anywhere: the capped
# window holds no newline, so the run consumes nothing and leaves the offset mid-line.
"$python" -c 'import sys
open(sys.argv[1], "a").write("A" * 2000 + "ERROR not at the start of a line" + "B" * 1000)' "$log"
# The cap has to land exactly on that "E", or the case would pass without testing anything.
# 6 bytes of "quiet\n" plus 2000 bytes of filler sit in front of it.
cap=$(($(byte_size "$log") - 2006))
expect=0 check "a window without a newline consumes nothing" \
  -F "$log" -p '^ERROR' -s "$state" -t app --max-bytes "$cap"
assert "the offset is left at the start of ERROR" "$(state_offset "$state/app.json")" "2006"
printf '\n' >>"$log"
expect=0 check "the resumed fragment is not read as a line" -F "$log" -p '^ERROR' -s "$state" -t app
assert "the fragment is consumed all the same" "$(state_offset "$state/app.json")" "$(byte_size "$log")"

note "without --max-bytes nothing is ever skipped"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
# A matching line, then 40 MB behind it. The size is the point of the case: a default cap
# small enough to protect memory would start reading past the ERROR and report OK, and only
# an append larger than such a cap can tell that apart from a genuinely uncapped scan.
printf 'ERROR in front of a large append\n' >>"$log"
"$python" -c 'import sys; open(sys.argv[1], "a").write(("x" * 99 + "\n") * 400000)' "$log"
expect=2 check "a match before a 40 MB append is still found" -F "$log" -p ERROR -s "$state" -t app
refute_output "no cap was applied" "scan limited by --max-bytes"
expect_output "the whole append was scanned" "matches=1"

note "only a newline ends a line"
workspace
# A form feed is a line boundary for str.splitlines() but not for the offset accounting.
"$python" -c 'import sys; open(sys.argv[1], "w").write("prefix\x0c   FATAL: real problem\n")' "$log"
expect=2 check "a form feed does not split the line" -F "$log" -p 'prefix.*FATAL' -s "$state" -t app --from-start
workspace
printf 'ERROR carriage returned\r\n' >"$log"
expect=2 check "a CRLF line still anchors at its end" -F "$log" -p 'returned$' -s "$state" -t app --from-start

note "a short log file survives a device renumbering"
workspace
printf 'ERROR from last week\n' >"$log"
expect=0 check "initialize behind a file too short to fingerprint" -F "$log" -p ERROR -s "$state" -t app
bump_state_dev "$state/app.json"
printf 'still quiet\n' >>"$log"
expect=0 check "a changed st_dev is not a rotation" -F "$log" -p ERROR -s "$state" -t app
refute_output "no rotation is reported" "rotation/truncation detected"

note "an offset with nothing to back it up is not trusted"
workspace
printf 'ERROR at the top\nquiet\n' >"$log"
# No identity and no fingerprint: too short to fingerprint, and nothing to compare the inode
# against. Reading from the stale offset here would skip the line the check exists to find.
"$python" -c 'import json, sys; json.dump({"offset": 6}, open(sys.argv[1], "w"))' "$state/app.json"
expect=2 check "an unbacked offset is read from the start" -F "$log" -p ERROR -s "$state" -t app
expect_output "it is reported as a rotation" "rotation/truncation detected"

note "a log file that is not a regular file is rejected, not waited on"
workspace
mkfifo "$log"
expect=3 check_deadline "a fifo does not block the check" 15 -F "$log" -p ERROR -s "$state" -t app
expect_output "the reason is reported" "not a regular file"

note "concurrent runs count every match exactly once"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
for i in 1 2 3 4 5 6 7 8; do printf 'ERROR %s\n' "$i" >>"$log"; done
pids=""
for _ in 1 2 3 4 5 6 7 8; do
  "$python" "$plugin" -F "$log" -p ERROR -s "$state" -t app >/dev/null 2>&1 &
  pids="$pids $!"
done
# Each exit code, not just the state left behind: one run that read every line while the
# other seven died on the lock would leave exactly the same state file.
codes=""
for pid in $pids; do
  wait "$pid"
  codes="$codes$?"
done
assert "every concurrent run reported CRITICAL" "$codes" "22222222"
assert "the latch counts each line once" "$(latch_count "$state/app.json")" "8"
assert "the offset ends at EOF" "$(state_offset "$state/app.json")" "$(byte_size "$log")"

note "a log too short to fill a fingerprint still notices being rewritten"
workspace
printf 'quiet line one\nquiet line two\n' >"$log"
expect=0 check "initialize behind a 30-byte log" -F "$log" -p ERROR -s "$state" -t app
# Truncated in place -- so the inode is unchanged -- and refilled past the old offset. Only
# the leading bytes can tell this from an ordinary append.
"$python" -c 'import sys
open(sys.argv[1], "w").write("ERROR right after the truncate\nand more, past the old offset\n")' "$log"
expect=2 check "a rewritten short log is caught" -F "$log" -p ERROR -s "$state" -t app
expect_output "it is reported as a rotation" "rotation/truncation detected"

note "the state file and its directory are never followed through a symlink"
workspace
printf 'quiet\n' >"$log"
ln -s "$work/elsewhere.json" "$state/app.json"
expect=3 check "a symlinked state file is refused" -F "$log" -p ERROR -s "$state" -t app
if [ -e "$work/elsewhere.json" ]; then ng "the symlink target is untouched"; else ok "the symlink target is untouched"; fi
workspace
printf 'quiet\n' >"$log"
mkdir "$work/real"
ln -s "$work/real" "$work/linked"
expect=3 check "a symlinked state directory is refused" -F "$log" -p ERROR -s "$work/linked" -t app
expect_output "the reason is reported" "state directory is a symlink"

note "tags that differ only in unusable characters keep separate state"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize one tag" -F "$log" -p ERROR -s "$state" -t 'app/one'
expect=0 check "initialize the other" -F "$log" -p FATAL -s "$state" -t 'app one'
printf 'ERROR only\n' >>"$log"
expect=2 check "the first tag latches" -F "$log" -p ERROR -s "$state" -t 'app/one'
expect=0 check "the second tag is unaffected" -F "$log" -p FATAL -s "$state" -t 'app one'

note "a state file carried over from another log says so"
workspace
printf 'quiet\n' >"$log"
printf 'quiet\n' >"$work/other.log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
expect=0 check "a different -F is reported" -F "$work/other.log" -p ERROR -s "$state" -t app
# Not the full path: the plugin normalizes it, and $TMPDIR may hand us a trailing slash.
expect_output "the previous log file is named" "state last used for a different log file: /"
expect=0 check "the note does not repeat" -F "$work/other.log" -p ERROR -s "$state" -t app
refute_output "the note is gone once the state caught up" "state last used for a different log file"

note "a run that cannot get the lock reports instead of waiting to be killed"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
hold_lock "$state/app.json.lock" 30
expect=3 check_deadline "a held lock is given up on" 8 -F "$log" -p ERROR -s "$state" -t app --lock-timeout 1
expect_output "the reason is reported" "another run still holds the lock"
release_lock
expect=0 check "the lock is usable again afterwards" -F "$log" -p ERROR -s "$state" -t app
printf 'ERROR boom\n' >>"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app
hold_lock "$state/app.json.lock" 30
expect=2 check_deadline "a held lock does not downgrade a latch" 8 -F "$log" -p ERROR -s "$state" -t app --lock-timeout 1
expect_output "perfdata reports the latch" "latched=1"
release_lock

note "a control character in the state file cannot reach the output"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p ERROR -s "$state" -t app
"$python" -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["latch"] = {"since": "2026-01-01\x1b[2J\x07", "count": 1, "latest_match": "boom"}
json.dump(state, open(sys.argv[1], "w"))' "$state/app.json"
expect=2 check "the latch is reported" -F "$log" -p ERROR -s "$state" -t app
assert "no control character survives" "$(printf '%s' "$out" | tr -d '[:cntrl:]')" "$out"

note "a runaway pattern is given up on rather than left to be killed"
workspace
printf 'quiet\n' >"$log"
expect=0 check "initialize" -F "$log" -p 'x' -s "$state" -t app
# Catastrophic backtracking: '(a+)+$' against a line of a's that cannot match takes longer
# than any monitoring system waits. The alarm has to land inside the regex engine itself.
"$python" -c 'import sys; open(sys.argv[1], "a").write("a" * 60 + "!\n")' "$log"
expect=3 check_deadline "a backtracking pattern gives up on time" 20 \
  -F "$log" -p '(a+)+$' -s "$state" -t app --scan-timeout 2
expect_output "the reason is reported" "did not finish within 2s"
# Nothing was saved, so the line the run gave up on is still in front of the offset. Asked
# with a pattern that matches it: a run that wrongly saved its position would leave the
# offset at EOF and this would come back OK.
assert "the offset stayed where the timed-out run found it" "$(state_offset "$state/app.json")" "6"
expect=2 check "the line the scan gave up on is still scanned next time" -F "$log" -p '!$' -s "$state" -t app
expect_output "it is the same line" "aaa"
workspace
printf 'ERROR boom\n' >"$log"
expect=2 check "latch on a match" -F "$log" -p ERROR -s "$state" -t app --from-start
"$python" -c 'import sys; open(sys.argv[1], "a").write("a" * 60 + "!\n")' "$log"
expect=2 check_deadline "a timed-out scan does not downgrade a latch" 20 \
  -F "$log" -p '(a+)+$' -s "$state" -t app --scan-timeout 2
expect_output "perfdata reports the latch" "latched=1"
workspace
printf 'quiet\n' >"$log"
expect=3 check "a negative --scan-timeout is rejected" -F "$log" -p ERROR -s "$state" -t app --scan-timeout -1
expect_output "the reason is reported" "finite, non-negative"
expect=3 check "a nan --scan-timeout is rejected" -F "$log" -p ERROR -s "$state" -t app --scan-timeout nan
# 0 takes the alarm out of the picture entirely. Proving "no limit" would mean waiting
# forever, so what is checked is that a scan still runs and still matches without one.
expect=0 check "initialize with the limit disabled" -F "$log" -p ERROR -s "$state" -t app --scan-timeout 0
printf 'ERROR with no deadline\n' >>"$log"
expect=2 check "--scan-timeout 0 still scans and matches" -F "$log" -p ERROR -s "$state" -t app --scan-timeout 0
expect_output "the line was read" "ERROR with no deadline"

note "--version reports one"
workspace
expect=0 check "-V exits OK" -V
expect_output "the version is printed" "check_log_latch"
# The plugin's own VERSION, not a copy of it here: this catches an empty or unformatted
# version without having to be edited on every release.
assert "the version matches the source" "$out" \
  "check_log_latch.py $("$python" -c 'import re, sys
print(re.search(r"^VERSION = \"(.*)\"", open(sys.argv[1]).read(), re.M).group(1))' "$plugin")"

note "the state directory is created without exposing its parents"
workspace
printf 'quiet\n' >"$log"
(umask 000 && "$python" "$plugin" -F "$log" -p ERROR -s "$work/deep/nested/state" -t app >/dev/null 2>&1)
assert "an intermediate directory is not world-writable" "$(file_mode "$work/deep")" "750"
assert "the state directory itself is not world-writable" "$(file_mode "$work/deep/nested/state")" "750"

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
