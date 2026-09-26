-- ui/i18n.lua
--
-- THE INTERNATIONALISATION LAYER -- the SINGLE place user-facing prose lives.
--
-- ===========================================================================
-- WHY THE DEFAULT IS ENGLISH (do not "fix" it to Chinese)
-- ===========================================================================
-- A stock CC:Tweaked terminal ships NO CJK font, so Chinese prose renders as
-- garbage on screen.  English therefore works on ANY computer with ZERO extra
-- dependencies, and is the DEFAULT.  Chinese is opt-in: it is only usable once
-- a runtime-fetched pixel-font renderer is available.  Both languages are
-- present in this module from the start, so a machine without that renderer
-- still works perfectly in English.  Do NOT hard-code user-facing prose in a
-- renderer again -- add a key to BOTH tables below and call i18n.t().
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local i18n = require("ui.i18n")
--
--   i18n.DEFAULT_LANGUAGE      -- "en"
--   i18n.languages()           -- <array of supported codes, sorted, e.g. {"en","zh"}>
--   i18n.set_language(code)    -- true, or false + reason for an unknown code
--   i18n.get_language()        -- the active code
--   i18n.t(key, args)          -- the translated string, placeholders substituted
--   i18n.has(key)              -- true when the key exists in the ACTIVE language
--   i18n.missing_keys()        -- <array of keys present in "en" but absent in the
--                                 active language>
--
--   i18n.translations(code)    -- DIAGNOSTICS ONLY: the raw string table for a
--                                 language code, or nil.  Do not mutate it in
--                                 production code; it exists so tooling and
--                                 tests can inspect language completeness.
--
-- ===========================================================================
-- NAMED PLACEHOLDERS -- not positional
-- ===========================================================================
-- Sentences use NAMED placeholders such as "{min_key}" / "{count}", NOT the
-- positional "%s".  Chinese word order differs from English, so a translator
-- must be able to MOVE a placeholder within the sentence.  Substitution is
-- done here with string.gsub against `args`; string.format with positional
-- specifiers is never used.
--
--   * A placeholder with no matching arg keeps its literal "{name}" text -- so
--     a Lua `nil` can NEVER reach a rendered string.
--   * i18n.t NEVER raises, whatever it is handed.
--   * A MISSING key returns the KEY itself, so a gap is visible and greppable
--     rather than silent.  (There is deliberately NO English fallback at
--     render time: a gap in the active language must be seen.  Use
--     i18n.missing_keys() to find gaps in bulk.)
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no math.maxinteger, no collectgarbage, no string.dump, no os.exit
-- and no utf8.* -- the tables are plain Lua byte strings.

local i18n = {}

-- The language a fresh computer runs in.  English works everywhere; Chinese
-- needs a runtime-fetched CJK pixel-font renderer.
i18n.DEFAULT_LANGUAGE = "en"

-- ---------------------------------------------------------------------------
-- Translation tables.  ONE key set, one entry per supported language.
-- ---------------------------------------------------------------------------

local TRANSLATIONS = {}

