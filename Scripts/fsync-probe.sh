#!/bin/sh
# Shows which flush calls Relay's real save path makes. Builds RelayBench, runs its
# quick save workload with a flush-counting interposer, and prints the counts.
# Writes only to a temporary directory. See ARCHITECTURE.md → Durability.
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d -t RelayBench-probe)"
trap 'rm -rf "$work"' EXIT
swift build -c release --package-path Packages/RelayCore --product RelayBench >/dev/null
clang -O2 -dynamiclib Scripts/fsync-probe/interpose.c -o "$work/libfsyncprobe.dylib"
echo "SQLite library: $(sqlite3 --version 2>/dev/null | cut -d' ' -f1 || echo unknown)"
DYLD_INSERT_LIBRARIES="$work/libfsyncprobe.dylib" \
    Packages/RelayCore/.build/release/RelayBench --quick --only save --output "$work" 2>&1 \
    | grep -E "fsync-probe|^\| save-latency"
echo "Commits in this run: 1,000 template inserts + 2 x 210 edits, plus setup."
