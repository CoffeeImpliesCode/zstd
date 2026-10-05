#!/usr/bin/env bash
# Source-integrity check for the Zstandard SDK.
#
# Four questions, all answerable without a compiler:
#
#   1. Do the 637 upstream files, and the fixture manifest's own digest, still
#      hash to what UPSTREAM.sha256 records?
#   2. Is the native file set exactly that set -- no missing, extra or renamed
#      file under src/?  A plain checksum run cannot see an addition.
#   3. Do the 19 data entries of fixtures/SHA256SUMS still hold?
#   4. Are the preserved upstream README and both of Zstandard's two licence
#      texts still where the records say they are, and is the pinned version
#      still what the imported header states?
#
# This is a provenance gate, not a build gate. Nothing here compiles, links or
# runs a target binary; it is the check that an edit to the canonical native
# source cannot pass as a routine change.
#
# Usage: tools/check-provenance.sh   (run from anywhere in the repository)
#
# SPDX-License-Identifier: BSD-3-Clause
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# per-file inventory of the upstream material this package ships.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

# 1. Bytes. `--quiet` prints only the lines that failed, and with `pipefail` in
#    force there is no `head` in this pipeline to turn a success into a
#    SIGPIPE.
sha256sum -c --quiet UPSTREAM.sha256 || fail "an upstream file no longer matches UPSTREAM.sha256"
echo "all 638 recorded files match UPSTREAM.sha256"

# 2. File set. UPSTREAM.sha256 is the complete record of src/, so comparing the
#    two listings catches an addition as well as a deletion, which a checksum
#    run alone cannot do.
expected_tree=$(awk '/^[0-9a-f]{64}  / { print $2 }' UPSTREAM.sha256 | grep -E '^src/' | LC_ALL=C sort)
actual_tree=$(find src -type f | LC_ALL=C sort)
if [ "$expected_tree" != "$actual_tree" ]; then
    echo "the native file set differs from the recorded one:" >&2
    diff -u <(echo "$expected_tree") <(echo "$actual_tree") >&2 || true
    echo >&2
    echo "An intentional change to the native source needs an observed failure, a" >&2
    echo "small causal patch, an explicit per-file deviation record in NOTICE.md," >&2
    echo "updated digests here, and a CHANGELOG.md entry in the same change." >&2
    exit 1
fi
echo "the native file set is exactly the recorded 637 files"

# 3. The fixture set.
#
#    fixtures/SHA256SUMS records the 19 data files under fixtures/ and nothing
#    else. It does **not** record its own digest: a manifest cannot contain its
#    own digest, because writing the digest into the file changes the file. An
#    earlier revision of this manifest did try, with `e3b0c442...b855` -- the
#    SHA-256 of zero bytes -- in place of its real digest, which made
#    `sha256sum -c fixtures/SHA256SUMS` fail on that line forever. The entry was
#    removed and the manifest's own digest moved to UPSTREAM.sha256, where a
#    manifest's digest belongs. There is no exclusion here because there is
#    nothing left to exclude.
sha256sum -c --quiet fixtures/SHA256SUMS ||
    fail "a fixture no longer matches fixtures/SHA256SUMS"

# The manifest and the directory are compared, not just the digests: a file
# added under fixtures/ with no manifest line would otherwise pass a digest
# check silently, because a file nothing lists is a file nothing checks.
#
# Two files in the directory are records rather than fixtures and are named
# here rather than filtered silently:
#   fixtures/SHA256SUMS   this check's own input; its digest is the first line
#                         of UPSTREAM.sha256 and is verified in step 1 above.
#   fixtures/PROVENANCE.md  the prose record of who produced each fixture. It is
#                         checked for existence and for being cited below; it is
#                         prose, not data, so no digest belongs beside the frames.
expected_fixtures=$(awk '/^[0-9a-f]{64}  / { print $2 }' fixtures/SHA256SUMS | LC_ALL=C sort)
actual_fixtures=$(find fixtures -type f ! -name SHA256SUMS ! -name PROVENANCE.md | LC_ALL=C sort)
if [ "$expected_fixtures" != "$actual_fixtures" ]; then
    echo "the fixture file set differs from the one fixtures/SHA256SUMS records:" >&2
    diff -u <(echo "$expected_fixtures") <(echo "$actual_fixtures") >&2 || true
    echo >&2
    echo "A fixture added, removed or renamed without a manifest line is a change to" >&2
    echo "the oracle, not a bookkeeping detail. Add the line and the PROVENANCE.md row," >&2
    echo "and a CHANGELOG.md entry, in the same change." >&2
    exit 1
