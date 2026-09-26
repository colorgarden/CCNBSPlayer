# AGENTS.md — CCNBSPlayer agent instructions

**This file is binding for every agent session in this repository.** It exists
because the same failure recurred across sessions: an agent was asked to follow
a reference implementation and instead invented its own, then had to be
corrected. Read this before planning anything.

---

## 1. THE PRIME DIRECTIVE: READ THE REFERENCE BEFORE YOU DESIGN

When the user says **"照抄 MPlayer"** (copy MPlayer), or anything equivalent, they
mean **read MPlayer's source and reproduce it**. They do not mean "build
something inspired by it".

The reference implementation is readable source, not a compressed blob:

```
https://git.liulikeji.cn/xingluo/MPlayer
  branch: master
  src/startup.lua          9,545 lines, ~34 bytes/line — READABLE. Read it.
  src/Api/MusicApi.lua     the client pattern (async + token + retry)
  src/Api/ImeApi.lua       the pinyin input client
  src/Lib/Player.lua       the player library
  src/Settings.lua         settings persistence + the settings projects
  src/icons/*.lua          35 bimg icons (vendored here already)
  src/install.lua          the GUI installer (the model for installer.lua)
  release/install_list.lua the install manifest + the third-party URLs
```

**Fetch it before planning.** Examples of the cost of not doing so, all real:

* Claimed the installer "followed MPlayer" without ever reading it. It did not:
  MPlayer's is a Basalt GUI with a progress bar and a button state machine.
* Did not notice MPlayer opens with a `package`/`shell` shim. Without it the
  vendored Basalt cannot load at all, so the GUI never appeared and the failure
  was swallowed.
* Vendored the OFFICIAL Basalt instead of the fork MPlayer uses. The official
  build cannot render Chinese in text elements, so the whole Chinese UI was built
  on a framework that cannot do the job.

**Rule: before writing a line that reproduces MPlayer behaviour, `curl` the
relevant MPlayer file and read it.** It takes one call and prevents all of the
above.

---

## 2. Confirm facts from the SOURCE or a PROBE — never from an API field or memory

Measured examples of trusting the wrong thing:

| Trusted | Reality |
|---|---|
| Gitea `license` API field said `None` | The repo's LICENSE file was GPL-2.0, 17,337 bytes |
| `tostring(a_table):find("write")` | Can never match; reported a false failure |
| A grep count of `setImage` = 0 | The name is generated at runtime, not absent |
| `git check-ignore` on `agent/` | Ignored and would have made `installer.lua` unshippable |
| raw CDN after a push | Served the OLD file for ~5 min (`max-age=300`); git held the new one |

**Rule: read the file, run the probe, or compare a hash. Then state the method.**

---

## 3. PROJECT CONSTRAINTS (hard, checked by the gate)

* **THE DISK LIMIT IS A DESIGN CONSTRAINT, NOT A DETAIL.** A default CC:Tweaked
  computer holds **1,000,000 bytes**. This project's sources measured
  **1,123,336 B** installed — 123 KB OVER, so the install did not merely waste
  space, it **could not fit**. The reference implementation had already solved
  this and the lesson was recorded in its `release/` artifacts, not its docs:
  1. it **minifies** what it ships (9,545 lines of source become a 232 KB bundle),
     and
  2. it **does not install its own installer**.
  This project now does both. `installer.shrink_for_install` strips comments from
  OUR OWN Lua as it is written (measured 1,128,115 → 777,036 B) and **never
  touches `vendor/**`**, whose comments carry upstream attribution. The install
  now costs ~720 KB, leaving ~280 KB for the user's songs.
  **Before adding a module, measure the install. Any change that pushes it past
  1,000,000 B ships something that cannot be installed.**
* **Language subset** — CC:Tweaked Cobalt, Lua 5.2 base. FORBIDDEN in our code:
  `//`, bitwise operators, `math.maxinteger`, `collectgarbage`, `string.dump`,
  `os.exit`, `goto`. `lua tests/lint.lua` must exit 0.
  NOTE: lint does **not** check `utf8.*` — that is a convention, enforced by
  review, and it exists because the desktop interpreter (stock Lua 5.2.4) lacks
  `utf8`.
* **Licence: GPL-2.0.** Third-party code is vendored under `vendor/` with
  attribution in `NOTICE`. Never vendor anything whose licence is unknown without
  saying so in `NOTICE`. Never write a claim into `NOTICE`/`README` that the code
  no longer satisfies — that happened twice and had to be corrected.
* **`tests/` is NOT published** (`.gitignore`). The suite protects the local
  developer only. If a guarantee must hold on GitHub, it cannot live only in
  `tests/`.
* **Install root is `/lib`**, and the manifest is the single source of truth for
  what ships. Keep `installer.manifest`, `installer.RUNTIME_FILES` and
  `EXPECTED_FILES` in `tests/installer_spec.lua` IDENTICAL in content and order.
* **The drift guard has known blind spots.** It scans literal
  `require("...")`/`pcall(require, "...")`, so it has already missed:
  1. a require through a VARIABLE,
  2. a BARE root-level require,
  3. **data assets read by path** (e.g. `vendor/mplayer-icons/*.lua`) — nothing
     requires them, so a missing entry ships a broken program silently.
  When you add a module or an asset, add it to all three lists BY HAND and say so.

---

## 4. WORKING PROTOCOL (the user asked for this to persist)

