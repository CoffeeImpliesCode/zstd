<!--
SPDX-License-Identifier: BSD-3-Clause
See FORK-LICENSE.md for what that identifier covers.
-->

# Fixture provenance

Every fixture in this directory is a **recorded answer from a producer that is
not this package's own facade**. This file is what `tests.zig` cites when it
claims that a fixture has a producer: what ran, at what version, over what
input, and what the resulting bytes hash to.

`fixtures/SHA256SUMS` is the machine-readable form of the digests below, and
`tools/check-provenance.sh` re-derives every one of them.

There are three producers here and they are **not equally independent**, and
this file says which is which rather than letting "fixture" imply a uniform
strength:

1. **RFC 8878 itself** — hand-built frames whose expected plaintext follows from
   the specification, not from any implementation.
2. **The system `zstd` CLI v1.5.7** and **the `python-zstandard` 0.22.0
   binding** — two producers, but *one* implementation, as the byte-identity
   rows below show.
3. **The payload**, `plain.bin` — the single plaintext the produced frames all
   encode.

## The payload

| | |
|---|---|
| File | `plain.bin` |
| Size | 232 bytes |
| sha256 | `91c846cd95c7a1b7e40b73fdd0323f58ecebdd11a35cd855ae898368818fe071` |

Every `cli/*.zst` and `pyzstd/*.zst` file below decodes to exactly these bytes.
`plain.bin` is the single independent known answer those frames are checked
against: it is stored uncompressed in this repository, so a decoder that
returned the wrong bytes would fail against a file nobody has to trust a
compressor to produce.

## Producer 1 — the frames built from RFC 8878

| | |
|---|---|
| Producer | this repository, byte by byte from RFC 8878's normative text |
| Reference | <https://datatracker.ietf.org/doc/html/rfc8878> |
| Producers used | **none** — no encoder, CLI or library, contributed a byte |

These three pairs are the specification oracle. The magic number is §3.1.1, the
`Frame_Header_Descriptor` bit layout is §3.1.1.1.1 Table 3, the
`Window_Descriptor` rule is §3.1.1.1.2, the `Block_Header` layout is §3.1.1.2
Table 9, the `RLE_Block` rule is §3.1.1.2.2, and the skippable-frame layout is
§3.1.2. The expected plaintext is a consequence of those rules, not an output
someone observed.

| Frame | Plaintext | Frame size | sha256 | Plaintext sha256 |
|---|---|---:|---|---|
| `rfc8878/raw-block.zst` | `rfc8878/raw-block.plain` | 35 | `1dba13faa616a87820c1c3e1734fd5541dba7d32897b40d2f61fc8cab19266b0` | `35fe8574a44ca9c5044b5ec1272085430f4c157845176f377f0e3eb04e8627ae` |
| `rfc8878/rle-block.zst` | `rfc8878/rle-block.plain` | 10 | `4b182b9eb7e2e0a124e74d6a25d6971be616aeb4ad9f2cf3cdbc55748ea46de4` | `d64527abf8bbf8d23129cd790bba661f5cfa61b4a5661b30da2e821653575abb` |
| `rfc8878/skippable-plus-frame.zst` | `rfc8878/skippable-plus-frame.plain` | 88 | `c490075364c4e0156d1b22b42d0031f64b0ec16d7ce2bd5819ee35a211e52b8e` | `35fe8574a44ca9c5044b5ec1272085430f4c157845176f377f0e3eb04e8627ae` |

`rle-block.zst` is 10 bytes and expands to 200: that ratio is only possible
under §3.1.1.2.2, where an `RLE_Block` header of one byte followed by a
one-byte block size stands for that many identical bytes.

`skippable-plus-frame.zst` uses the magic number `0x184D2A53` — RFC 8878
§3.1.2's sixteen skippable magic numbers are `0x184D2A5?`, and this one is
`ZSTD_MAGIC_SKIPPABLE_START` plus 3 (`src/lib/zstd.h:144`) — and carries a
zstd frame after the skippable payload, so the file exercises both the
"skippable frame, skip it" path and the "real frame after it" path in one
input.

**`raw-block.plain` and `skippable-plus-frame.plain` have the same digest.** They
are the same 26 bytes of expected output; they are two files because they are
reachable through two different frame layouts, and collapsing them into one file
would hide which layout produced the answer.

## Producer 2 — the CLI and the Python binding

