# 游戏内验收测试（UAT）

> 这是 **Tier-3 验收工件**：它不属于自动化测试门，而是由**项目所有者**在**真实
> Minecraft + CC:Tweaked** 环境里亲自执行的步骤清单。自动化测试（Tier-1 单元测试 +
> Tier-2 CraftOS-PC 无头集成）见 `README.md` 的「测试」一节。
>
> 目标：用不读源码也能照做的步骤，验证「解码 → 分析 → 调度音符 → 扬声器发声」这条
> 真实链路，并覆盖模拟器覆盖不到的两件事：**真实硬件的越界音高**与**扩展音域材质包**。
>
> 日期基准：本文对应版本 `1.0.0`。

---

## 0. 你需要准备什么

| 物品 | 说明 |
|---|---|
| 一台 CC:Tweaked 电脑 | 任意等级（普通 / 高级 / 命令电脑均可） |
| 至少一个 `speaker` 外设 | 贴在电脑任意一侧（如 `back`），用 `peripheral.getNames()` 能看到它 |
| 一个 `.nbs` 歌曲文件 | 放进电脑的当前目录；可先用仓库自带的 `tests/fixtures/` 里的样本 |
| 可选：多个 `speaker` | 用于 §5 的多扬声器步骤 |
| 可选：扩展音域材质包 | 用于 §4；这是社区资源包，由你自行获取，本项目不提供、不自动安装 |

> **关于 HTTP**：只有「一键安装」需要 HTTP。若服务器未启用 HTTP，可改用
> 「手动复制文件」的方式安装（见 `README.md`）。

---

## 1. 安装并自检

### 1.1 一键安装（需要 HTTP）

在电脑的 shell 里输入：

```text
wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
```

**PASS 判据**

- 终端出现中文成功横幅，形如：

  ```text
  ========== CCNBSPlayer 安装完成 ==========
  版本：1.0.0　已安装文件：22
  用法：在 shell 里输入  /lib/ccnbsplayer
  ...
  ==========================================
  ```

- 输入 `ls /lib` 能看到 `ccnbs.lua`、`ccnbsplayer.lua`、`nbs/`、`player/`。

> 若 HTTP 未启用，安装器会打印**中文可操作提示**（告诉你在服务器配置里启用
> `http.enable = true`），而不是抛出原始 traceback。按提示启用后重跑即可。

### 1.2 手动复制（无 HTTP 时）

把仓库里的以下文件按原结构复制到电脑的 `/lib/` 下（共 22 个文件）：

```text
/lib/ccnbs.lua
/lib/ccnbsplayer.lua
/lib/nbs/*.lua        （10 个）
/lib/player/*.lua     （10 个）
```

**PASS 判据**：与 §1.1 相同，`ls /lib` 结构完整。

### 1.3 库加载自检

在 shell 里执行（利用「`require` 相对当前程序目录解析」这一规则，从 `/lib` 里跑）：

```text
/lib/ccnbsplayer
```

应当能进入播放器的歌曲选择界面而**不报 `module not found`**。

**若报错 `module 'ccnbs' not found`**：说明安装布局不对。`require` **没有**固定的
`/lib` 搜索根，它按「正在运行的程序所在目录」解析，所以 `ccnbs.lua` 必须与
`ccnbsplayer.lua` 同处 `/lib`，`nbs/`、`player/` 也必须在 `/lib` 下。

---

## 2. 验收探针：`qa/ingame.lua`

`qa/ingame.lua` 是一个**即拷即用**的验收脚本：它会发现扬声器、读取你指定的 `.nbs`、
解码分析、打印警告、播放，并给出稳定的结果摘要。**它不依赖任何测试脚手架。**

把它复制/粘贴到电脑上（例如 `/ingame.lua`），然后运行：

```text
ingame.lua /我的歌.nbs
```

不带参数运行时会提示你输入 `.nbs` 路径。

**探针的输出形状**

