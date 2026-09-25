# CCNBSPlayer

在 [CC:Tweaked](https://tweaked.cc/) 电脑上播放
[Note Block Studio](https://noteblock.studio/) 的 `.nbs` 歌曲文件的音乐播放器。
它读取 `.nbs` 乐谱，解码、分析、编排，再通过游戏内的 `speaker` 外设**调度音符**
发声——**不打包、不播放任何音频采样**。

> 当前版本：`1.0.0`。这是一个可安装、可运行的正式版本。

## 这是什么

- 解码已发布的 `.nbs` 格式（v0 老格式到 v6）：图层、音符力度/声像/音高、自定义
  乐器与循环元数据。
- 加载歌曲时做分析：总音符数、峰值并发、是否需要扩展音域、需要几个扬声器。
- 把乐谱编排成一条**确定的全序事件流**，按节拍调度到扬声器上，调用
  `speaker.playNote`（普通音符盒音色）与 `speaker.playSound`（v6 小号类音色）。
- 当一首歌同一时刻的音符数超过单扬声器上限时，自动把音符**分配到多个扬声器**，
  并在数量不足时提示需要几个。

**一句话**：它是「音符调度器」，不是「音频播放器」——声音由 Minecraft 自己合成，
本项目只负责在正确的时刻敲下正确的音符。

## 安装

### 方式一：一键安装（推荐，需要 HTTP）

在电脑的 shell 里运行：

```text
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
```

安装器会把运行所需的全部文件下载并放到 `/lib/` 下。成功后终端会打印一段中文横幅，
并告诉你用法。

**前提：HTTP 必须可用。** 好消息是：**两个平台的 HTTP 默认都是开启的**，因此绝大多数
用户**无需做任何事**：

- **CraftOS-PC 模拟器**：开关是模拟器自己的配置文件 `config/global.json`（位于 CraftOS-PC
  的**用户数据目录**中）里的 `http_enable` 键，默认 `true`。
- **真实 CC:Tweaked 服务器**：开关是服务器配置 `computercraft-server.toml` 里的
  `http.enabled`，默认 `true`。

若 HTTP 被人为关闭，`wget` 会先失败；即便直接运行安装器，它也会给出**明确的中文提示**。
此时请**直接编辑上述配置文件**并**重启**模拟器 / 服务器后再重试——而不是抛出一段看不懂
的 traceback。

> 注意：本项目的被测 CraftOS-PC 2.8.3 构建**会忽略 `-o` / `--option` 启动参数**
> （实测 `-o maxNotesPerTick=...` 与 `--option` 两种写法均不生效），所以**不要**指望用
> `-o http_enable=true` 打开 HTTP——那条路走不通，**只有改配置文件并重启才有效**。

安装器是**幂等**的：重复运行会干净地覆盖旧文件，不会破坏既有安装。

### 方式二：手动复制（无 HTTP 时）

把仓库里这些文件按原目录结构复制到电脑的 `/lib/`：

```text
/lib/ccnbs.lua            （库入口）
/lib/ccnbsplayer.lua      （交互播放器）
/lib/nbs/*.lua            （10 个解码/分析模块）
/lib/player/*.lua         （10 个运行时/界面模块）
```

共 22 个文件。复制完成后即可直接使用。

### 安装位置与 `require` 解析规则（重要）

安装根目录是 **`/lib/`**。请务必理解这条规则，否则会踩到 `module not found`：

- CC:Tweaked 的 `require` **没有**一个固定的 `/lib` 搜索根。它的 `package.path` 是
  `?;?.lua;?/init.lua;/rom/modules/main/?;...`，其中 `?` 模式会**相对于「正在运行的
  程序所在目录」**解析。
- 因此 `/lib/` 之所以可用，是因为**整棵运行时都在 `/lib` 下，且入口程序
  `ccnbsplayer.lua` 也在 `/lib` 下**。当你运行 `/lib/ccnbsplayer` 时，它的目录是
  `/lib`，于是 `require("ccnbs")` 找到 `/lib/ccnbs.lua`，`require("nbs.decode")`
  找到 `/lib/nbs/decode.lua`。
- 这也正是仓库根目录那个 `ccnbs.lua` 必须与 `ccnbsplayer.lua` 放在**同一个目录**的
  原因（安装后即都在 `/lib`）。
- 若你在**别处**写自己的脚本要用这个库，请显式把 `/lib` 加进搜索路径：

  ```lua
  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
  local ccnbs = require("ccnbs")
  ```

## 使用

### 运行播放器

安装后，在 shell（当前目录为 `/`）里输入：

```text
lib/ccnbsplayer
```

或先 `cd lib` 再输入 `ccnbsplayer`。

播放器会列出**当前工作目录**下的 `.nbs` 文件，用方向键选择、回车开始。

### 歌曲文件放哪里

把 `.nbs` 文件放到播放器的**当前工作目录**（例如默认的 `/`，或你 `cd` 进去的目录）。
播放器只扫描当前目录，不会递归子目录。

### 传输键

| 操作 | 按键 |
|---|---|
| 选择上一首 / 下一首 | ↑ / ↓ |
| 开始播放选中的歌曲 | Enter / 空格 |
| 暂停 / 继续 | 空格 或 `p` |
| 停止 | `s` 或 `q` |

> v1 **不支持**跳转进度（seek）与循环播放；左右方向键在播放阶段是空操作。

### 扬声器数量要求

**同时发声的音符越多，需要的扬声器越多。** 一个 CC:T 扬声器每个游戏 tick 最多接受
**8 次** `playNote`；一次 `playSound`（v6 小号类音色）则独占一整个 tick。播放器会
在分析阶段算出所需数量，并在不足时给出形如下面的提示：

```text
WARN[speakers] 本曲峰值 <peak> 音符/50ms，需要 <required> 个扬声器，实际 <found> 个，已丢弃 <dropped> 个音符
```

按提示增加扬声器即可消除丢音。所需数量由公式
`ceil(峰值香草音符数 / 8) + 峰值小号音符数` 给出。

### 扩展音域提醒（需要材质包）

NBS 音符的**原生两个八度**对应 key `33..57`。当一首歌使用了该范围**之外**的音符时，
播放器会提示：

```text
WARN[extended-range] 本曲含超出原生两个八度的音符（key ...），需安装扩展音域材质包才能听到完整音色
```

此时需要**自行安装社区提供的扩展音域材质包**才能听到这些音符的完整音色（本项目不
提供、也不自动安装材质包）。

一个必须知道的行为差异：**真实 CC:Tweaked 会原样接受越界音高**（交给客户端与材质包
表现），而 **CraftOS-PC 模拟器会比游戏更严**，对 0..24 之外的音高直接报错。这是
「模拟器比游戏更严」的单侧分歧，不是项目缺陷。完整的源码证据与逐项对照见
[`docs/COMPAT.md`](docs/COMPAT.md)。

## 警告代码参考

所有警告都用同一种**机器可识别标记**呈现：`WARN[<code>] <中文说明>`，由
`player/warnings.lua` 渲染；交互播放器与验收探针会把它打印出来。库入口 `ccnbs` 只把
**裸代码**交给 `opts.on_warning(code, args)`，自己不打印。**每个代码在一首歌里至多出现
一次。**

| 代码 | 触发时机 | 含义（`args`） | 你该怎么办 |
|---|---|---|---|
| `WARN[speakers]` | 播放开始时（由扇出分配决定） | 本曲峰值并发超过现有扬声器能承载的量，部分音符被丢弃。`{peak, required, found, dropped}` | 把扬声器增加到 `required` 个 |
| `WARN[extended-range]` | 播放开始时（加载期属性，不是播放中途） | 曲中含原生两个八度（key `33..57`）之外的音符。`{min_key, max_key}` | 自行安装社区扩展音域材质包；真实 CC:Tweaked 会原样接受越界音高 |
| `WARN[custom-instrument]` | 播放结束或取消时汇总 | 曲中含 `.nbs` 自定义乐器；这些音符**被拒绝播放并跳过**（没有任何扬声器调用）。`{count}` | 无需操作；**自定义乐器不会发声**，属预期行为 |
| `WARN[play-sound-pitch]` | 播放到对应音符时 | v6 小号类音色（`speaker.playSound`）的音高超出可表示范围（0.5..2.0），被夹取为近似值 | 接受近似音高；属已知限制 |
| `WARN[tempo-clamp]` | **歌曲自身的节拍**细于 50 ms 计时粒度时，一次性 | 曲目的 tick 间隔本身比 CC:Tweaked 计时器的 0.05 s（50 ms）粒度更细。注意：普通的**同刻音符（和弦）与第一拍不会**触发它 | 接受轻微的节拍量化；属已知限制 |

> `WARN[tempo-clamp]` 只描述**歌曲自身节拍**快于 20 tps（即 `tick_ms < 50`）的情况，
> 不是给和弦或第一拍发的。

## 明确不做的事

- **不打包、不播放音频采样**，不使用 DFPWM / PCM 之类的音频接口——本项目只调度
  音符调用，声音由 Minecraft 合成。
- **不播放自定义乐器**（`.nbs` 内自带的自定义乐器）——遇到时跳过并一次性提示。
- **v1 不支持**跳转进度（seek）与循环播放。
- 不修改 Minecraft、不修改服务端，也不会替你安装材质包。

## 库 API

除了交互播放器，本项目还提供一个可 `require` 的库入口：

```lua
local ccnbs = require("ccnbs")   -- 需先把 /lib 加进 package.path，见上文

ccnbs.version                       -- "1.0.0"
ccnbs.decode(bytes)                 -- 解码，返回「包装表」（见下），不是歌曲本身
ccnbs.analyze(song)                 -- 分析
ccnbs.plan(song, analysis)          -- 编排为有序事件
ccnbs.discover_speakers()           -- 已挂载的扬声器
ccnbs.play(song, opts) -> session   -- 播放（立即返回，不阻塞）
```

**`decode` 返回的是一个「包装表」，不是歌曲本身**——请先判断 `.ok`，再取 `.song`：

```lua
local result = ccnbs.decode(bytes)
-- 成功：result = { ok = true,  song = <歌曲表> }
-- 失败：result = { ok = false, error = { code = "E_...", msg = ... } }

if not result.ok then
  print("解码失败：" .. tostring(result.error.code))
  return
end

local song = result.song              -- play 要的是 song，不是 result
local analysis = ccnbs.analyze(song)
local events = ccnbs.plan(song, analysis)
ccnbs.play(song, {})                  -- 只传歌曲表 song
```

`decode` **从不抛错**（`nbs.decode.decode` 的冻结契约），错误一律以
`{ok = false, error = {code = ...}}` 返回；`analyze` / `plan` / `play` 接纳的都是**歌曲表**
（`result.song`）。把整个包装表 `result` 直接传给它们会失败，所以**必须先检查 `.ok`**。

`play` 的全部接缝（`speakers` / `clock` / `on_warning` / `on_progress` / `on_event`）
都可注入，因此播放逻辑可被确定性测试。完整说明与可运行示例见
[`docs/API.md`](docs/API.md)。

## 测试

- Tier-1（纯 Lua 单元测试）：`lua tests/run.lua`
- 静态检查（Cobalt 子集）：`lua tests/lint.lua`
- Tier-2（CraftOS-PC 无头集成）：`powershell -File tests/tier2/run.ps1 -Assert`
- Tier-3（真实游戏内验收，由所有者执行）：见 [`docs/UAT.md`](docs/UAT.md)，
  探针脚本为 [`qa/ingame.lua`](qa/ingame.lua)

## 许可证与来源

本项目以 **MIT** 许可证发布，见 [`LICENSE`](LICENSE)。归属信息见 [`NOTICE`](NOTICE)。

**本项目不含任何第三方代码**：全部实现均为从零编写。`NOTICE` 中列出的第三方条目仅
针对测试用的 `.nbs` 样本文件，与运行时无关。本项目与 Open Note Block Studio、
Mojang、Microsoft 及 CC:Tweaked 维护者均无关联。