| | |
|---|---|
| CLI | `zstd` v1.5.7, 64-bit |
| CLI version record | `cli-version.txt`, 54 bytes, sha256 `f6d344e585f9a9ceb9500ff65355ce23bcc39dec9e4164aceab9da0a5ac3113e` |
| Binding | `python-zstandard` 0.22.0, linking libzstd (1, 5, 7) |
| Binding version record | `pyzstd/binding-version.txt`, 50 bytes, sha256 `cdbd9cc68a30cd801b8318c093fb1b294a8f40a3e42a609bc1c957edce9d9a85` |

The two version records are stored as the tools printed them, verbatim, so the
producers are identifiable from the tree without a second source.

| Frame | Producer and setting | Size | sha256 |
|---|---|---:|---|
| `cli/level-1.zst` | `zstd -1` | 136 | `0e9e833f3499d9df9e070bb72a5573e2ae00611c5169ba7688a2b654d9c5e7b1` |
| `cli/level-3.zst` | `zstd -3` | 136 | `cd37b9d78c30a42042d932c422f74451d822fdb317997c5ad7de3a9b368db402` |
| `cli/level-19.zst` | `zstd -19` | 133 | `2c0faf6df4e28495337b6431c1c2eb838a91c70493262791b5a4d1b670cbb33c` |
| `cli/ultra-22.zst` | `zstd --ultra -22` | 133 | `2c0faf6df4e28495337b6431c1c2eb838a91c70493262791b5a4d1b670cbb33c` |
| `cli/single-thread-3.zst` | `zstd -3 --single-thread` | 136 | `cd37b9d78c30a42042d932c422f74451d822fdb317997c5ad7de3a9b368db402` |
| `cli/no-check-3.zst` | `zstd -3 --no-check` | 132 | `1d1f2ab185d66adf0728b4d1569fe1a76856c28541d36cb615f8fb3d710aee1f` |
| `pyzstd/level-1.zst` | `zstd.ZstdCompressor(level=1)` | 136 | `0e9e833f3499d9df9e070bb72a5573e2ae00611c5169ba7688a2b654d9c5e7b1` |
| `pyzstd/level-3.zst` | `zstd.ZstdCompressor(level=3)` | 136 | `cd37b9d78c30a42042d932c422f74451d822fdb317997c5ad7de3a9b368db402` |
| `pyzstd/level-19.zst` | `zstd.ZstdCompressor(level=19)` | 133 | `2c0faf6df4e28495337b6431c1c2eb838a91c70493262791b5a4d1b670cbb33c` |
| `pyzstd/bare-3.zst` | `zstd.ZstdCompressor(level=3, write_checksum=False, write_content_size=False)` | 132 | `d1a126474d754a4c6a73e21a37abde6fb890d4cc3e7619e2eab8d19d5b774562` |

### What this set is, stated exactly

**These are one implementation behind two producers, not two independent
encoders.** Every digest in the CLI block also appears in the binding block at
the same level, and the table is arranged so that the duplication is visible
rather than something a reader has to notice:

* level 1 — `cli/level-1.zst` and `pyzstd/level-1.zst` share `0e9e833f…`
* level 3 — `cli/level-3.zst`, `cli/single-thread-3.zst` and
  `pyzstd/level-3.zst` share `cd37b9d7…`
* level 19 — `cli/level-19.zst`, `cli/ultra-22.zst` and
  `pyzstd/level-19.zst` share `2c0faf6d…`

The CLI is a front end over libzstd and `python-zstandard` binds libzstd
directly, so both producers are the same reference encoder. The binding's own
version line records this: `python-zstandard 0.22.0 binding libzstd (1, 5, 7)`.

That does not make the set useless, and it does not make it two independent
answers:

* it **is** a real interoperability claim in one direction — frames produced by
  a release of the reference encoder outside this build are decoded by this
  build's decoder, and must land on `plain.bin` byte for byte;
* the three *distinct* frames in the CLI block are distinct for real reasons,
  and each is a boundary rather than a duplicate. `ultra-22` is byte-identical
  to `level-19` because `--ultra -22` and `-19` reach the same match finder and
  the same entropy tables for a 232-byte input; `single-thread-3` is
  byte-identical to `level-3` because single-threaded mode cannot change the
  output of one frame this small; and `no-check-3` is four bytes shorter than
  `level-3` because `--no-check` drops the content checksum the other three
  carry — that four-byte difference is the `Content_Checksum` field, and it is
  what makes `no-check-3` a separate fixture rather than a copy.
