# Changelog

All notable changes to the Session Tracker Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-05-19

### Added
- **daily-summary skill** — User-invocable; spawns the summarizer agent to generate a cross-project daily report
- **summarizer agent** — Claude Haiku sub-agent that finds all `.logs/YYYY-MM-DD-log.md` files in subdirectories, reads each, synthesizes a per-project summary, and writes the grouped report to `.logs/YYYY-MM-DD-daily-summary.md`

## [1.0.0] - 2026-05-19

### Added
- **end-session skill** — User-invocable; triggers on session-ending phrases and spawns the logger agent; does no context gathering itself
- **logger agent** — Claude Haiku sub-agent that works independently: invokes `query-changes` to gather git activity for the past 28 hours, synthesizes a summary, then invokes `save-log` to append the entry to `.logs/YYYY-MM-DD-log.md`
- **query-changes skill** — Internal; defines how the logger queries committed and uncommitted git changes for the 28-hour session window
- **save-log skill** — Internal; defines how the logger appends or creates the daily log file at `.logs/YYYY-MM-DD-log.md`
