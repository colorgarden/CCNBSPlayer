# ccnbs 公共库 API

`ccnbs` 是 CCNBSPlayer 对外的唯一入口模块。其它脚本只需要 `require("ccnbs")`
即可完成「解码 → 分析 → 编排 → 播放」全流程，无需了解内部各层的存在。

模块文件位于**项目根目录** `ccnbs.lua`，而不是 `nbs/init.lua`：目标环境的
`package.path` 不保证包含 `?/init.lua`，但根目录的 `ccnbs.lua` 一定能被
`./?.lua` 这一条默认规则解析到。

## 快速开始

```text
local ccnbs = require("ccnbs")
```

`require` 不会访问网络。安装完成后可从全新 shell 直接加载。

## 公共接口

| 调用 | 返回 |
| --- | --- |
| `ccnbs.decode(bytes)` | 与 `nbs.decode.decode` 完全相同的结构：成功 `{ok=true, song=...}`，失败 `{ok=false, error={code=...}}` |
| `ccnbs.analyze(song)` | 与 `nbs.analyze.analyze` 完全相同的结构 |
| `ccnbs.plan(song, analysis)` | 事件数组（冻结全序 `(tick_index, layer_index, note_index)`） |
| `ccnbs.play(song, opts)` | 一个**会话** `session`，立即返回、不阻塞 |
| `ccnbs.discover_speakers()` | 已挂载扬声器记录数组（side 升序），调用 `player.speaker.discover` |
| `ccnbs.version` | 版本字符串，例如 `"1.0.0"` |

`decode` / `analyze` / `plan` 是**原样转发**，返回值与直接调用底层模块逐字段一致。

## 接缝注入（seams）

`ccnbs.play(song, opts)` 的 `opts` 全部可选。生产环境什么都不传，即使用真实
外设与真实时钟；测试环境注入两个接缝即可获得完全确定性：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `opts.speakers` | `ccnbs.discover_speakers()` | 扬声器记录数组 |
| `opts.clock` | 新建的 `player.clock.new_os()` | 计时来源；可注入虚拟时钟 |
| `opts.on_warning` | 无 | `function(code, args)`，每个不同的**裸**代码至多回调一次 |
| `opts.on_progress` | 无 | `function(info)`，`info = {t_ms, index, total}` |
| `opts.on_event` | 无 | `function(event)`，每个到期事件在**派发之前**回调 |

`play` 只在注入的时钟上排期后立即返回。测试用虚拟时钟通过
`clock.advance_to(vc, target_ms)` 推进；生产用 os 时钟与真实定时器。
`play` 自身不忙等、不睡眠，节奏由 `player.tempo` 负责。

## 会话对象 `session`

| 成员 | 说明 |
| --- | --- |
| `session.cancel()` | 停止播放；幂等 |
| `session.is_playing()` | 是否仍在播放（取消后为 `false`） |
| `session.analysis` | 本次分析结果 |
| `session.plan` | 本次事件数组 |
| `session.assignment` | 扇出分配结果（含 `warning_args`） |
| `session.stats()` | 透传自 tempo 会话的统计 |

## 警告代码

所有警告都经由**同一个** `opts.on_warning(code, args)` 回调上报，每个裸代码
在每个会话中**至多出现一次**。`ccnbs` 只上报**代码**，不负责渲染
`WARN[...]` 文本，也绝不直接打印；文本渲染由 `player/warnings.lua` 负责。

| 代码 | 触发条件 | `args` |
| --- | --- | --- |
| `"extended-range"` | 分析发现存在 33..57 之外的键；**在播放开始时**上报（加载期属性，不是播放中途） | `{min_key, max_key}` |
| `"speakers"` | 扇出发生丢弃或所需扬声器数不足 | `{peak, required, found, dropped}` |
| `"custom-instrument"` | 有自定义乐器事件被拒绝播放 | `{count=<n>}` |
| `"play-sound-pitch"` | 小号音高被夹取进 0.5..2.0 | 无 |
| `"tempo-clamp"` | 某个延时低于定时器粒度（50 ms） | 无 |

## 调用约定：冒号与点号**故意不统一**

注入的两类接缝使用不同的方法调用约定，这是刻意设计的，请勿「统一」：

- **扬声器记录**与**分发器**用冒号（方法带显式 `self`）：
  `rec:play_note(name, vol, pitch)`、`d:event(event, speaker)`。
- **时钟对象**与**时钟模块**用点号（方法不带 `self`）：
  `vc.after(delay, fn)`、`vc.now_ms()`、`clock.advance_to(vc, target)`。
  对时钟调用 `vc:after(...)` 会把时钟自身当作延时传入并报错。

注意 tempo 自己暴露的接口又是冒号风格（`t:play`、`t:cancel`、`t:stats`），
即使它消费的时钟是点号风格。

## 完整可运行示例

下面的示例被测试套件**实际执行**（`tests/api_spec.lua` 会从本文档抽取
`lua` 围栏代码块并运行），因此它不会随接口演进而失效。样例文件
`tests/fixtures/simple.nbs` 随仓库提供；换成你自己的 `.nbs` 路径即可。

```lua
local ccnbs = require("ccnbs")
local clock = require("player.clock")
local speaker = require("player.speaker")

-- 1) 读取并解码一个 .nbs 文件
local file = assert(io.open("tests/fixtures/simple.nbs", "rb"))
local bytes = file:read("*a")
file:close()

local decoded = ccnbs.decode(bytes)
assert(decoded.ok, "decode failed: " .. tostring(decoded.error and decoded.error.code))

-- 2) 注入两个 mock 扬声器与一个虚拟时钟（生产环境省略这两个接缝即可）
local left = speaker.mock("left")
local right = speaker.mock("right")
local vclock = clock.new_virtual(0)

local warning_counts = {}
local session = ccnbs.play(decoded.song, {
  speakers = { left, right },
  clock = vclock,
  on_warning = function(code)
    warning_counts[code] = (warning_counts[code] or 0) + 1
  end,
})

-- 3) 推进虚拟时钟直到歌曲结束（play 不阻塞调用方）
clock.advance_to(vclock, 60000)

assert(session.analysis.total_notes > 0)
assert(#session.plan == #decoded.song.notes)
assert(session.is_playing() == false)
for code, count in pairs(warning_counts) do
  assert(count == 1, "each warning code fires at most once: " .. code)
end
```

## 注意事项

- `ccnbs` 不打印任何内容；警告一律交给 `opts.on_warning`。
- 自定义乐器**从不**被播放：`play` 会跳过并上报一次 `"custom-instrument"`。
- 多扬声器同步在 CC:Tweaked 中是尽力而为；`ccnbs` 只保证分配确定性。
- v1 不支持跳转进度与循环播放。
