# CCNBSPlayer

在 [CC:Tweaked](https://tweaked.cc/) 电脑上播放 Note Block Studio `.nbs` 歌曲文件的音乐
播放器。它读取 `.nbs` 乐谱，解码、分析、编排，再通过游戏内的 `speaker` 外设**调度音符**
发声。本项目**不打包、也不下载任何音频采样**，声音完全由 Minecraft 自己合成。

> 当前版本：`1.0.0`。

## 这是什么

- 解码已发布的 `.nbs` 格式（v0 老格式到 v6）：图层、音符力度/声像/音高、自定义乐器与
  循环元数据。
- 加载歌曲时做分析：总音符数、峰值并发、是否需要扩展音域、需要几个扬声器。
- 把乐谱编排成一条**确定的全序事件流**，按节拍调度到扬声器上，调用
  `speaker.playNote`（普通音符盒音色）与 `speaker.playSound`（v6 小号类音色）。
- 当一首歌同一时刻的音符数超过单扬声器上限时，自动把音符**分配到多个扬声器**，并在数量
  不足时提示需要几个。

**一句话**：它是「音符调度器」，不是「音频播放器」。声音由 Minecraft 自己合成，本项目
只负责在正确的时刻敲下正确的音符。

## 环境要求

- 一台 CC:Tweaked 电脑，且**至少连接一个 `speaker` 外设**（贴在电脑任意一侧，用
  `peripheral.getNames()` 能看到它）。
- 使用「一键安装」时需要 **HTTP**。好消息是：**两个平台的 HTTP 默认都是开启的**，因此
  绝大多数用户**无需做任何事**：
  - **CraftOS-PC 模拟器**：开关是模拟器自己的配置文件 `config/global.json`（位于
    CraftOS-PC 的**用户数据目录**中）里的 `http_enable` 键，默认 `true`。
  - **真实 CC:Tweaked 服务器**：开关是服务器配置 `computercraft-server.toml` 里的
    `http.enabled`，默认 `true`。

若 HTTP 被人为关闭，`wget` 会先失败，安装器也会给出**明确的中文提示**。此时请**直接编辑
上述配置文件**并**重启**模拟器 / 服务器，然后再重试。

> 注意：实测本项目使用的 CraftOS-PC 2.8.3 构建**会忽略 `-o` / `--option` 启动参数**
> （实测 `-o maxNotesPerTick=...` 与 `--option` 两种写法均不生效），所以**不要**指望用
> `-o http_enable=true` 打开 HTTP。那条路走不通，**只有改配置文件并重启才有效**。

## 安装

### 方式一：一键安装（推荐）

在电脑的 shell 里运行：

```text
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
```

安装器会把运行所需的全部文件下载并放到 `/lib/` 下。成功后终端会打印一段中文横幅，并告诉
你用法。安装器是**幂等**的：重复运行会干净地覆盖旧文件，不会破坏既有安装。

### 网络不好 / `raw.githubusercontent.com` 连不上（镜像源）

安装器**默认会自动切换镜像源**，你什么都不用做。它按顺序尝试以下来源，**用第一个能答上
的来源完成整次安装**（不会东拼一点西拼一点）：

| 顺序 | 名称 | 地址 |
|---|---|---|
| 1 | `github` | `raw.githubusercontent.com`（官方，**始终最先尝试**） |
| 2 | `ghproxy` | `ghproxy.net` |
| 3 | `ghfast` | `ghfast.top` |
| 4 | `gh-proxy` | `gh-proxy.com` |
| 5 | `hkproxy` | `hk.gh-proxy.com` |
| 6 | `llkk` | `gh.llkk.cc` |
| 7 | `jsdelivr` | `cdn.jsdelivr.net`（**放最后，因为它有缓存**） |

能直连 GitHub 的机器**行为和以前完全一样**，永远用不到镜像，因为官方地址排第一。

**为什么 jsDelivr 排最后**：它是唯一**会缓存**的来源——按分支缓存，可能长达数小时。刚推
的提交在它上面可能还看不到，过期的清单会让你装到旧文件列表，所以只当最后手段。

需要手动控制时：

```text
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua --list-mirrors
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua --mirror ghfast
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua --mirror https://自定义镜像/前缀
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua --no-mirror
```

| 参数 | 作用 |
|---|---|
| `--list-mirrors` | 列出所有可用来源后退出，不做安装 |
| `--mirror <名称>` | **只用**该来源，不再自动回退 |
| `--mirror <地址>` | 只用该地址（同样不回退） |
| `--no-mirror` | 只用 GitHub 官方地址，完全不碰镜像 |

> `--mirror` 是「只用它」而不是「优先它」：指定后若该来源不通，会直接失败而不会偷偷换源，
> 这样你才能确定文件到底从哪来。

### 方式二：手动复制（无 HTTP 时）

把仓库里这些文件按原目录结构复制到电脑的 `/lib/`：

```text
/lib/ccnbs.lua            （库入口）
/lib/ccnbsplayer.lua      （交互播放器）
/lib/updater.lua          （更新器）
/lib/nbs/*.lua            （10 个解码/分析模块）
/lib/player/*.lua         （9 个运行时模块）
/lib/net/*.lua            （3 个网络模块）
/lib/ui/*.lua             （4 个界面模块）
/lib/vendor/*.lua         （2 个第三方库，见「许可证」）
```

共 31 个文件。复制完成后即可直接使用。

> `vendor/` 里是随仓库分发的第三方库（Basalt 2 与 utf8display），**必须一起复制**，否则
> 播放器无法启动。字体**不在**其中，由程序在运行时自行下载（见下文「中文显示」）。

### 安装位置与 `require` 解析规则（重要）

安装根目录是 **`/lib/`**。请务必理解这条规则，否则会踩到 `module not found`：

- CC:Tweaked 的 `require` **没有**一个固定的 `/lib` 搜索根。它的 `package.path` 是
  `?;?.lua;?/init.lua;/rom/modules/main/?;...`，其中 `?` 模式会**相对于「正在运行的程序
  所在目录」**解析。
- 因此 `/lib/` 之所以可用，是因为**整棵运行时都在 `/lib` 下，且入口程序
  `ccnbsplayer.lua` 也在 `/lib` 下**。当你运行 `/lib/ccnbsplayer` 时，它的目录是
  `/lib`，于是 `require("ccnbs")` 找到 `/lib/ccnbs.lua`，`require("nbs.decode")` 找到
  `/lib/nbs/decode.lua`。
- 这也正是仓库根目录那个 `ccnbs.lua` 必须与 `ccnbsplayer.lua` 放在**同一个目录**的原因
  （安装后即都在 `/lib`）。
- 若你在**别处**写自己的脚本要用这个库，请显式把 `/lib` 加进搜索路径：

  ```lua
  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
  local ccnbs = require("ccnbs")
  ```

## 使用

### 运行播放器

安装后，在 shell 里输入：

```text
lib/ccnbsplayer
```

也可以先 `cd lib` 再输入 `ccnbsplayer`。

### 歌曲文件放哪里

把 `.nbs` 文件放到播放器的**当前工作目录**（例如默认的 `/`，或你 `cd` 进去的目录）。
播放器只在**当前目录**里找 `.nbs`，不会递归子目录。

### 更新

装上以后再想更新，运行**更新器**即可，不需要再记 `wget` 地址：

```text
/lib/updater
```

它会读取本机已安装的版本、从仓库读取版本，**只有仓库更新时才重新安装**；已经是最新则什么都
不做，也**不会下载任何文件**。更新器完全复用安装器的逻辑（同一份镜像链、同一份清单、同一
个写入器），因此「更新」和「安装」不可能得出不同结果。

```text
/lib/updater --check          # 只报告有没有新版本，不做任何改动
/lib/updater --mirror ghfast  # 只用一个来源
/lib/updater --no-mirror      # 只用 GitHub 官方地址
/lib/updater --list-mirrors   # 列出可用来源
```

版本号只有**一个来源**：`installer.lua` 里的 `installer.VERSION`。更新器是去抓**远端
`installer.lua` 源码**并把这一行解析出来比较的，而不是另外维护一个 `version` 文件——多一个
版本文件就多一处会过期的地方，而过期的版本号会让更新器自信地给出错误结论。测试里有一条断言
专门锁住这件事：解析安装在机器上的 `installer.lua` 得到的版本，必须等于它自己报告的版本。

版本比较是**按数字**而不是按字符串，所以 `1.10.0` 正确地**新于** `1.9.0`。如果你装的是比仓
库**更超前**的本地/开发构建，更新器会识别出来并**拒绝降级**，什么都不改。

### 传输键

启动后播放器会列出当前目录下的歌曲：

| 操作 | 按键 |
|---|---|
| 上一首 / 下一首 | ↑ / ← / ↓ / → |
| 载入选中的歌曲 | `Enter` |
| 播放 / 暂停 / 继续 | 空格 或 `p` |
| 停止 | `s` 或 `q` |
| 切换中/英文界面 | `l` |
| 退出播放器 | `Esc` |

> v1 **不支持**跳转进度（seek）与循环播放。

### 界面与中文显示

界面基于 **Basalt 2**（随仓库分发，见 [`vendor/`](vendor/)）。Basalt 的文字元素**无法显示
中文**——它用的是 CC 自带终端字体，没有中文字形。所以中文是这样显示出来的：用 `ui/cjk.lua`
把文字转成像素点阵（bimg），再喂给 Basalt 的图像元素。

这意味着**中文需要一份 CJK 像素字体**，而这份字体：

- **不随仓库分发**，由 `ui/cjk.lua` 在**运行时下载**到你的电脑上；
- 默认用 **8px** 字体（1,681,325 字节，约占 6 MB 内存），因为它比 12px 小一半以上；
- **默认每次启动都会重新下载**。原因是 CC:Tweaked 电脑默认磁盘上限是 **1,000,000 字节**，
  而 8px 字体就有 1.68 MB，**装不下**，所以缓存写入会失败。

程序会**先尝试缓存**，缓存失败**不影响使用**（只是下次启动要重下），并且会在界面里告诉你
当前是不是走的缓存。

**想避免每次重下**：把服务器的 `computer_space_limit` 调大到 2 MB 以上，字体就能被缓存下来，
之后启动不再下载。这是可选的优化，不做也完全能用。

**拿不到字体时**：界面**自动退回 ASCII/英文**，程序照常可用——中文失败只让你损失中文，不会
让你用不了程序。

### 扬声器数量要求

**同时发声的音符越多，需要的扬声器越多。** 一个 CC:T 扬声器每个游戏 tick 最多接受
**8 次** `playNote`；一次 `playSound`（v6 小号类音色）则独占一整个 tick。播放器会在
加载时算出所需数量，不足时给出形如下面的提示：

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

播放器**不会夹取**音高：超出原生范围的音符会**原样**送进扬声器。真实 CC:Tweaked 会原样
接受这些音高（最终音色取决于客户端安装的扩展音域材质包），所以此时需要**自行安装社区
提供的扩展音域材质包**才能听到完整音色。本项目不提供、也不自动安装材质包。

一个必须知道的行为差异：**CraftOS-PC 模拟器比游戏更严**，会对 0..24 之外的音高直接报错。
这是「模拟器比游戏更严」的单侧分歧，不是项目缺陷。

## 警告代码参考

所有警告都用同一种**机器可识别标记**呈现：`WARN[<code>] <中文说明>`，由
`player/warnings.lua` 渲染；交互播放器会把它打印出来。库入口 `ccnbs` 只把**裸代码**交给
`opts.on_warning(code, args)`，自己不打印。**每个代码在一首歌里至多出现一次。**

| 代码 | 触发时机 | 含义（`args`） | 你该怎么办 |
|---|---|---|---|
| `WARN[speakers]` | 播放开始时（由扇出分配决定） | 本曲峰值并发超过现有扬声器能承载的量，部分音符被丢弃。`{peak, required, found, dropped}` | 把扬声器增加到 `required` 个 |
| `WARN[extended-range]` | 播放开始时（加载期属性，不是播放中途） | 曲中含原生两个八度（key `33..57`）之外的音符。`{min_key, max_key}` | 自行安装社区扩展音域材质包；真实 CC:Tweaked 会原样接受越界音高 |
| `WARN[custom-instrument]` | 播放结束或取消时汇总 | 曲中含 `.nbs` 自定义乐器；这些音符**被拒绝播放并跳过**（没有任何扬声器调用）。`{count}` | 无需操作；**自定义乐器不会发声**，属预期行为 |
| `WARN[play-sound-pitch]` | 播放到对应音符时 | v6 小号类音色（`speaker.playSound`）的音高超出可表示范围（0.5..2.0），被夹取为近似值 | 接受近似音高；属已知限制 |
| `WARN[tempo-clamp]` | **歌曲自身的节拍**细于 50 ms 计时粒度时，一次性 | 曲目的 tick 间隔本身比 CC:Tweaked 计时器的 0.05 s（50 ms）粒度更细 | 接受轻微的节拍量化；属已知限制 |

> `WARN[tempo-clamp]` 只描述**歌曲自身节拍**快于 20 tps（即 `tick_ms < 50`）的情况，
> **不是**给和弦或第一拍发的。普通的同刻音符（和弦）与第一拍都不会触发它。

## 明确不做的事

- **不打包、不播放音频采样**，不使用 DFPWM / PCM 之类的音频接口。本项目只调度音符调用，
  声音由 Minecraft 合成。
- **不播放自定义乐器**（`.nbs` 内自带的自定义乐器）。遇到时跳过并一次性提示。
- **v1 不支持**跳转进度（seek）与循环播放。
- 不修改 Minecraft、不修改服务端，也不会替你安装材质包。

## 库 API

除了交互播放器，本项目还提供一个可 `require` 的库入口，位于**项目根目录** `ccnbs.lua`
（不是 `nbs/init.lua`）：

```lua
local ccnbs = require("ccnbs")        -- 需先把 /lib 加进 package.path，见上文

ccnbs.version                         -- "1.0.0"
ccnbs.decode(bytes)                   -- 解码：返回「包装表」，不是歌曲本身（见下）
ccnbs.analyze(song)                   -- 分析
ccnbs.plan(song, analysis)            -- 编排为有序事件数组
ccnbs.discover_speakers()             -- 已挂载的扬声器
ccnbs.play(song|plan, opts)           -- 播放：立即返回，不阻塞；可传歌曲表或事件数组
```

**`decode` 返回的是一个「包装表」，不是歌曲本身**。请先判断 `.ok`，再取 `.song`：

```lua
local ccnbs = require("ccnbs")

-- 把 "my_song.nbs" 替换成你自己的歌曲文件
local file = io.open("my_song.nbs", "rb")
if file == nil then
  print("未找到 my_song.nbs，请替换成你自己的歌曲文件后再运行本示例。")
  return
end
local bytes = file:read("*a")
file:close()

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

`play` 的**第一个参数既可以是一首歌，也可以是一份已编排好的计划**（`ccnbs.plan` 返回的
事件数组）。传计划时还必须再传 `opts.analysis`（即 `ccnbs.analyze(song)`），否则会抛出
类型化错误 `E_PLAN_REQUIRES_ANALYSIS`：

```lua
-- song 为上一示例中解码得到的歌曲表
local analysis = ccnbs.analyze(song)
local events = ccnbs.plan(song, analysis)
ccnbs.play(events, { analysis = analysis })   -- 播放已编排好的计划
```

`decode` **从不抛错**，错误一律以 `{ok = false, error = {code = ...}}` 返回。`analyze` /
`plan` / `play` 接纳的都是**歌曲表**（`result.song`），把整个包装表 `result` 直接传给它们
会失败，所以**必须先检查 `.ok`**。完整说明与可运行示例见 [`docs/API.md`](docs/API.md)。

## 许可证

本项目以 **GNU 通用公共许可证第 2 版（GPL-2.0）** 发布，完整条款见
[`LICENSE`](LICENSE)。第三方组件及其归属信息见 [`NOTICE`](NOTICE)。

**本项目包含第三方代码。** 用户界面基于 **Basalt 2**（MIT），中文渲染使用
**utf8display**（自身未声明许可证，经 **MPlayer**（GPL-2.0）分发），两者都**随仓库
分发**在 [`vendor/`](vendor/) 目录下，来源、固定版本与重新构建方法见
[`vendor/README.md`](vendor/README.md)。之所以是随仓库分发而非运行时下载，是因为 Basalt
内部模块之间用 `require` 互相引用，散放文件时无法解析。

**字体不属于仓库内容**：CJK 像素字体由 `ui/cjk.lua` 在运行时下载到用户的电脑上（原因见
下文「中文显示」），这与 MPlayer 的做法一致。

`.nbs` 测试素材属于各自独立的第三方作品，仍按其原有许可证（MIT）授权，不适用本项目的
GPL-2.0；它们不随仓库分发。