-- English -- the default.  Plain ASCII so it renders on a stock terminal.
TRANSLATIONS.en = {
  -- extended-range: notes outside the native two octaves.
  ["warn.extended_range.both"] =
    "this song has notes outside the native two octaves (key {min_key}..{max_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.min"] =
    "this song has notes outside the native two octaves (lowest key {min_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.max"] =
    "this song has notes outside the native two octaves (highest key {max_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.none"] =
    "this song has notes outside the native two octaves; install an "
    .. "extended-range resource pack to hear the full timbre",

  -- speakers: peak concurrency vs. the speakers actually attached.  These are
  -- FRAGMENTS joined with a localised separator, because the renderer includes
  -- only the fields that are actually present.
  ["warn.speakers.peak"] = "this song peaks at {peak} notes/50ms",
  ["warn.speakers.required"] = "needs {required} speakers",
  ["warn.speakers.found"] = "found {found}",
  ["warn.speakers.dropped"] = "dropped {dropped} notes",
  ["warn.speakers.separator"] = ", ",
  ["warn.speakers.none"] = "not enough speakers; some notes cannot be played",

  -- custom-instrument: .nbs custom instruments are refused and skipped.
  ["warn.custom_instrument.count"] =
    "this song has {count} custom instruments; skipped (not played)",
  ["warn.custom_instrument.none"] =
    "this song has custom instruments; skipped (not played)",

  -- tempo-clamp: the SONG'S OWN tick interval is finer than the 50 ms timer
  -- granularity.  It is not about ordinary chords or the first note.
  ["warn.tempo_clamp"] =
    "tick interval is finer than the 0.05 s timer granularity; clamped",

  -- play-sound-pitch: a v6 trumpet pitch was clamped to an approximation.
  ["warn.play_sound_pitch"] =
    "a trumpet pitch was outside the representable range; clamped to an approximation",

  -- The generic fallback for an unknown warning code.
  ["warn.unknown"] = "unknown warning code; handled by the default policy",

  -- ---------------------------------------------------------------------
  -- Interface: navigation, playback, lists, search, settings, help
  -- ---------------------------------------------------------------------
  ["app.name"] = "CCNBSPlayer",
  ["app.title"] = "CCNBSPlayer",
  ["app.ready"] = "Ready.",
  ["app.preparing"] = "Preparing...",
  ["app.downloading"] = "Downloading",
  ["app.writing"] = "Writing",
  ["app.done"] = "Done.",
  ["app.failed"] = "Failed.",
  ["app.cancelled"] = "Cancelled.",
  ["app.retrying"] = "Retrying...",
  ["app.download_failed"] = "Could not download {name}: {detail}",
  ["app.download_done"] = "Saved {name}.",
  ["app.source_active"] = "Source: {name}",
  ["app.file_progress"] = "{index}/{total}  {name}",
  ["app.err_no_files"] = "no files to install",
  ["app.err_no_fs"] = "no filesystem is available",
  ["app.err_no_http"] = "HTTP is disabled on this computer",
  ["app.err_status"] = "the server answered with status {code}",
  ["app.err_timeout"] = "the request timed out",
  ["app.err_unreadable"] = "the response could not be read",
  ["app.mkdir_failed"] = "could not create {dir}",
  ["app.detail_ready"] = "Pick a source, then start the install.",
  ["app.detail_done"] = "Wrote {count} files under /lib.",
  ["app.detail_cancelled"] = "Nothing was written.",
  ["app.detail_later"] = "Run /lib/ccnbsplayer whenever you like.",
  ["app.detail_download_done"] = "Download complete.",
  ["app.autostart.pending_on"] = "Autostart will be ENABLED when you write.",
  ["app.autostart.pending_off"] = "Autostart will be DISABLED when you write.",

  ["nav.home"] = "Home",
  ["nav.browse"] = "Discover",
  ["nav.roaming"] = "Shuffle",
  ["nav.help"] = "Help",
  ["nav.likes"] = "Favourites",
  ["nav.downloads"] = "Downloads",
  ["nav.recent"] = "Recent",
  ["nav.about"] = "About",

  ["search.placeholder"] = "Search Note Block World                ",
  ["search.submit"] = "Search",
  ["search.hint_ime"] = "Type pinyin or ASCII; Enter searches, Escape closes the box.",
  ["search.hint_ascii"] = "Type ASCII and press Enter; the Chinese input method is off.",
  ["search.tab_songs"] = "Songs",
  ["search.tab_players"] = "Uploaders",
  ["search.tab_albums"] = "Albums",
  ["search.unsupported"] = "Note Block World has no such category; only songs.",

  ["browse.title"] = "Discover",
  ["browse.tab_new"] = "Newest",
  ["browse.tab_hot"] = "Most played",
  ["browse.offline"] = "Note Block World is unreachable; check the network in Settings.",

  ["home.subtitle"] = "Local Note Block Studio songs, plus picks from Note Block World.",
  ["home.section_local"] = "On this computer",
  ["home.section_featured"] = "From Note Block World",
  ["home.section_recent"] = "Recently played",
  ["home.loading"] = "Loading...",
  ["home.offline"] = "Note Block World is unreachable (see Settings > Network).",
  ["home.no_local"] = "No .nbs files in this directory.",
  ["home.no_recent"] = "Nothing played yet.",
  ["home.greeting"] = "Welcome",
  ["home.greeting_morning"] = "Good morning",
  ["home.greeting_afternoon"] = "Good afternoon",
  ["home.greeting_evening"] = "Good evening",
  ["home.greeting_night"] = "Still up",

  ["library.local_title"] = "On this computer",
  ["library.local_hint"] = "Every .nbs file in the working directory.",
  ["library.local_empty"] = "No .nbs files here. Download one, or copy files in.",
  ["library.downloads_title"] = "Downloads",
  ["library.downloads_hint"] = "Songs you downloaded from Note Block World.",
  ["library.downloads_empty"] = "Nothing downloaded yet. Open a song and press Download.",
  ["library.likes_title"] = "Favourites",
  ["library.likes_hint"] = "Songs you marked as favourites.",
  ["library.likes_empty"] = "No favourites yet.",
  ["library.recent_title"] = "Recently played",
  ["library.recent_hint"] = "Newest first, capped so it cannot fill the disk.",
  ["library.recent_empty"] = "Nothing played yet.",
  ["library.no_scanner"] = "the song scanner is unavailable",
  ["library.scan_failed"] = "could not read this directory",
  ["library.no_store"] = "the local store is unavailable",
  ["library.store_failed"] = "could not read the local store",

  ["list.loading"] = "Loading...",
  ["list.empty"] = "Nothing to show.",
  ["list.error"] = "Something went wrong.",
  ["list.previous"] = "< Previous",
  ["list.next"] = "Next >",
  ["list.page_of"] = "page {page}/{pages}   {total} in total",
  ["list.page_label"] = "{page}/{pages}",

  ["song.play"] = "Play",
  ["song.download"] = "Download",
  ["song.licence"] = "Licence",
  ["song.credit"] = "Credit",
  ["song.no_licence"] = "no licence stated - treat as all rights reserved",
  ["song.unknown_title"] = "Untitled song",
  ["song.unknown_author"] = "unknown uploader",

  ["queue.title"] = "Play queue",
  ["queue.count"] = "{total} items   page {page}/{pages}",
  ["queue.close"] = "Close",

  ["player.play"] = "Play",
  ["player.pause"] = "Pause",
  ["player.stop"] = "Stop",
  ["player.previous"] = "<<",
  ["player.next"] = ">>",
  ["player.close"] = "Close",

  ["display.title"] = "Select a monitor",
  ["display.none"] = "No monitor found. Attach one and reboot.",

  ["settings.title"] = "Settings",
  ["settings.general"] = "General",
  ["settings.network"] = "Network",
  ["settings.display"] = "Display",
  ["settings.audio"] = "Audio",
  ["settings.appearance"] = "Appearance",
  ["settings.about"] = "About",
  ["settings.update"] = "Update",
  ["settings.close"] = "Close",
  ["settings.on"] = "ON",
  ["settings.off"] = "OFF",
  ["settings.saved"] = "Saved.",
  ["settings.cleared"] = "Local history and favourites cleared.",
  ["settings.restart_required"] = "Saved. Restart the program to apply the language.",
  ["settings.bad_url"] = "That is not a valid http:// or https:// address.",
  ["settings.editing"] = "Editing: {value}",
  ["settings.edit_cancelled"] = "Edit cancelled.",
  ["settings.ime_edit_hint"] = "Type the address, then press Enter.",
  ["settings.general_section"] = "Language and local data",
  ["settings.language"] = "Language (en / zh)",
  ["settings.clear_history"] = "Clear history + favourites",
  ["settings.nbw_section"] = "Note Block World",
  ["settings.nbw_url"] = "API address",
  ["settings.nbw_timeout"] = "Timeout (seconds)",
  ["settings.nbw_retries"] = "Retries",
  ["settings.ime_section"] = "Chinese input method",
  ["settings.ime_enabled"] = "Enabled (click to toggle)",
  ["settings.ime_url"] = "Lookup address (click to edit)",
  ["settings.ime_timeout"] = "Timeout (seconds)",
  ["settings.ime_unavailable"] = "the input method module is unavailable",
  ["settings.ime_note"] =
    "The lookup runs against an external service, so Chinese input needs that "
    .. "host to be reachable. Turning it off leaves the search box ASCII-only. "
    .. "The default is the address the reference project uses.",
  ["settings.display_section"] = "Monitor",
  ["settings.display_current"] = "In use",
  ["settings.display_note"] =
    "Monitors are chosen at startup, before the interface can be laid out. "
    .. "Delete Settings/Display.json to be asked again.",
  ["settings.appearance_section"] = "Palette",
  ["settings.appearance_note"] =
    "Seven of the sixteen terminal colours are redefined for the dark theme. "
    .. "Colours are not editable from here yet.",
  ["settings.audio_section"] = "Speakers",
  ["settings.audio_speakers"] = "Speakers found",
  ["settings.audio_note"] =
    "There is no volume control: notes are scheduled, not mixed, so the "
    .. "loudness of a note is fixed by its velocity in the song.",
  ["settings.update_section"] = "Updates",
  ["settings.update_note"] =
    "Run /lib/updater in the shell to check for and install an update. It reads "
    .. "the version from the repository and only writes when it is newer.",

  ["about.title"] = "About",
  ["about.version"] = "version {version}",
  ["about.purpose"] =
    "A Note Block Studio song player for CC:Tweaked. It schedules notes to "
    .. "speakers; it does not decode or play audio samples.",
  ["about.not_official"] =
    "Independent project. Not affiliated with Mojang, CC:Tweaked, Note Block "
    .. "World or Note Block Studio.",
  ["about.licence"] =
    "This program is GPL-2.0. Third-party components keep their own licences; "
    .. "see NOTICE in the repository.",
  ["about.credits"] = "Credits",
  ["about.credit_basalt"] = "Basalt 2 (fork) - MIT",
  ["about.credit_utf8"] = "ComputerCraft-Utf8 utf8display - via MPlayer, GPL-2.0",
  ["about.credit_font"] =
    "Fusion Pixel Font - MIT, fetched at run time when Chinese is shown",
  ["about.credit_nbw"] = "Note Block World - song search and download",
  ["about.credit_keyboard"] =
    "cct-keyboard - wireless keyboard, fetched from upstream at install time",
  ["about.credit_icons"] = "Icon set - from MPlayer, GPL-2.0",

  ["help.title"] = "Help",
  ["help.section_keys"] = "Keys",
  ["help.section_monitor"] = "Monitor",
  ["help.section_keyboard"] = "Wireless keyboard - please read",
  ["help.section_nbw"] = "Note Block World",
  ["help.section_font"] = "Chinese text",
  ["help.key_up_down"] = "Up / Down",
  ["help.key_enter"] = "Enter",
  ["help.key_space"] = "Space or P",
  ["help.key_s"] = "S or Q",
  ["help.key_arrows"] = "Left / Right",
  ["help.key_escape"] = "Escape",
  ["help.act_select"] = "move through a list",
  ["help.act_play"] = "play the selected song",
  ["help.act_pause"] = "pause / resume",
  ["help.act_stop"] = "stop",
  ["help.act_seek"] = "seek one step",
  ["help.act_quit"] = "quit",
  ["help.global_note"] =
    "Space, S and the arrow keys are GLOBAL: they act on playback even while "
    .. "you are typing in a search box, unless you are editing a settings field.",
  ["help.monitor_body"] =
    "The interface is drawn on a MONITOR at half text scale, which is what "
    .. "makes the multi-section layout fit. With no monitor attached the program "
    .. "shows a selection page instead and reboots once you pick one.",
  ["help.keyboard_body"] =
    "A wireless keyboard server is installed and started at boot. It injects any "
    .. "rednet message whose protocol matches straight into this computer's event "
    .. "queue.",
  ["help.keyboard_advice"] =
    "That means ANYONE ON THE SAME REDNET CAN TYPE INTO THIS COMPUTER, including "
    .. "mouse clicks and pasted text. On a private world that is the point; on a "
    .. "shared server, delete /Keyboard_server.lua and the line in /startup.lua, "
    .. "or do not run the wireless modem.",
  ["help.nbw_body"] =
    "Songs are searched and downloaded from Note Block World. Downloads are "
    .. "written into the working directory as .nbs files.",
  ["help.nbw_licence"] =
    "Each song carries its OWN licence, shown before you play it. Standard means "
    .. "personal listening only; CC BY-SA allows reuse if you credit the author. "
    .. "This program never bundles a song.",
  ["help.font_body"] =
    "Chinese needs a pixel font fetched at run time, because it is larger than a "
    .. "default computer's whole disk. If it cannot be fetched the interface falls "
    .. "back to English rather than showing garbage.",
}