```text
INGAME version=1.0.0
INGAME speakers=1
INGAME file=/我的歌.nbs
INGAME song=<曲名> notes=<音符数> peak=<峰值并发> tick_ms=<节拍毫秒>
INGAME warn=WARN[<code>] <中文说明>   ← 命中一个警告码就一行；没有警告时没有这一行
INGAME status=ok speakers=1 song=<曲名> notes=... events=... warnings=<警告数>
INGAME warncode=<code>                ← 每个警告码再单独一行；没有警告时没有
```

`warnings=` 就是上面 `INGAME warn=`（以及末尾 `INGAME warncode=`）的**条数**，三者必须
自洽：`warnings=0` 时**不出现**任何 `warn=` / `warncode=` 行；一旦出现 `warn=` 行，
`warnings` 必然 `≥ 1`。

例如 §3 用的 `compat_demo_song.nbs`（峰值 `3`、`tick_ms=100`、音符全在原生音域内）
**不产生任何警告**，因此结尾打印 `warnings=0`，且**没有** `INGAME warn=` 行。若换成含
越界音符的 `simple.nbs`，则会多出 `warnings=1` 与一行
`INGAME warn=WARN[extended-range] ...`（见 §4）。

**PASS 判据**

- `INGAME speakers=` 至少为 `1`；
- `INGAME status=ok`；
- `events=` 与 `notes=` 数量一致（没有事件凭空丢失）；
- **自定义乐器音符不会发声（所有平台一致）**：`player/dispatch.lua` 对
  `kind == "custom"` 的事件**不做任何扬声器调用**（`called=false`、`method=nil`），
  只发一次 `WARN[custom-instrument]`。它们**仍会计入** `events=`，但扬声器上听不到——
  这是**预期的拒绝行为**（见 §9）。
- **越界音高的普通音符**在真实硬件上**会发声**（真实 CC:Tweaked 原样接受越界音高，
  音色是否正确取决于扩展音域材质包），见 §4。
  **注意区分**：只有「普通音符越界」会在真机发声；「自定义乐器」无论是否越界都**不发**。

---

## 3. 阶段一：单扬声器、原生音域曲目

**步骤**

1. 选一首**所有音符都落在原生两个八度内**的曲子（NBS key 33..57）。仓库自带的
   `tests/fixtures/compat_demo_song.nbs` 满足此条件。
2. 运行：

   ```text
   ingame.lua /compat_demo_song.nbs
   ```

**PASS 判据**

- 能听到按节拍依次敲出的音符盒音色；
- 终端**没有** `WARN[speakers]`（单扬声器足够）；
- 终端**没有** `WARN[extended-range]`；
- 终端**没有** `WARN[tempo-clamp]`——本曲 `tick_ms=100`（10 tps），本身并不细于
  50 ms 计时粒度（该警告只对自身节拍快于 20 tps 的歌曲发出，见 `README.md` 的
  「警告代码参考」）；
- 最后一行是 `INGAME status=ok`，且其中的 `warnings=0`。

**失败排查**

- 完全没声音：先确认 `peripheral.getNames()` 里真的有 speaker，再确认该扬声器不是
  静音或距离过远（CC:T 扬声器有音量/距离衰减）。
- `INGAME status=no-speaker`：扬声器没接好。

---

## 4. 阶段二：扩展音域（真实硬件 + 材质包）

> 背景与源码证据见 [`docs/COMPAT.md`](COMPAT.md)。一句话结论：真实 CC:Tweaked 的
> `speaker.playNote` **原样接受任意有限音高**（不夹取、不拒绝），因此超出原生两个
> 八度的音符能否听成「正确音高」，取决于客户端安装的**扩展音域材质包**；而
> **CraftOS-PC 模拟器会比游戏更严**，直接对 0..24 之外的音高抛 `invalid pitch`。

**步骤**

1. 选一首**含越界音符**的曲子（`tests/fixtures/simple.nbs` 含 key 27/29/32 等
   低于 33 的音符）。
2. **先不装材质包**运行：

   ```text
   ingame.lua /simple.nbs
   ```

   **PASS 判据（警告出现）**：终端出现一次

   ```text
   WARN[extended-range] 本曲含超出原生两个八度的音符（key ...），需安装扩展音域材质包才能听到完整音色
   ```

