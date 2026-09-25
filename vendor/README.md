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

## `basalt.lua` — Basalt 2 (single-file bundle)

| | |
|---|---|
| Upstream | https://github.com/Pyroxenium/Basalt2 |
| Pinned commit | `ba6c6911d2a317b452629faf77e55c7929857c73` |
| Licence | MIT — full text in `LICENSE-Basalt2` |
| Source | upstream's **published release artifact**, `release/basalt-full.lua`, at that commit |
| Size | 305,968 bytes |
| SHA256 | `4ce59622b7b4d5ec056a543859c91a080edd6cef5c64db8d9ddcfe0d0cf53859` |

Basalt 2 is a UI framework for CC:Tweaked. The **Full** variant is vendored, not
Core, because the reactive layout engine behind expressions such as
`"{parent.width - 2}"` is a *plugin*, and `config.lua` marks it `default = false`,
so a Core bundle would exclude it. The framework's own documentation calls Core
"recommended"; that is misleading for this project's needs, which is why Full is
used here.

This is the same artifact the reference project (MPlayer) installs, which is why
it is used here verbatim rather than rebuilt.

### Why it is bundled rather than shipped as separate files

Basalt's modules call `require("main")`, `require("elements.Frame")` and so on.
Those names only resolve if the directory holding them is on `package.path`.
Committing the 58 sources as loose files under `/lib/vendor/basalt/` would require
manipulating `package.path` at load time from a path this project does not control.
The bundle instead installs its own `require` shim at the top and resolves every
module from an in-memory table, which is self-contained and path-independent.

### Verifying or re-obtaining it

The file is the artifact upstream publishes, unmodified. To confirm it byte for
byte, or to fetch a fresh copy at the pinned commit:

```text
curl -L -o basalt.lua \
  https://raw.githubusercontent.com/Pyroxenium/Basalt2/ba6c6911d2a317b452629faf77e55c7929857c73/release/basalt-full.lua
sha256sum basalt.lua
# expected: 4ce59622b7b4d5ec056a543859c91a080edd6cef5c64db8d9ddcfe0d0cf53859
```

Because the pinned COMMIT is named rather than the branch, this URL is immutable
and the hash above stays valid. (The same file was also served from `main` when
this was fetched, but `main` moves, so the commit is what is recorded.)

Note on tooling: upstream's own `tools/bundler.lua` can rebuild a bundle from
`src/`, but an early draft of this directory did exactly that and the result was
**not** byte-identical — the module and stub declaration ORDER follows whatever
order the file listing comes back in, and upstream's bundler enumerates files with
`io.popen("find ...")`, which does not exist on Windows. The two bundles contained
the same 58 modules with the same bodies and the same total size, so either would
work, but the released artifact is preferred precisely because it removes that
local build step and every question that comes with it.

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