0. **DO NOT COMMIT ANYTHING — not locally, not to a remote.**
   The user forbade it explicitly, in two steps: first "不许提交到远程仓库"
   (do not push), then "本地也不行" (local commits are not allowed either).
   So: **no `git add` + `git commit`, no `git push`, no `git tag`, no stash
   housekeeping** — leave every change in the working tree for the user to review
   and commit themselves.
   Do not treat an uncommitted tree as a problem to fix, and do not suggest
   committing. Only commit if the user explicitly asks for it, and then only what
   they name.
   (This supersedes the earlier instruction in this project, where pushes and
   local commits WERE requested. Do not carry that assumption forward.)
1. **Plan agent for anything 2+ steps.** Non-negotiable. It returns a task graph
   with waves; execute in that order.
2. **TDD, always.** Write the failing test FIRST, run it, capture the assertion
   message proving it fails for the RIGHT reason. Then the smallest change that
   turns it GREEN. Production code before its failing test = revert and redo.
3. **Delegate.** Parallelise independent work across agents; one module per lane;
   never let two lanes touch the same file.
4. **Evidence, not assertion.** "Tests pass" is the floor, not the ceiling.
   Capture the literal command output, and for anything user-visible capture the
   real surface (the emulator, the rendered screen, the HTTP response).
5. **Mutation-test your own tests.** Break the implementation deliberately and
   confirm the test FAILS. A test that cannot fail proves nothing — this caught a
   spec whose driver silently recorded nothing after the first test.
6. **Verify the PUBLISHED state, not just the local tree.** A green local suite
   proved nothing when the published manifest 404'd. After pushing, probe the live
   URLs; allow for the CDN's 5-minute cache and re-probe rather than concluding.
7. **Correct yourself in the record.** When a claim in `NOTICE`, a doc or a
   ledger entry turns out false, fix the text — do not leave it standing.

---

## 5. ARCHITECTURE DECISIONS ALREADY MADE (do not relitigate)

* **UI framework = HKXingluo's BASALT FORK**, not official Basalt. Vendored at
  `vendor/basalt.lua` (324,622 B, pinned commit `5adef1851b1aba4cd21f566f826a7f0194a24b42`).
  The fork adds `setImage()` to text elements, which is the ONLY way to render
  Chinese in a label or button. Official Basalt has zero `setImage` occurrences.
  Checklist when touching it: `grep -c setImage vendor/basalt.lua` must NOT be 0.
* **Chinese rendering** = `utf8display` (vendored) + a runtime-fetched CJK font
  (`ui/cjk.lua`). The font is NOT vendored: 1.68 MB against a default 1 MB disk
  limit. Failure to get the font must degrade to English, never to garbage.
* **The installer** is a Basalt GUI (see `installer.lua` + `ui/installer_app.lua`)
  modelled on MPlayer's `src/install.lua`: bootstrap shim, source choice,
  async download with a progress bar, then write. It must NEVER overwrite a
  foreign `/startup.lua` — autostart is ours only, identified by a marker line.
* **The main program UI is a full replica of MPlayer's**, monitor-based
  (`setTextScale(0.5)`), with a display-selection page when no monitor exists.
  The user explicitly chose this over a 51×19 computer-screen layout.
* **Reuse our own layers where they are already better.** Do NOT port MPlayer's
  `ImeApi.lua` (166 lines of request/retry plumbing): `net/http.lua` already
  provides retry with backoff, timeouts, bounded reads and a never-raise
  contract. Write thin modules on top of it. Same for JSON — use
  `textutils.serializeJSON`/`unserializeJSON` through an injectable seam, as
  `net/nbw.lua` does.
* **Remote keyboard** (`xingluo/cct-keyboard`): the user chose UNCONDITIONAL
  install + autostart, accepting the risk. That risk is real and must be
  documented, not hidden: `Keyboard_server.lua` injects ANY rednet message whose
  protocol matches straight into the local event queue, i.e. anyone on the same
  rednet can type into the machine. It is NOT vendored — the installer fetches it
  from upstream at install time, exactly as MPlayer does, which also avoids
  redistributing a repository that declares no licence.
* **The IME endpoint is a DEFAULT, not a constant** (the user corrected this).
  MPlayer reads it from its settings layer and only falls back to
  `http://rime.liulikeji.cn/query`. Expose it as configurable, with that address
  as the documented default.

---

## 6. HOW TO RUN THINGS

```text
lua tests/run.lua           # full suite
lua tests/lint.lua          # the Cobalt-subset gate; must print "lint: OK"
lua tests/run.lua tests/ui/foo_spec.lua   # one spec
```

The emulator (for anything that must be proven on the real target):

```text
D:\tools\CraftOS-PC\CraftOS-PC_console.exe --headless -d <data-dir>
```

Files handed to it MUST be written **without a BOM** — PowerShell's
`Set-Content -Encoding UTF8` adds one and CC's Lua rejects it with
"Unexpected character". Write with Python in binary mode instead.

The user's real test rig: a Minecraft instance at
`D:\Release 2.7.3\.minecraft\versions\1.21.1-NeoForge_21.1.251`, whose
`config\computercraft-server.toml` carries a `198.18.0.0/15` allow rule placed
BEFORE `$private` (the proxy resolves every domain into that range, which
CC:Tweaked otherwise treats as private and refuses).
