# MPlayer UI replica — the measured specification

This file records **what was measured from the reference implementation**, so the
screens in `ui/screens/` can be checked against a fact rather than a memory. It
is the document `AGENTS.md` refers to when it says the reference must be read
before anything is designed.

The reference is MPlayer:

```
https://git.liulikeji.cn/xingluo/MPlayer    branch: master
  src/startup.lua      9,545 lines, 337,130 bytes, ~34 bytes/line — READABLE
  src/Settings.lua     the settings store and its 5 API projects
  src/Api/ImeApi.lua   the pinyin client
  src/icons/*.lua      35 bimg icons (vendored into vendor/mplayer-icons/)
```

Every coordinate below was read out of `src/startup.lua` at the line given.
`ui/screens/frame.lua` and `ui/app_shell.lua` carry the same numbers as named
constants, so a reader can diff the two.

---

## 1. Startup order

| Step | Reference | Line |
|---|---|---|
| Root frame | `ComputerFrame = Basalt.getMainFrame()` then `:setBackground(colors.black)` | 952 |
| Monitor lookup | `Settings.loadDisplay()` → `DisplayName`; matched against `GetAvailableDisplayMonitors()` | 956 |
| No monitor | `CreateDisplaySelectionPage(DisplayMonitors)` then `Basalt.run()` — **nothing else starts** | 968 |
| Text scale | `Monitor.setTextScale(0.5)` | 973 |
| Palette | seven `Monitor.setPaletteColor` calls | 975–982 |
| Monitor frame | `MonitorFrame = Basalt.createFrame(); MonitorFrame.term = Monitor` | 985 |
| Main frame | `Main_Frame = MonitorFrame:addFrame{x=1,y=1,width="{parent.width}",height="{parent.height}"}` | 992 |
| Console | `ComputerFrame:openConsole()` (a log pane) | 989 |

The `0.5` text scale is what makes the multi-section layout fit a monitor at all,
which is why this project also requires a monitor rather than shrinking to a 51×19
computer screen.

### The seven palette colours

| Slot | Value | Slot | Value |
|---|---|---|---|
| `black` | `0x101014` | `magenta` | `0x695E61` |
| `gray` | `0x18181C` | `pink` | `0x3A3438` |
| `lightGray` | `0x222226` | `purple` | `0xFFDAD6` |
| `orange` | `0x2C2C32` | | |

`frame.apply_palette` applies exactly these seven, in this order, so the count is
deterministic.

### The standard content frame

`CreateNavigationPage(title)` (line 1001) gives every page the same geometry:

```
x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-6-4}"
```

The `19` clears the 17-wide sidebar plus a margin; the trailing `4` leaves room
for the top bar and the playback bar.

---

## 2. Sidebar — `Navigation` (lines 3055–3165)

```
Navigation = Main_Frame:addFrame{ x=1, y=1, width=17, height="{parent.height}",
                                  background=colors.gray }
```

| Widget | y | Notes |
|---|---|---|
| brand label | 1 | height 3, width 16, `purple` on `gray` |
| 推荐 (Home) | 5 | `icons.Home` + label, 16×3 |
| 发现 (Discover) | 8 | `icons.Discover` |
| 漫游 (Roaming) | 11 | `icons.Roaming`; hidden while logged out, and the rows below shift up by 3 |
| 播客 (Podcast) | 14 | `icons.Podcast` |
| main divider | 17 | 16×3 label |
| 喜欢 (LikeSongs) | 18 | `icons.Like` |
| 收藏 (Like) | 21 | `icons.Favorite` |
| 最近 (History) | 24 | `icons.Recently` |
| bottom divider | 27 | |

Our mapping keeps the geometry and changes the destinations: **Podcast → Help**
(there is no podcast here), and the three collection slots become local stores.
The `-3` shift for the logged-out case disappears with the login.

---

## 3. Top bar — `TopBackBar_Frame` (lines 3182–3264)

```
TopBackBar_Frame = Main_Frame:addFrame{ x=18, y=1,
    width="{parent.width-18}", height=4, background=colors.black }
```

| Widget | x | y | size | Notes |
|---|---|---|---|---|
| back chevron | 4 | 2 | 4×3 | `icons.chevron-left` |
| forward chevron | 9 | 2 | 4×3 | `icons.chevron-right` |
| search icon | 15 | 2 | 4×3 | background `pink` |
| search box | 19 | 2 | 30×3 | background `pink` |
| IME-mode button | 67 | 2 | 6×3 | lives on `MonitorFrame`, `z=20`, hidden until the box has focus |
| user button | `{parent.width-44}` | 2 | 40×3 | `icons.User` + name |
| settings | `{parent.width-3}` | 2 | 4×3 | `icons.Settings` → `OpenSettingsWindow` |

Ours: the **user button becomes About**, because there are no accounts, and the
IME-mode button is dropped — the search page decides on its own whether the
input method is on, and says so in its hint line.

---

## 4. Playback bar — `PlaybackBar_Frame` (lines 3272–3520)

```
PlaybackBar_Frame = Main_Frame:addFrame{ x=1, y="{parent.height-5}",
    width="{parent.width}", height=6, background=colors.gray }
```