-- Chinese -- opt-in, only usable when a CJK pixel-font renderer is loaded.
TRANSLATIONS.zh = {
  ["warn.extended_range.both"] =
    "本曲含超出原生两个八度的音符（key {min_key}..{max_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.min"] =
    "本曲含超出原生两个八度的音符（最低 key {min_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.max"] =
    "本曲含超出原生两个八度的音符（最高 key {max_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.none"] =
    "本曲含超出原生两个八度的音符，需安装扩展音域材质包才能听到完整音色",

  ["warn.speakers.peak"] = "本曲峰值 {peak} 音符/50ms",
  ["warn.speakers.required"] = "需要 {required} 个扬声器",
  ["warn.speakers.found"] = "实际 {found} 个",
  ["warn.speakers.dropped"] = "已丢弃 {dropped} 个音符",
  ["warn.speakers.separator"] = "，",
  ["warn.speakers.none"] = "扬声器数量不足，部分音符无法播放",

  ["warn.custom_instrument.count"] = "本曲含 {count} 个自定义乐器，已跳过不播放",
  ["warn.custom_instrument.none"] = "本曲含自定义乐器，已跳过不播放",

  -- Corrected semantics: the SONG'S OWN tick interval is below the 50 ms timer
  -- granularity -- not an ordinary chord and not the first note.
  ["warn.tempo_clamp"] = "歌曲自身的节拍间隔低于 0.05 秒计时粒度，已钳制",

  ["warn.play_sound_pitch"] = "小号音高超出可表示范围，已钳制为近似值",

  ["warn.unknown"] = "未知警告码，已按默认方式处理",

  -- ---------------------------------------------------------------------
  -- 界面：导航、播放、列表、搜索、设置、帮助
  -- ---------------------------------------------------------------------
  ["app.name"] = "CCNBSPlayer",
  ["app.title"] = "CCNBSPlayer",
  ["app.ready"] = "就绪。",
  ["app.preparing"] = "正在准备……",
  ["app.downloading"] = "正在下载",
  ["app.writing"] = "正在写入",
  ["app.done"] = "完成。",
  ["app.failed"] = "失败。",
  ["app.cancelled"] = "已取消。",
  ["app.retrying"] = "正在重试……",
  ["app.download_failed"] = "无法下载 {name}：{detail}",
  ["app.download_done"] = "已保存 {name}。",
  ["app.source_active"] = "当前来源：{name}",
  ["app.file_progress"] = "{index}/{total}  {name}",
  ["app.err_no_files"] = "没有要安装的文件",
  ["app.err_no_fs"] = "文件系统不可用",
  ["app.err_no_http"] = "本机未启用 HTTP",
  ["app.err_status"] = "服务器返回状态 {code}",
  ["app.err_timeout"] = "请求超时",
  ["app.err_unreadable"] = "响应无法读取",
  ["app.mkdir_failed"] = "无法创建 {dir}",
  ["app.detail_ready"] = "选择来源后开始安装。",
  ["app.detail_done"] = "已写入 {count} 个文件到 /lib。",
  ["app.detail_cancelled"] = "没有写入任何文件。",
  ["app.detail_later"] = "之后随时可运行 /lib/ccnbsplayer。",
  ["app.detail_download_done"] = "下载完成。",
  ["app.autostart.pending_on"] = "点「写入」后将开启开机自启动。",
  ["app.autostart.pending_off"] = "点「写入」后将关闭开机自启动。",

  ["nav.home"] = "主页",
  ["nav.browse"] = "发现",
  ["nav.roaming"] = "随机",
  ["nav.help"] = "帮助",
  ["nav.likes"] = "收藏",
  ["nav.downloads"] = "下载",
  ["nav.recent"] = "最近",
  ["nav.about"] = "关于",

  ["search.placeholder"] = "搜索 Note Block World                ",
  ["search.submit"] = "搜索",
  ["search.hint_ime"] = "可输拼音或英文字母；回车搜索，Esc 关闭输入。",
  ["search.hint_ascii"] = "请输入英文字母后回车；中文输入法当前关闭。",
  ["search.tab_songs"] = "歌曲",
  ["search.tab_players"] = "上传者",
  ["search.tab_albums"] = "专辑",
  ["search.unsupported"] = "Note Block World 没有这个分类，只有歌曲。",

  ["browse.title"] = "发现",
  ["browse.tab_new"] = "最新",
  ["browse.tab_hot"] = "最热",
  ["browse.offline"] = "无法连接 Note Block World，请在设置里检查网络。",

  ["home.subtitle"] = "本机的 Note Block Studio 歌曲，以及来自 Note Block World 的推荐。",
  ["home.section_local"] = "本机歌曲",
  ["home.section_featured"] = "来自 Note Block World",
  ["home.section_recent"] = "最近播放",
  ["home.loading"] = "正在加载……",
  ["home.offline"] = "无法连接 Note Block World（见 设置 > 网络）。",
  ["home.no_local"] = "当前目录没有 .nbs 文件。",
  ["home.no_recent"] = "还没有播放记录。",
  ["home.greeting"] = "欢迎",
  ["home.greeting_morning"] = "早上好",
  ["home.greeting_afternoon"] = "下午好",
  ["home.greeting_evening"] = "晚上好",
  ["home.greeting_night"] = "夜深了",

  ["library.local_title"] = "本机歌曲",
  ["library.local_hint"] = "当前工作目录下的全部 .nbs 文件。",
  ["library.local_empty"] = "这里没有 .nbs 文件。可以下载一首，或手动拷进来。",
  ["library.downloads_title"] = "下载",
  ["library.downloads_hint"] = "你从 Note Block World 下载的歌曲。",
  ["library.downloads_empty"] = "还没有下载过。打开一首歌，点「下载」。",
  ["library.likes_title"] = "收藏",
  ["library.likes_hint"] = "你标记为收藏的歌曲。",
  ["library.likes_empty"] = "还没有收藏。",
  ["library.recent_title"] = "最近播放",
  ["library.recent_hint"] = "最新在前，有上限，不会把磁盘写满。",
  ["library.recent_empty"] = "还没有播放记录。",
  ["library.no_scanner"] = "歌曲扫描功能不可用",
  ["library.scan_failed"] = "无法读取该目录",
  ["library.no_store"] = "本地存储不可用",
  ["library.store_failed"] = "无法读取本地存储",

  ["list.loading"] = "正在加载……",
  ["list.empty"] = "没有内容。",
  ["list.error"] = "出错了。",
  ["list.previous"] = "< 上一页",
  ["list.next"] = "下一页 >",
  ["list.page_of"] = "第 {page}/{pages} 页　共 {total} 项",
  ["list.page_label"] = "{page}/{pages}",

  ["song.play"] = "播放",
  ["song.download"] = "下载",
  ["song.licence"] = "许可证",
  ["song.credit"] = "归属",
  ["song.no_licence"] = "未声明许可证——按「保留所有权利」对待",
  ["song.unknown_title"] = "未命名歌曲",
  ["song.unknown_author"] = "未知上传者",

  ["queue.title"] = "播放队列",
  ["queue.count"] = "共 {total} 项　第 {page}/{pages} 页",
  ["queue.close"] = "关闭",

  ["player.play"] = "播放",
  ["player.pause"] = "暂停",
  ["player.stop"] = "停止",
  ["player.previous"] = "<<",
  ["player.next"] = ">>",
  ["player.close"] = "关闭",

  ["display.title"] = "请选择显示器",
  ["display.none"] = "未找到显示器。接一个显示器后重启。",

  ["settings.title"] = "设置",
  ["settings.general"] = "常规",
  ["settings.network"] = "网络",
  ["settings.display"] = "显示",
  ["settings.audio"] = "音频",
  ["settings.appearance"] = "外观",
  ["settings.about"] = "关于",
  ["settings.update"] = "更新",
  ["settings.close"] = "关闭",
  ["settings.on"] = "开",
  ["settings.off"] = "关",
  ["settings.saved"] = "已保存。",
  ["settings.cleared"] = "已清空本地历史与收藏。",
  ["settings.restart_required"] = "已保存。重启程序后语言生效。",
  ["settings.bad_url"] = "这不是有效的 http:// 或 https:// 地址。",
  ["settings.editing"] = "正在编辑：{value}",
  ["settings.edit_cancelled"] = "已取消编辑。",
  ["settings.ime_edit_hint"] = "输入地址后按回车。",
  ["settings.general_section"] = "语言与本地数据",
  ["settings.language"] = "语言（en / zh）",
  ["settings.clear_history"] = "清空历史与收藏",
  ["settings.nbw_section"] = "Note Block World",
  ["settings.nbw_url"] = "API 地址",
  ["settings.nbw_timeout"] = "超时（秒）",
  ["settings.nbw_retries"] = "重试次数",
  ["settings.ime_section"] = "中文输入法",
  ["settings.ime_enabled"] = "启用（点击切换）",
  ["settings.ime_url"] = "查询地址（点击编辑）",
  ["settings.ime_timeout"] = "超时（秒）",
  ["settings.ime_unavailable"] = "输入法模块不可用",
  ["settings.ime_note"] =
    "查询走的是外部服务，所以中文输入需要该主机可达。关掉之后搜索框只能用"
    .. "英文。默认地址与参考实现一致。",
  ["settings.display_section"] = "显示器",
  ["settings.display_current"] = "当前使用",
  ["settings.display_note"] =
    "显示器在启动时选定，因为界面必须先知道画在哪。删除 Settings/Display.json "
    .. "可以重新选择。",
  ["settings.appearance_section"] = "配色",
  ["settings.appearance_note"] =
    "深色主题重定义了 16 色中的 7 色。目前还不能在这里直接改颜色。",
  ["settings.audio_section"] = "扬声器",
  ["settings.audio_speakers"] = "已发现扬声器",
  ["settings.audio_note"] =
    "没有音量控制：音符是被调度的，不是混音，所以音量由歌曲里的力度决定。",
  ["settings.update_section"] = "更新",
  ["settings.update_note"] =
    "在 shell 里运行 /lib/updater 即可检查并安装更新。它会读取仓库版本，只有"
    .. "更新时才写入。",

  ["about.title"] = "关于",
  ["about.version"] = "版本 {version}",
  ["about.purpose"] =
    "CC:Tweaked 上的 Note Block Studio 歌曲播放器。它只把音符调度到扬声器，"
    .. "不解码也不播放音频采样。",
  ["about.not_official"] =
    "独立项目，与 Mojang、CC:Tweaked、Note Block World、Note Block Studio "
    .. "均无隶属关系。",
  ["about.licence"] =
    "本程序以 GPL-2.0 发布。第三方组件各自保留其许可证，详见仓库中的 NOTICE。",
  ["about.credits"] = "致谢",
  ["about.credit_basalt"] = "Basalt 2（fork）——MIT",
  ["about.credit_utf8"] = "ComputerCraft-Utf8 utf8display——经 MPlayer，GPL-2.0",
  ["about.credit_font"] = "Fusion Pixel Font——MIT，显示中文时运行时获取",
  ["about.credit_nbw"] = "Note Block World——歌曲搜索与下载",
  ["about.credit_keyboard"] = "cct-keyboard——无线键盘，安装时从上游获取",
  ["about.credit_icons"] = "图标集——来自 MPlayer，GPL-2.0",

  ["help.title"] = "帮助",
  ["help.section_keys"] = "按键",
  ["help.section_monitor"] = "显示器",
  ["help.section_keyboard"] = "无线键盘——请务必阅读",
  ["help.section_nbw"] = "Note Block World",
  ["help.section_font"] = "中文显示",
  ["help.key_up_down"] = "上 / 下",
  ["help.key_enter"] = "回车",
  ["help.key_space"] = "空格 或 P",
  ["help.key_s"] = "S 或 Q",
  ["help.key_arrows"] = "左 / 右",
  ["help.key_escape"] = "Esc",
  ["help.act_select"] = "在列表中移动",
  ["help.act_play"] = "播放选中歌曲",
  ["help.act_pause"] = "暂停 / 继续",
  ["help.act_stop"] = "停止",
  ["help.act_seek"] = "步进跳转",
  ["help.act_quit"] = "退出",
  ["help.global_note"] =
    "空格、S 和左右方向键是全局键：即使你正在搜索框里打字也会作用于播放，"
    .. "除非你正在编辑设置项。",
  ["help.monitor_body"] =
    "界面画在显示器上，文字缩放 0.5——这是多分区布局能塞下的原因。没有接显示器"
    .. "时程序会显示选择页，选定后自动重启。",
  ["help.keyboard_body"] =
    "无线键盘服务端会被安装并在开机时自动启动。它会把任何协议名匹配的红网消息"
    .. "直接注入本机事件队列。",
  ["help.keyboard_advice"] =
    "这意味着同一红网上的任何人都能向本机打字，包括鼠标点击和粘贴文本。私人存档"
    .. "里这正是目的；但在公共服务器上，请删除 /Keyboard_server.lua 与 /startup.lua "
    .. "里对应那行，或者不要装无线调制解调器。",
  ["help.nbw_body"] =
    "歌曲来自 Note Block World 的搜索与下载。下载会以 .nbs 文件写到工作目录。",
  ["help.nbw_licence"] =
    "每首歌有自己的许可证，播放前会显示。Standard 仅限个人收听；CC BY-SA 允许"
    .. "在署名前提下二次使用。本程序从不打包歌曲。",
  ["help.font_body"] =
    "中文需要运行时获取的像素字体，因为它比默认电脑的整个磁盘上限还大。取不到时"
    .. "界面会退回英文，而不是显示乱码。",
}