* `pyzstd/bare-3.zst` is the only frame produced with both the checksum and the
  content size switched off, which is why it is 132 bytes and not 136.

**The claim this repository does not make** is that it decodes two independent
encoders' output. It does not, and `tests.zig` says so in the same words at
`tests.zig:55-61`, including why: a set of files that agreed only because two
programs happened to share an encoder would let a decoder regression hide behind
a coincidence. `tests.zig` asserts the byte-identity above **directly**, because
that is the fact which keeps the rest of the claim honest — if a future
regeneration made the two producers diverge, that test fails and the prose has
to change with it.

The genuine independence in this repository's oracle set comes from elsewhere:
the RFC 8878 frames above are built from the specification, and upstream's own
`src/tests/golden-decompression/` corpus is real output from other
implementations, embedded in place from the vendored source rather than copied
here.

## `fixtures/SHA256SUMS`

`fixtures/SHA256SUMS` records the digest of each of the **19 data files** in
this directory. It does not record its own digest, and it cannot.

An earlier revision of the manifest did try, with this as its line 1:

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  fixtures/SHA256SUMS
```

`e3b0c442…b855` is the SHA-256 of zero bytes. It is **not** the digest of that
file, and no digest could ever be: a manifest cannot contain its own digest,
because writing the digest into the file changes the file. The entry was
therefore unsatisfiable by construction, and `sha256sum -c fixtures/SHA256SUMS`
reported `FEHLSCHLAG` on it on every run, whatever the bytes were — a gate that
fails forever teaches a reader to ignore the gate.

**The entry has been removed, and the manifest's own digest moved to
`UPSTREAM.sha256`**, which is the one file in this repository that already
exists to record digests:

```
026f456061f5855a492f200555c45b3a88e7636820648d58fece0b844ec4fd5b  fixtures/SHA256SUMS
```

That is the digest of the manifest as it stands with 19 lines. `sha256sum -c
fixtures/SHA256SUMS` now verifies every entry it lists, and
`tools/check-provenance.sh` runs it with no exclusion and no special case —
because there is nothing left to exclude. A permanent carve-out for a line that
should not exist would be a second place for the fixture set to be wrong
quietly.

### The two records, and what covers each

| File | What it is | What checks it |
|---|---|---|
| `fixtures/SHA256SUMS` | the machine-readable digest list for the 19 data files | itself, via `UPSTREAM.sha256` line 1 |
| `fixtures/PROVENANCE.md` | this file: who produced each fixture and how | its existence, and that `tests.zig`, `smoke.zig` and `consumer/src/main.zig` still cite it |

`tools/check-provenance.sh` names both of them in its fixture-file-set
comparison rather than filtering them silently, so a reader can see exactly
which two files the manifest is not expected to list and why.

## What is deliberately not here

* **No frame produced by this package's own `compress`.** A frame this build
  made and this build read back is a round trip. `tests.zig` and
  `smoke.zig` both do that, and both do it as a *supplement* to the oracles
  above, never as the interoperation claim.
* **No copy of upstream's golden corpus.** `src/tests/golden-decompression/` is
  already in this repository as upstream shipped it, and `tests.zig` embeds
  those files in place. Copying them into `fixtures/` would create a second
  copy that could drift from the first, and would break the record that
  upstream's suite is used unmodified.
* **No hex literal of a compressed frame in a source file.** Every frame is
  `@embedFile`d, so a frame is a diffable file rather than an unreadable string
  constant.

## Re-deriving these fixtures

Each row above names the exact producer and setting. To regenerate one, run
that producer at that version over the 232 bytes of `plain.bin`, and compare
the new digest with the table and with `fixtures/SHA256SUMS`. A digest that
changes is a fact to investigate — a different libzstd behind either producer,
a different CLI build, a different binding version — and never something to
re-record to make a gate pass. An intentional change needs the new producer
named here, the new digest in both this file and `fixtures/SHA256SUMS`, and a
numbered `CHANGELOG.md` entry in the same change.

`STATUS`: `SOURCE-CONFIRMED` for every digest, size, version string and
producer setting in this file. Each was computed or read out of the bytes in
this directory. No producer was run to produce any of them and no gate was run,
so nothing here is a verification result; the observed runs are recorded in
[`README.md`](../README.md) and are marked `PENDING-VERIFICATION` until the
driver observes them.