| Widget | x | y | size | Notes |
|---|---|---|---|---|
| progress used (label) | 1 | 1 | `{floor(parent.width/2)}`×1 | `purple` on `gray`, filled with `"\131"` |
| progress remaining (label) | `{floor(parent.width/2+1)}` | 1 | `{floor(parent.width/2)}`×1 | `pink` |
| progress button | 1 | 1 | `{parent.width}`×1 | `backgroundEnabled=false`, `z=22`; seeks |
| maximise | 1 | 3 | 4×3 | `icons.Maximise` → the full-screen card |
| title label | 6 | 3 | 1×3 → widened by `SetPlaybackBar_Title` | |
| shuffle / prev / play / next / repeat | centred around `{floor(parent.width/2)}` | 3 | 4×3 | |
| duration | `{parent.width-40}` | 3 | 44×3 | |
| volume | `{parent.width-9}` | — | — | opens the volume drawer |
| queue | — | — | — | opens the play queue, showing a count |

The **progress strip is two labels, not a ProgressBar**: the filled part is drawn
in the accent colour, the remainder in the muted colour, and a transparent button
on top converts a click column into a fraction. `ui/app_shell.lua` reproduces
that arrangement rather than substituting a `ProgressBar`, because the two-label
form is what makes the bar clickable.

Ours drops the volume control (our transport has no gain stage, so a slider would
be a control that does nothing) and keeps the queue.

---

## 5. Overlays

| Overlay | Reference | Line | Ours |
|---|---|---|---|
| Full-screen now-playing | `MaxPlay_Frame` + `animate()` | 1221 | kept; the **lyric region becomes the licence/credit block** |
| Volume drawer | `Volume_Frame`, vertical slider | 1243 | replaced by a speaker-status block in Settings |
| Play queue | `PlayQueue_Frame` + `PlayQueue_DismissLayer` | 1266 | kept, half-width right drawer |
| Popups | `Popup_Frame` / `MaxPopup_Frame` | 1296 / 1297 | `frame.show_popup` |
| User menu | `UserMenu_Frame` | 1329 | dropped (no accounts) |
| Search hot / IME | `SearchHot_Frame`, `SearchIme_Frame` | 1447 / 1477 | the search page's own hint line |
| Settings | `Settings_Frame` + `addSideNav(18)` | 2074 | kept, 7 pages instead of 8 |
| Login / QR | `LogIn_Frame` | 4983 | dropped |
| Confirm dialog | `CreateConfirmDialog` | 824 | `frame.create_confirm_dialog` |
| Display selection | `CreateDisplaySelectionPage` | 607 | `frame.create_display_selection_page` |

## 6. Routing

```
NavigationState = { current = "home", history = {}, index = 0, applyingHistory = false }   line 8682
NavigateToPage(page, params)        line ~8655
CapturePageState / ApplyPageState   per-page state saved across a navigation
PageFrames = { home, dailySongs, discover, podcast, playlist, album, like,
               history, artist, search }                                                     line 9168
```

Our router keeps `current`, `history` and `index`, and truncates the forward
entries when a new navigation happens from the middle — the browser behaviour the
reference implements with the same three fields.

## 7. Events

| Event | Reference use | Line |
|---|---|---|
| `key` / `char` / `key_up` | IME and window input | 9308–9316 |
| `http_success` / `http_failure` | routed by a `ImeAPI_T=` token first, else music/player | 68–86 |
| `peripheral` | re-detect audio devices | 3039 |
| `timer` | QR polling, popup expiry, the startup prompt | — |

`basalt.onEvent("key", fn)` is the **global** hook; the reference uses it for the
same reason we do — an element's `:onKey` only fires for the focused child.

---

## 8. Screens — reference → ours

| Reference | Ours | Why |
|---|---|---|
| 推荐 Home (daily / like / FM / playlists / radar / artists) | Home | greeting + local `.nbs` + NBW picks + recently played |
| 发现 Discover (playlist square / charts) | Discover | two tabs over the API's `sort`/`order` |
| Search (songs / playlists / users / albums) | Search | the songs tab is real; the others state that NBW has none |
| 漫游 Roaming / personal FM | Shuffle | a differently sorted list — the API's only "surprise me" |
| 播客 Podcast | Help | hotkeys, monitor requirement, the keyboard risk, credits |
| 喜欢 Liked / 收藏 Saved / 最近 History | Favourites / Downloads / Recent | local stores, because there are no accounts |
| Playlist / Album / Artist | Song detail | NBW exposes one collection |
| Daily songs | — | unreachable without a login, so never navigated to |
| Login, QR, VIP, free-listen | — | no accounts exist |
| Lyrics | — | NBW has none; the region shows licence and credit |
| Volume slider | — | no gain stage in the transport |

## 9. What could not be copied literally

1. **The account screens cannot exist.** NBW has no accounts, playlists, albums,
   artists, lyrics or VIP. The layout is replicated; the data cannot be.
2. **`startup.lua` cannot be copied byte for byte.** It requires MPlayer's own
   `MusicApi`, `ImeApi`, `Lib/Player` (ffmpeg), `Lib/json`, `About` and `Update`.
   This is a structural replica built on this project's layers — porting its
   request plumbing is explicitly forbidden by `AGENTS.md`, because
   `net/http.lua` already does retries, backoff, timeouts and bounded reads.
3. **The CJK font is not shippable.** 1.68 MB against a default 1 MB disk limit,
   so it is fetched at run time and Chinese must degrade to English.
4. **The wireless keyboard cannot be made safe.** Its server queues any rednet
   message whose protocol matches straight into the local event queue. The user
   chose an unconditional install; the risk is therefore documented in the README
   and stated in the program's own Help page rather than hidden.