3. 在客户端安装社区扩展音域材质包，重启客户端后再运行一次。

   **PASS 判据（音色完整）**：之前「听不到 / 音色不对」的越界音符，现在能听到且音高
   关系正确。

> **重要**：本步骤必须在**真实游戏**里做。在 CraftOS-PC 上跑的自动化集成测试
> **无法**覆盖它——模拟器会对越界音高直接报错，这是模拟器单侧的分歧，不是本项目
> 的缺陷。详见 `docs/COMPAT.md` §6、§7。

---

## 5. 阶段三：多扬声器

**为什么需要多个扬声器**：一个 CC:T 扬声器每个游戏 tick 最多接受 **8 次**
`playNote`；而一次 `playSound`（v6 小号类音色）就独占该 tick。因此当某首歌在
**同一刻**同时发声的音符超过这个上限时，就需要多个扬声器。所需数量由播放器自动
计算并提示。

**步骤**

1. 先只挂 **1 个**扬声器，选一首**峰值并发较高**的曲子运行。
2. 观察终端是否出现形如下面的提示：

   ```text
   WARN[speakers] 本曲峰值 <peak> 音符/50ms，需要 <required> 个扬声器，实际 1 个，已丢弃 <dropped> 个音符
   ```

3. 按提示把扬声器数量增加到 `required` 个，再运行一次。

**PASS 判据**

- 步骤 2：出现 `WARN[speakers]`，且 `需要 N 个扬声器` 是明确的数字；
- 步骤 3：`WARN[speakers]` **消失**，且听感上不再有音符被丢弃。

> 多扬声器同步在 CC:Tweaked 中是「尽力而为」，本项目只保证**分配确定**，不承诺
> 采样级同步。

---

## 6. 阶段四（可选）：交互播放器

用 `/lib/ccnbsplayer` 验证 TUI：

| 操作 | 按键 |
|---|---|
| 上下选择歌曲 | ↑ / ↓ |
| 开始播放选中的歌曲 | Enter / 空格 |
| 暂停 / 继续 | 空格 或 `p` |
| 停止 | `s` 或 `q` |

**PASS 判据**：列表能列出当前目录下的 `.nbs`；选择后开始播放；暂停后音符冻结、
继续后从原处续播；停止后所有扬声器静音。

---

## 7. 结果记录表

| 阶段 | 内容 | 结果 | 备注 / 证据 |
|---|---|---|---|
| 1.1 | 一键安装 | ☐ PASS ☐ FAIL | 成功横幅、`/lib` 文件数 |
| 1.2 | 手动复制 | ☐ PASS ☐ FAIL | |
| 1.3 | 库加载自检 | ☐ PASS ☐ FAIL | |
| 3 | 单扬声器原生音域 | ☐ PASS ☐ FAIL | 是否有 `WARN[speakers]` |
| 4 | 扩展音域 + 材质包 | ☐ PASS ☐ FAIL | 是否出现 `WARN[extended-range]` |
| 5 | 多扬声器 | ☐ PASS ☐ FAIL | `需要 N 个扬声器` 的 N |
| 6 | 交互播放器 | ☐ PASS ☐ FAIL | |

---

## 8. 附：无头验收模式（供自动化使用，不是给人用的）

`qa/ingame.lua` 支持一个**无头模式**，供 CraftOS-PC 之类的测试环境使用：

```text
ingame.lua --harness --result=<结果文件> <歌曲.nbs>
```

- `--harness`：使用**虚拟时钟**让整首歌瞬间跑完，不等待真实时间；
- `--result=<路径>`：把 `INGAME ...` 摘要写入该文件（默认 `ingame.txt`）；
- 结束时调用 `os.shutdown`，好让无头进程退出（并遵守 2.8.3 的音频收尾宽限）。

**正常人类玩家请勿加 `--harness`**——它会关掉电脑。

---

## 9. 非目标（本验收**不**覆盖）

- 不验证音频采样 / DFPWM / PCM 播放——本项目**根本不做**这类播放；
- 不验证自定义乐器播放——本项目**拒绝**播放自定义乐器（会跳过并提示）；
- 不验证跳转进度（seek）与循环播放——**v1 不支持**。
