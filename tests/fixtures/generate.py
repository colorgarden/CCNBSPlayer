#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Deterministic generator for the synthetic NBS v1..v5 fixtures.

Why this file exists
--------------------
The NBS format versions 1, 2, 3, 4 and 5 are not published as downloadable
sample files anywhere (the upstream ``OpenNBS/pynbs`` and ``OpenNBS/nbs.js``
repositories ship v0 and v6 samples only).  To pin the byte layout of every
version 0..6 we therefore synthesise the missing ones with pynbs, whose writer
implements the same version-gated field layout that the decoder under test
implements independently.  The generator mirrors the exact pattern used by
pynbs's own test suite so the fixtures stay faithful to upstream behaviour.

Interpreter used to produce the committed files
-----------------------------------------------
    C:\\Program Files\\Python311\\python.exe   (pynbs 1.0.0-beta.0)

Regenerate (from the repository root):

    python tests/fixtures/generate.py

The output is deterministic: same pynbs version -> byte-identical files.
Every generated file is committed; the spec never runs this script.

The ONE deliberate post-processing step
---------------------------------------
``File.save(path, version=N)`` calls ``File.update_header``, which stores
``song_length = notes[-1].tick`` -- the LAST TICK INDEX, one less than the true
tick count (``max_tick + 1``).  The decoder under test decides which length to
trust with a "reconstruct-if-shorter" rule:

    notes-derived length > stored header length  ->  source "notes"
    otherwise                                    ->  source "header"

With the stock off-by-one value, EVERY non-empty v3+ song (generated or real,
including the upstream samples) lands in the "notes" branch, so the v3
requirement "the stored song_length exists again and is authoritative"
(``song_length_source == "header"``) could never be exercised.  We therefore
rewrite the two stored ``song_length`` bytes for v3+ to the true tick count.
The rest of the file is byte-for-byte what pynbs wrote.  See
tests/fixtures/README.md and the evidence file for the full rationale.
"""

import os
import struct

import pynbs

FIXTURES_DIR = os.path.dirname(os.path.abspath(__file__))

# Tick list used by pynbs' own test suite for its minimal song.
TICKS = (0, 2, 4, 6, 8)


def build(version):
    """Return the pynbs File used for a given target format version."""
    song = pynbs.new_file(song_name="ccnbs v%d" % version, song_author="ccnbs")
    song.notes.extend(
        [pynbs.Note(tick=t, layer=0, instrument=0, key=45) for t in TICKS]
    )
    return song


def store_authoritative_length(path, length):
    """Patch the v3+ stored i16 song_length to the true tick count.

    New-format header layout written by pynbs:
        [0:2]  i16  zero sentinel (marks the new format)
        [2]    u8   format version
        [3]    u8   vanilla_instrument_count
        [4:6]  i16  song_length        <- only present when version >= 3
    """
    with open(path, "rb") as handle:
        data = bytearray(handle.read())
    data[4:6] = struct.pack("<h", length)
    with open(path, "wb") as handle:
        handle.write(bytes(data))


def main():
    true_length = TICKS[-1] + 1

    for version in range(1, 6):
        path = os.path.join(FIXTURES_DIR, "v%d.nbs" % version)
        build(version).save(path, version=version)

        # v1/v2 store no length; v3+ get the authoritative tick count.
        if version >= 3:
            store_authoritative_length(path, true_length)

        # Read the bytes straight back so the log shows what was written and
        # the size check catches an accidental empty/placeholder file.
        size = os.path.getsize(path)
        reloaded = pynbs.read(path)
        print(
            "wrote %-10s bytes=%-4d version=%d header_length=%s notes=%d layers=%d"
            % (
                os.path.basename(path),
                size,
                reloaded.header.version,
                reloaded.header.song_length,
                len(reloaded.notes),
                len(reloaded.layers),
            )
        )


if __name__ == "__main__":
    main()
