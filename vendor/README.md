# vendor/ — bundled third-party code

This directory contains third-party source that is **committed to this repository**,
not fetched at runtime. It exists because the project's user interface is built on
Basalt 2, and Basalt's internals resolve their own modules through `require`, which
does not work when its sources are scattered across a directory that is not on
`package.path`. The upstream project solves this by bundling its sources into a
single self-contained file; this directory does the same.

**Everything here is GPL-2.0-compatible and is redistributed lawfully.** See
`NOTICE` in the repository root for the attribution that must accompany it.

---

## `basalt.lua` — Basalt 2 (single-file bundle), the *fork* build

| | |
|---|---|
| Upstream | https://github.com/HKXingluo/Basalt2 — a **fork** of https://github.com/Pyroxenium/Basalt2 |
| Pinned commit | `5adef1851b1aba4cd21f566f826a7f0194a24b42` |
| Licence | MIT — full text in `LICENSE-Basalt2` (the fork keeps the upstream licence) |
| Source | the fork's published `release/basalt-full.lua` at that commit |
| Size | 324,622 bytes |
| SHA256 | `5a273409fce6baaa89ae17d72332f4ad6e3c4232c3e3e426276cdbfa33a6d538` |

### WHY THE FORK AND NOT OFFICIAL BASALT 2 — this is the whole point

**Official Basalt 2 cannot render Chinese in its text elements.** A label or a
button only accepts plain text, which it draws through CC's `term.blit` using CC's
built-in font — and that font has no CJK glyphs. There is no font hook and no
per-element workaround: the text simply cannot contain Chinese.

The fork adds exactly that missing capability: `setImage()` on text elements, so a
label or button can display a **bimg** (the pixel-bitmap format) directly.

This is not a preference. It is why the reference project (MPlayer) is built on
the fork, and matching MPlayer was the requirement. The measured difference
between the two builds at the time of writing:

```text
official  305,968 B   sha 4ce59622...   occurrences of "setImage": 0
fork      324,622 B   sha 5a273409...   occurrences of "setImage": 5
```

The fork is a **superset**: the `Image` element and its `bimg` property are still
present (occurrences of `bimg` rise from 19 to 31), so code written against
official Basalt — including this project's own player view — keeps working.

The fork is MIT, inherited from upstream, so it is redistributable on the same
terms as the official build. Its author describes it as a proof of concept and
does not intend to upstream it; that is noted here so a future maintainer
understands why this is not simply "the latest Basalt release".

### Why it is bundled rather than shipped as separate files

Basalt's modules call `require("main")`, `require("elements.Frame")` and so on.
Those names only resolve if the directory holding them is on `package.path`.
Committing the sources as loose files under `/lib/vendor/basalt/` would require
manipulating `package.path` at load time from a path this project does not control.
The bundle instead installs its own `require` shim at the top and resolves every
module from an in-memory table, which is self-contained and path-independent.

### Verifying or re-obtaining it

The file is the artifact the fork publishes, unmodified. To confirm it byte for
byte, or to fetch a fresh copy at the pinned commit:

```text
curl -L -o basalt.lua \
  https://raw.githubusercontent.com/HKXingluo/Basalt2/5adef1851b1aba4cd21f566f826a7f0194a24b42/release/basalt-full.lua
sha256sum basalt.lua
# expected: 5a273409fce6baaa89ae17d72332f4ad6e3c4232c3e3e426276cdbfa33a6d538
```

Because the pinned COMMIT is named rather than the branch, this URL is immutable
and the hash above stays valid.

One check worth running after any change here, because it is the reason this
build was chosen: `grep -c setImage basalt.lua` must NOT be 0. A build with zero
`setImage` occurrences is official Basalt, and Chinese text in the interface will
silently fail to render.

Note on tooling, kept because it explains a decision: Basalt ships a
`tools/bundler.lua` that rebuilds a bundle from `src/`. An early draft of this
directory used it to rebuild the **official** bundle, and the result was not
byte-identical to official's published artifact — the module and stub declaration
ORDER follows whatever order the file listing comes back in, and that bundler
enumerates files with `io.popen("find ...")`, which does not exist on Windows.
Both contained the same 58 modules with the same bodies, so either would run, but
the published artifact wins precisely because it removes a local build step and
every question that comes with it. The fork is taken verbatim for the same reason;
nothing here is rebuilt locally.

`basalt.lua` is loaded with:

```lua
local basalt = dofile("vendor/basalt.lua")     -- or require("vendor.basalt")
```

It returns the `basalt` table. It may only be loaded inside CC:Tweaked /
CraftOS-PC: it touches `fs` during load and will raise in a plain Lua interpreter.

---

## `utf8display.lua` — CJK pixel-font renderer

| | |
|---|---|
| Upstream | https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8 |
| Licence | **none declared upstream** — see below |
| Purpose | draws CJK glyphs as bitmaps through `term.blit` |

A stock CC:Tweaked terminal has no CJK glyphs, so Chinese renders as garbage.
This library draws each character from a pixel font as a bitmap.

### Licence position — read this before redistributing

`ComputerCraft-Utf8` **declares no licence anywhere**: the repository has no
`LICENSE`, `COPYING` or `NOTICE` file, and `utf8display.lua` contains no licence
header, no copyright line and no SPDX identifier. Unlicensed source cannot
lawfully be redistributed on its own.

It is included here because of **provenance** rather than a licence file: the same
author (`xingluo` / HKXingluo) also publishes **MPlayer**, a GPL-2.0 CC:Tweaked
music player, and MPlayer *distributes this file as part of its own GPL-2.0 work*.
Receiving it from MPlayer therefore means receiving it from its own copyright
holder under GPL-2.0. That is the basis on which it is redistributed here, and it
is why `NOTICE` states this situation plainly instead of implying the file carries
a separate licence of its own.

If you are the author and want this handled differently, see `NOTICE`.

The renderer **executes fetched source through `load`** when it downloads a font.
See `ui/cjk.lua` for how this project constrains that.

---

## What is NOT vendored

The **font** is not committed. Both this project and MPlayer fetch the Fusion Pixel
CJK font at runtime instead, because the 8px font is 1,681,325 bytes — larger than
a default CC:Tweaked computer's entire disk limit of 1,000,000 bytes — so a user's
computer cannot hold both it and the program on a default server. `ui/cjk.lua`
attempts to cache it and tolerates the failure, which is why the font is fetched
once per launch on a default server. See the README for how to raise
`computer_space_limit` to enable caching.