-- The active language.  Module-level state, deliberately: the whole program
-- shares one UI language.
local active = i18n.DEFAULT_LANGUAGE

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Replace "{name}" placeholders in `text` with args[name].  A placeholder with
-- no matching arg is left verbatim -- never the Lua nil.  The outer parentheses
-- keep only string.gsub's first return value.
local function substitute(text, args)
  if type(text) ~= "string" then
    return text
  end
  -- Placeholder names may contain letters, digits and underscores
  -- (e.g. {min_key}); `%w` alone would miss the underscore.
  return (text:gsub("{([%w_]+)}", function(name)
    local value = args[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end

-- ---------------------------------------------------------------------------
-- Language registry
-- ---------------------------------------------------------------------------

-- i18n.languages() -> a FRESH, sorted array of supported codes.
function i18n.languages()
  local codes = {}
  for code in pairs(TRANSLATIONS) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  return codes
end

-- i18n.set_language(code) -> true | false, reason.  Never raises.
function i18n.set_language(code)
  if type(code) ~= "string" then
    return false, "language code must be a string, got " .. type(code)
  end
  if TRANSLATIONS[code] == nil then
    return false, "unsupported language '" .. code .. "' (supported: "
      .. table.concat(i18n.languages(), ", ") .. ")"
  end
  active = code
  return true
end

-- i18n.get_language() -> the active code.
function i18n.get_language()
  return active
end

-- i18n.translations(code) -> the raw table for a language, or nil.
-- DIAGNOSTICS ONLY: do not mutate in production code.
function i18n.translations(code)
  if type(code) ~= "string" then
    return nil
  end
  return TRANSLATIONS[code]
end

-- ---------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------

-- i18n.has(key) -> true when `key` exists in the ACTIVE language.
function i18n.has(key)
  if type(key) ~= "string" then
    return false
  end
  local table_for_language = TRANSLATIONS[active]
  return table_for_language ~= nil and table_for_language[key] ~= nil
end

-- i18n.t(key, args) -> translated, placeholder-substituted string.
--
-- Never raises and never returns nil.  A key absent from the ACTIVE language
-- returns the key itself, so a gap is visible and greppable.
function i18n.t(key, args)
  if type(key) ~= "string" then
    return ""
  end

  local table_for_language = TRANSLATIONS[active]
  local text = nil
  if table_for_language ~= nil then
    text = table_for_language[key]
  end
  if type(text) ~= "string" then
    return key
  end

  if type(args) ~= "table" then
    args = {}
  end
  return substitute(text, args)
end

-- i18n.missing_keys() -> a FRESH, sorted array of keys present in the DEFAULT
-- (English) language but absent from the ACTIVE language.
function i18n.missing_keys()
  local baseline = TRANSLATIONS[i18n.DEFAULT_LANGUAGE] or {}
  local table_for_language = TRANSLATIONS[active] or {}

  local missing = {}
  for key in pairs(baseline) do
    if table_for_language[key] == nil then
      missing[#missing + 1] = key
    end
  end
  table.sort(missing)
  return missing
end

return i18n
