#!/bin/sh
# Builds RelayBench in release and runs every workload. Results are written to
# benchmark-results/ (JSON) and summarized on stdout. Extra arguments are passed to
# RelayBench (for example --quick, or --only save,search). See BENCHMARKS.md.
#
# Safe to run: uses only temporary databases with synthetic notes, never the app's
# database, and never CloudKit. Git is only read (revision and dirty-file count).
set -eu
cd "$(dirname "$0")/.."
swift build -c release --package-path Packages/RelayCore --product RelayBench
RELAY_BENCH_SWIFT="$(swift --version 2>&1 | grep -m1 'Swift version')"
RELAY_BENCH_XCODE="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo unknown)"
RELAY_BENCH_GIT_REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
RELAY_BENCH_GIT_DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
RELAY_BENCH_POWER="$(pmset -g batt 2>/dev/null | head -1 | sed "s/.*'\(.*\)'.*/\1/" || echo unknown)"
export RELAY_BENCH_SWIFT RELAY_BENCH_XCODE RELAY_BENCH_GIT_REVISION RELAY_BENCH_GIT_DIRTY RELAY_BENCH_POWER
exec Packages/RelayCore/.build/release/RelayBench --output benchmark-results "$@"
