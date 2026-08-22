# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-23

Initial release.

### Added

- `check_log_latch.py`, a Nagios plugin that scans newly appended log lines for one or
  more regexes and keeps returning `CRITICAL` until a human clears the latch with
  `--reset`. Unlike `check_log`, which reports a match only on the run that first sees it,
  the state is held rather than the event.
- A latch that is hard to lose: it survives log rotation and truncation, device
  renumbering across reboots or remounts, and a log file that has become missing or
  unreadable. Nothing short of `--reset` clears it.
- A `--reset` that is hard to refuse: it requires neither the pattern, nor a readable log
  file, nor an intact state file, nor a usable lock file, so a latch can never become
  unclearable. Clearing also seeks to the current end of file, so old lines are not
  detected again.
- Sanitizing of every log-derived string before it reaches the status line, so a crafted
  log line cannot forge plugin output or performance data.
- A lock timeout and a scan timeout, so a run never blocks on the log file or on a
  concurrent run of the same check. Standard Nagios exit codes for unexpected failures and
  for a bad command line.
- Performance data reporting scanned bytes, match count and latch state.
- Options: `--file`, `--pattern`, `--tag`, `--state-dir`, `--state-file`,
  `--ignore-case`, `--from-start`, `--reset`, `--missing`, `--max-bytes`, `--max-output`,
  `--lock-timeout`, `--scan-timeout`, `--version`.
- A regression suite driving the plugin as a subprocess (`tests/run_tests.sh`), lint and
  test entry points in `Taskfile.yml` with a pinned ruff, and CI running ruff, shellcheck
  and the tests on Python 3.8 through 3.14 across Linux and macOS.
- Documentation in English (`README.md`) and Japanese (`README.ja.md`).

[0.1.0]: https://github.com/ryochin/check_log_latch/releases/tag/v0.1.0