fi
echo "the 19 fixture files are exactly the ones fixtures/SHA256SUMS records"

# The producer version strings. `tests.zig:55-61`, `smoke.zig` and
# `consumer/src/main.zig` all rest an interoperability claim on these two lines:
# which CLI release and which binding produced the frames. A rewritten record
# would make those claims silently false.
[ "$(tr -d '\n' < fixtures/cli-version.txt)" = \
    '*** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***' ] ||
    fail "fixtures/cli-version.txt no longer records zstd CLI v1.5.7"
[ "$(tr -d '\n' < fixtures/pyzstd/binding-version.txt)" = \
    'python-zstandard 0.22.0 binding libzstd (1, 5, 7)' ] ||
    fail "fixtures/pyzstd/binding-version.txt no longer records python-zstandard 0.22.0 over libzstd 1.5.7"
echo "both producer version records are intact"

# The byte-identity the fixture prose depends on. tests.zig asserts the same
# three pairs at runtime; this asserts it on the stored bytes, so a regeneration
# that made the CLI and the binding diverge is caught even before a gate runs.
for pair in \
    '0e9e833f3499d9df9e070bb72a5573e2ae00611c5169ba7688a2b654d9c5e7b1:fixtures/cli/level-1.zst:fixtures/pyzstd/level-1.zst' \
    'cd37b9d78c30a42042d932c422f74451d822fdb317997c5ad7de3a9b368db402:fixtures/cli/level-3.zst:fixtures/pyzstd/level-3.zst' \
    '2c0faf6df4e28495337b6431c1c2eb838a91c70493262791b5a4d1b670cbb33c:fixtures/cli/level-19.zst:fixtures/pyzstd/level-19.zst' \
; do
    digest=${pair%%:*}
    rest=${pair#*:}
    left=${rest%%:*}
    right=${rest#*:}
    [ "$(sha256sum "$left" | cut -d' ' -f1)" = "$digest" ] ||
        fail "$left no longer hashes to $digest"
    [ "$(sha256sum "$right" | cut -d' ' -f1)" = "$digest" ] ||
        fail "$right no longer hashes to $digest"
done
echo "the CLI and the binding frames are still byte-identical at levels 1, 3 and 19"

# 4a. The import must be recorded identically in both records, so the two files
#     cannot disagree about which upstream release this is. What is recorded
#     here is an aggregate of the *imported file set*, not the tarball's
#     published digest: no tarball was ever held in this repository, and
#     UPSTREAM.md, "Canonical source", says so rather than filling the gap with
#     a number nobody here can compute.
expected_count=$(awk '/^[0-9a-f]{64}  / { n++ } END { print n + 0 }' UPSTREAM.sha256)
[ "$expected_count" = "638" ] ||
    fail "UPSTREAM.sha256 records $expected_count files, and the rest of this script checks 638"

# The aggregate is *derived*, not asserted: it is the sha256 of the file's own
# digest column, in file order. It changes if any entry is added, removed,
# reordered or edited, and anyone holding UPSTREAM.sha256 can recompute it.
recorded_aggregate=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.md || true)
actual_aggregate=$(awk '/^[0-9a-f]{64}  / { print $1 }' UPSTREAM.sha256 | sha256sum | cut -d' ' -f1)
[ -n "$recorded_aggregate" ] ||
    fail "UPSTREAM.md records no sha256 aggregate of UPSTREAM.sha256"
[ "$recorded_aggregate" = "$actual_aggregate" ] ||
    fail "UPSTREAM.md records $recorded_aggregate but UPSTREAM.sha256 aggregates to $actual_aggregate"
echo "the 637-entry import aggregate is recorded consistently: $recorded_aggregate"

# 4b. The preserved upstream README. README.upstream.md is the exact bytes of
#     the tarball's README.md; the copy in the source tree is the imported
#     original.
cmp -s src/README.md README.upstream.md ||
    fail "src/README.md and README.upstream.md are no longer byte-identical"
echo "README.upstream.md is byte-identical to the imported upstream README"

# 4c. BOTH of Zstandard's grants, in the two files that carry them and in the
#     records. Upstream's grant is "You may select, at your option, one of the
#     above-listed licenses" (src/lib/libzstd.mk:8), following "This source code
#     is licensed under both the BSD-style license ... and the GPLv2"
#     (src/lib/libzstd.mk:5-6), so a package that installed one text and dropped
#     the other would have narrowed it rather than reported it.
#
# The matcher quotes that sentence as upstream writes it. It previously looked
# for "either, at your option, one of the above-listed licenses", a wording that
# is in no upstream file, so the check failed on vendored bytes whose 638
# digests had just been verified against UPSTREAM.sha256.
grep -q 'Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.' src/LICENSE ||
    fail "the upstream BSD copyright notice is missing from src/LICENSE"
grep -q 'Redistribution and use in source and binary forms' src/LICENSE ||
    fail "src/LICENSE no longer carries the BSD permission text"
grep -q 'GNU GENERAL PUBLIC LICENSE' src/COPYING ||
    fail "src/COPYING no longer carries the GPLv2 text"
grep -q 'Version 2, June 1991' src/COPYING ||
    fail "src/COPYING no longer carries the GPLv2 version and date"
grep -q 'You may select, at your option, one of the above-listed licenses' src/lib/libzstd.mk ||
    fail "src/lib/libzstd.mk no longer states the dual grant"
for file in NOTICE.md README.md FORK-LICENSE.md; do
    grep -q 'Meta Platforms, Inc.' "$file" ||
        fail "the upstream BSD copyright notice is missing from $file"
done
echo "both upstream grants, and the dual-licence statement, are present"

# 4d. The version the package claims, against the three numbers the imported
#     header states. A manifest that drifted from the source it describes would
#     make build.zig.zon, zstd.pc and the shared object's file name describe
#     three different releases.
grep -q '^    .version = "1.5.7",' build.zig.zon ||
    fail "build.zig.zon no longer records .version = 1.5.7"
# Upstream aligns the three values in a column at src/lib/zstd.h:112-114
# ("#define ZSTD_VERSION_MAJOR    1"), so the separator is matched as a run of
# blanks rather than one space. A single-space matcher found no line in a file
# whose 638 digests had just been verified.
grep -qE '^#define ZSTD_VERSION_MAJOR +1$' src/lib/zstd.h ||
    fail "src/lib/zstd.h no longer defines ZSTD_VERSION_MAJOR 1"
grep -qE '^#define ZSTD_VERSION_MINOR +5$' src/lib/zstd.h ||
    fail "src/lib/zstd.h no longer defines ZSTD_VERSION_MINOR 5"
grep -qE '^#define ZSTD_VERSION_RELEASE +7$' src/lib/zstd.h ||
    fail "src/lib/zstd.h no longer defines ZSTD_VERSION_RELEASE 7"
echo "the pinned version is recorded consistently: 1.5.7"

# 4e. build.zig.zon .paths is the package's file filter, and the one rule that
#     governs it is that every path it names must exist: `zig fetch` hashes the
#     named paths, so naming a path that is absent fails the fetch rather than
#     recording an absence. This reads the names out of the manifest rather than
#     from a list written here, so the check cannot fall out of step with the
#     manifest it is checking, and it runs in both directions: a named path that
#     is missing, and a lock file that now exists but is not named.
declared_paths=$(sed -n '/^    .paths = .{/,/^    },/p' build.zig.zon |
    sed -n 's/^        "\(.*\)",$/\1/p')
[ -n "$declared_paths" ] || fail "no .paths entries were read out of build.zig.zon"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] ||
        fail "build.zig.zon .paths names $path, and it does not exist"
done <<< "$declared_paths"
echo "all $(printf '%s\n' "$declared_paths" | grep -c .) paths build.zig.zon .paths names exist"

# The two lock files belong to the driver, and .paths deliberately names
# neither while both are absent. This says so out loud rather than leaving the
# omission to be read as an oversight, and it is the check that keeps the
# manifest honest when the driver does write one: a lock that exists and is not
# named would otherwise ship an unlocked tree.
for lock in flake.lock devenv.lock; do
    if [ -e "$lock" ]; then
        printf '%s\n' "$declared_paths" | grep -qx "$lock" ||
            fail "$lock now exists, so build.zig.zon .paths must name it in the same change"
    fi
done
echo "neither lock file exists, and .paths names neither"

# 4f. The fixture provenance record is cited by tests.zig and smoke.zig as the
#     record that gives each fixture a producer; a deletion would leave those
#     citations dangling and the fixture set unaudited.
for file in tests.zig smoke.zig consumer/src/main.zig; do
    grep -q 'fixtures/PROVENANCE.md' "$file" ||
        fail "$file cites fixtures/PROVENANCE.md but no longer does"
done
[ -f fixtures/PROVENANCE.md ] || fail "fixtures/PROVENANCE.md is missing"
echo "fixtures/PROVENANCE.md is present and is cited by tests.zig, smoke.zig and consumer/src/main.zig"

echo "provenance checks passed"