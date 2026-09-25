# Tier-2 集成测试（CraftOS-PC 无头跑真实播放）

本目录是 CCNBSPlayer 的 **Tier-2 集成测试**：在真实的 CraftOS-PC 模拟器里
加载**真实的播放器代码**，对着**真实的 `.nbs` 样本**在**真实的模拟 speaker
外设**上跑一遍，把每一次 `peripheral` 调用记进 `result.txt`，最后用退出码
判定成败。

- `record.lua` —— 在 CraftOS-PC **内部**运行的启动脚本（`--script`）。
- `run.ps1` —— Windows 宿主机上的运行器（普通 / 断言 / 多扬声器）。
- `assert_order.lua` —— 纯 Lua 投影器 + 比较器（不启动模拟器）。
- `assert_spec.lua` —— `assert_order.lua` 的单元测试。
- `failure_spec.lua` —— 失败/边界用例的**投影层**规格（纯 Lua，随全量套件跑）。
- `edge_cases.ps1` —— 失败/边界用例的**模拟器层**规格（宿主驱动）。
- `gen_fixtures.lua` —— 失败/边界 fixture 的确定性生成器。
- `fixtures/` —— 生成出来的失败/边界 fixture（`capacity_10.nbs`、`custom_mix.nbs`）。
- `pitch_probe.lua` —— 独立的音高范围探针（见 `docs/COMPAT.md`）。
- `README.md` —— 本文档。

---

## 1. 怎么跑

在仓库根目录执行：

```powershell
# 普通运行：只要模拟器退出 0 且 result.txt 末行是 STATUS ok
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1

# 指定其它 fixture（相对仓库根或绝对路径）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 tests/fixtures/new_file.nbs

# 改超时（秒）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -TimeoutSec 180

# 断言模式：投影比对 + 确定性复跑（默认 10 次，逐字节一致）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Assert
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Assert -DeterminismRuns 3

# 传统模式：把实录的 CALL 行与一份期望文件逐行比对
# （期望文件可先用 -CaptureResult 生成；仓库当前未提交该文件）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Assert -ExpectedFile <期望文件路径>

# 多扬声器：run.ps1 会把 -SpeakerSides 写进模拟器里的 /speakers.txt，
# record.lua 据此挂载扬声器并调用真实的 player.fanout.assign 分流
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Fixture tests/tier2/fixtures/capacity_10.nbs -SpeakerSides "back,left" -Assert

# 把 result.txt 复制出来（即使本次运行按预期失败也照抄），供规格断言原始文件通道
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Fixture <file> -CaptureResult <path>

# 失败/边界用例的模拟器层规格（跑五个用例并逐条断言）
powershell -ExecutionPolicy Bypass -File tests/tier2/edge_cases.ps1 -DeterminismRuns 2

# 重新生成失败/边界 fixture（确定性，字节可复现）
lua tests/tier2/gen_fixtures.lua
```

最后一行会打印 `=== PASS: ... ===` 或 `=== FAIL: ... ===`。

---

## 2. 运行模式与退出码

### 2.1 四种模式

| 模式 | 命令 | 行为 |
|------|------|------|
| 普通 | `run.ps1` | 单次运行；要求模拟器退出 0 且末行 `STATUS ok` |
| 投影断言 | `run.ps1 -Assert` | 用 `assert_order.lua` 从 fixture 投影出期望的 `CALL` 序列，与实录**逐行精确**比对；再连续跑 `-DeterminismRuns`（默认 10）次，要求每次的 `CALL` 行**逐字节一致**（SHA-256） |
| 确定性复跑 | `run.ps1 -Assert -DeterminismRuns N` | 同上，复跑次数改为 `N` |
| 传统比对 | `run.ps1 -Assert -ExpectedFile <path>` | 单次运行；把实录的 `CALL` 行与一份已存在的期望文件逐行比对（**不做**投影、**不做**确定性复跑） |

> **注意**：`-Assert` **不是**“只要求 STATUS ok”。它做的是投影比对 + 确定性
> 复跑。旧文档里“-Assert 目前即此含义（只要求 STATUS ok）”的说法已经作废。

`-SpeakerSides` 会把边名写进模拟器内的 `/speakers.txt`；投影断言会拿到**同一
组**边名，因此多扬声器 fixture 的“投影 vs 实录”才是同口径比较。

### 2.2 退出码表（`run.ps1`）

| 退出码 | 含义 |
|--------|------|
| 0 | 成功 |
| 1 | harness 内部未预期异常 |
| 2 | fixture 或 console 版二进制找不到 |
| 3 | 超过 `-TimeoutSec` 被杀（**挂起**的信号） |
| 4 | `result.txt` 未写出 |
| 5 | 模拟器退出码非 0 |
| 6 | 缺少 `STATUS ok` |
| 7 | 传统模式：期望文件找不到 |
| 8 | 传统模式：调用数量不一致 |
| 9 | 传统模式：第 N 条调用不一致 |
| 10 | 临时目录未删净 |
| 11 | 仍有 CraftOS 进程存活 |
| 12 | 投影序列与实录不一致 |
| 13 | 找不到 `lua` 解释器或 `assert_order.lua` |
| 14 | 多次运行的 `CALL` 行不是逐字节一致 |

`edge_cases.ps1` 自己的退出码：全部断言通过为 0，否则 1。

---

## 3. 四条硬性运行规则（都是踩过坑换来的）

### 3.1 必须用 console 版二进制

- 必须使用 `D:\tools\CraftOS-PC\CraftOS-PC_console.exe`（控制台子系统）。
- **不要**用 `CraftOS-PC.exe`（GUI 子系统版）：它拒绝 `--headless`，会弹出
  一个**模态对话框**并**阻塞进程**，直到有人手动点“确定”。退出码为 5。
- `run.ps1` 里把 console 版路径写死为绝对路径，就是为了避免这个坑。

### 3.2 脚本必须调用 `os.shutdown(N)`

- `record.lua` 的**每一条路径**最后都必须调用 `os.shutdown`：成功 `0`，
  任意失败 `1`。
- 如果没有调用就返回，模拟器会停在交互式 shell 里并**永久挂起**
  （这正是 `run.ps1` 必须设置超时、超时就杀进程的原因）。
- 已实测 `os.shutdown(N)` 会把退出码 `N` 传回宿主机。

### 3.3 绝不截断管道读取 stdout

- **不要**把原生进程的 stdout 管进 `Select-Object -First N` 之类的截断命令：
  提前杀死进程会得到一个**假的 `$LASTEXITCODE = -1`**。
- `run.ps1` 的做法：用 .NET `Process` 重定向 stdout/stderr，异步读到字符串，
  进程结束后再写进临时目录的 `emulator.log`。

### 3.4 绝不解析 stdout

- 无头渲染器输出的是屏幕差分流（启动横幅、"Welcome to CraftOS-PC!" 逐字符
  展开、成百上千个 CR/LF），**无法可靠解析**。
- **结果通道是文件**：`record.lua` 用
  `fs.open("result.txt","w")` 写出。宿主机上它出现在
  `<--directory DIR>\computer\<ID>\result.txt`，内容是干净的 LF。
  `run.ps1` 固定传 `--id 0`，所以路径可预测。

---

## 4. 结果文件格式

`result.txt` 除调用行外，还有一组**非 CALL** 的汇总行，最后一行是状态。
文件是 **UTF-8**。

```
CALL - getNames
CALL back getType
ASSIGN required=1 found=1 dropped=0 warning=-
SPLIT back 3
CALL back wrap
CALL back playNote harp 3 12
CALL back playNote bass 3 12
WARN[custom-instrument] 本曲含 1 个自定义乐器，已跳过不播放
STATUS ok
```

- `CALL <side> <method> <args...>`：`side` 为 `-` 表示该 API 没有方位
  （`getNames`）。数字做了归一化，保证逐字节可复现。
- `ASSIGN required=<n> found=<n> dropped=<n> warning=<code|->`：`player.fanout.assign`
  的判定。
- `WARGS peak=<n> required=<n> found=<n> dropped=<n>`：仅在有警告时出现，
  是警告器的真实参数。
- `SPLIT <side> <n>`：每个扬声器分到的事件数。
- `DROPPED tick=<n> layer=<n> note=<n> kind=<kind>`：被丢弃的事件，按丢弃顺序。
- `WARN[<code>] <中文说明>`：经 `player/warnings.lua` **每码至多一次**渲染。
- `STATUS ok` 表示成功；失败时为 `STATUS fail:<原因>`（原因折成一行）。

**CALL 行是唯一参与投影比对/确定性哈希的行**；上面这些汇总行会被投影比较器
与宿主断言忽略，只有 `edge_cases.ps1` 会断言它们。

**拦截点说明**：项目里只有 `player/speaker.lua` 会碰全局 `peripheral`
（`getNames` / `getType` / `wrap`），所以 `record.lua` 把全局替换成代理以
记录这三者；而真正的演奏调用是从 `peripheral.wrap(side)` 返回的**对象**上发出的
（`playNote` / `playSound` / `stop`），因此**同时**包装了那个对象——只包全局会
漏掉所有演奏调用，只包对象会漏掉方位发现信息。CraftOS 的 `peripheral.wrap`
内部会回调全局 `peripheral`（`getMethods`/`getType`/`call`），这些内部调用
会被临时抑制，不会污染记录。

---

## 5. 这个 harness 到底跑了什么

`record.lua` 直接驱动已经冻结的下层模块：

```
nbs.decode -> nbs.analyze -> player.plan -> player.fanout.assign
```

- **扬声器**：`run.ps1 -SpeakerSides` 写 `/speakers.txt`；`record.lua` 为每个边
  调用 `periphemu.create(side, "speaker")`，再用 `speaker.discover()` 按**边名
  升序**取得真实记录。文件缺失时回退为单个 `back` 扬声器（旧行为）。
- **分流**：调用真实的 `player.fanout.assign(events, analysis, records)`，再用
  与 `assert_order.lua` **完全相同**的规则（按冻结序逐个事件、用每边的游标做
  同一性匹配）把事件派发给他真正归属的扬声器。因此“丢弃”是**播放器自己的
  决定**，不是模拟器的每 tick 预算拒绝。
- **演奏侧**：`player/clock` 的**虚拟时钟**喂给 `player/tempo` 调度，事件交给
  `player.dispatch`，最终落到 `player/speaker` 从真实外设发现的记录上。虚拟
  时钟会被**同步推进到最后一拍**，整个播放瞬间完成，**不会**真实等待一首歌。
- **警告**：`player/dispatch` 的裸码经 `player/warnings.lua` 渲染，另加分析里
  的 `extended-range`（若命中）与 fanout 的 `speakers`（若命中）。

---

## 6. 断言模式（投影 vs 实录）

`-Assert`（不带 `-ExpectedFile`）会：

1. 用 `assert_order.lua` 投影出期望的 `CALL` 序列。投影用的是**真实生产模块**
   （`nbs.decode / nbs.analyze / player.plan / player.fanout.assign /
   player.dispatch`），路由规则不重写：dispatch 变了，投影跟着变。
2. 与实录**逐行精确**比对（无容差、不允许重排），忽略三条发现行
   （`getNames`/`getType`/`wrap`）。不一致时打印**第一个**不同行。
3. 连续跑 `-DeterminismRuns` 次，要求每次的 `CALL` 行**逐字节一致**（SHA-256）。

因此多扬声器 fixture 必须让 `-SpeakerSides` 与 `assert_order.lua` 收到的边名
一致——`run.ps1` 已经自动这么做。

---

## 7. 已知限制（如实记录，不掩盖）

1. **音频收尾需要一点真实时间。** CraftOS-PC 2.8.3 在还有排队音频时调用
   `os.shutdown` 会以访问违例（`0xC0000005`）崩溃。实测 `playNote` 后立刻
   `os.shutdown` 必崩，而 `playNote` 后空转约 1 秒再关就正常。因此
   `record.lua` 在**所有**路径（成功与失败）关停前都固定 `os.sleep(1.5)`。
   这是固定收尾等待，**不是**等歌曲放完。**不要删除这一行。**
2. **模拟 speaker 只接受 pitch 0..24。** CraftOS-PC 2.8.3 的模拟 speaker 对
   `playNote` 的 pitch 做范围校验：`< 0` 或 `> 24` 一律**抛错**
   `invalid pitch N`（不是返回 false）。而本项目的
   `player/mapping.lua` 出于“扩展音域材质包”的考虑**刻意不夹取**音高，
   `pitch_semitones(key) = key - 33`。因此：
   - 可播放的 key 范围是 **NBS 33..57**（对应 pitch 0..24）；
   - 见 §7.1，含 key < 33 或 > 57 的 fixture **不能**用于模拟器播放断言。
3. `maxNotesPerTick` 固定为 8（与 CC:T 一致），**不得调高**——调高会掩盖
   “每 tick 音符上限”这一被测特性本身。
4. **`result.txt` 必须以 UTF-8 读取。** PowerShell 5.1 的 `Get-Content` 默认用
   ANSI 代码页，会把 `WARN[...]` 里的中文解码错，**并且**一个 GBK 前导字节可能
   吃掉紧随的 `0x0A`，把 `WARN` 行和 `STATUS` 行粘在一起。模拟器写出的字节是
   正确的 UTF-8；宿主必须用 `[System.IO.File]::ReadAllText(path, UTF8)` 读取。
   `run.ps1` 与 `edge_cases.ps1` 已经这样做了。
5. **多扬声器是 task-30 新增的能力。** 旧版 `record.lua` 把所有事件都派给
   `records[1]`（单一扬声器），无法验证分流与丢弃。现在它按
   `player.fanout.assign` 的真实分配派发；单扬声器时行为与旧版一致（因为
   `v4.nbs`/`compat_demo_song.nbs` 的峰值都 ≤ 8，不会丢弃）。

### 7.1 模拟器音高限制：哪些 fixture 不能用于播放断言

CraftOS-PC 2.8.3 的模拟 speaker 对 `playNote` 的音高只在 **0..24** 接受；真实
CC:Tweaked 根本不校验音高（`docs/COMPAT.md` §1–§4 有源码与实测证据）。这是
**模拟器比游戏更严**的模拟器侧分歧。

| fixture | min_key..max_key | 可否用于播放断言 |
|---------|------------------|------------------|
| `v1.nbs`..`v5.nbs`、`new_file.nbs`、`old_new_file.nbs` | 45..45 | ✅ |
| `compat_demo_song.nbs`、`compat_old_demo_song.nbs` | 33..56 | ✅ |
| `tests/tier2/fixtures/capacity_10.nbs` | 45..45 | ✅ |
| `tests/tier2/fixtures/custom_mix.nbs` | 45..45 | ✅ |
| `tests/fixtures/simple.nbs` | 27..46 | ❌（key 27 → pitch −6，模拟器抛错） |

因此 **“扩展音域警告只出现一次”只能在投影层断言**（`simple.nbs` 确实
`has_extended_range == true`，`failure_spec.lua` 覆盖）；模拟器层只能用**在音域
内**的 fixture 断言“**零**条 `WARN[extended-range]`”（`edge_cases.ps1` 的用例 4）。
在模拟器上跑 `simple.nbs` 是**设计上不可能**的，不伪造这一步。

### 7.2 存活进程检查（`run.ps1` 退出码 11 / `edge_cases.ps1` 的 "no surviving CraftOS process"）：存在假失败

每轮跑完，harness 会用 `Get-Process *CraftOS*` 采样，确认没有**残留的模拟器进程**：

- `run.ps1`：主进程退出后先采样一次，然后**最多重试 `5 × 200 ms`（约 1 秒）**再定论，
  仍存活则以**退出码 11** 失败；
- `edge_cases.ps1`：最后一个用例结束后**立即采样一次**（第 234-235 行），**没有**这 1 秒
  宽限窗口，因此最容易踩到 Windows 的进程收尾滞后。

**这个检查是时序敏感的，可能给出假失败。** 已观测到一次
`FAIL no surviving CraftOS process -- survivors=1`：那个 PID 在**不到 4 秒后自行退出**，
且把同一用例**单独重跑 3 次全部通过**。这属于**进程收尾滞后（teardown lag）**，不是真正的
泄漏。

**操作指引**

1. **先重跑一次** `run.ps1` / `edge_cases.ps1` 再判定。偶发的**单个**存活进程通常会在
   第二次消失。
2. 区分二者：
   - **真泄漏**：进程在**很久以后**（例如再等 10 秒）**仍然存活**，或它的临时数据目录
     （`run.ps1` 的 `--directory`）**从未被删除**；
   - **收尾滞后**：只出现**一个**存活进程，且**数秒内自行消失**，重跑即通过。
3. 若反复失败，检查是否有杀不掉的模拟器进程占住了临时目录（`run.ps1` 的退出码 10 表示
   临时目录未删净）。

> **建议（供后续任务，不在本次范围内）**：把 `edge_cases.ps1` 的存活采样也改成带短暂重试 /
> 等待的版本，或在判定存活前先确认该 PID 仍在运行且其临时目录仍在，以消除该假失败。
> 本文档只如实记录时序，**不改动 `run.ps1` / `edge_cases.ps1`**。

---

## 8. 失败/边界用例（task-30）

| 用例 | fixture / 输入 | 断言落点 |
|------|----------------|----------|
| 1 | `fixtures/capacity_10.nbs` + 2 扬声器 | 平衡 5/5、`dropped == 0`（投影 + 模拟器） |
| 2 | `fixtures/capacity_10.nbs` + 1 扬声器 | 丢 2 个、`warning_code == "speakers"`、`warning_args`、丢弃身份（投影 + 模拟器） |
| 3 | `tests/corpus/malformed/*.nbs` | 不崩、`STATUS fail:<类型码>`、退出码非 0、不超时（模拟器；类型码表另在投影层） |
| 4 | `simple.nbs`（投影）/ `compat_demo_song.nbs`（模拟器） | 扩展音域警告恰好一次；在音域内零警告 |
| 5 | `fixtures/custom_mix.nbs` | 自定义音符零调用、恰好一条 `WARN[custom-instrument]`、周围原版音符照常播（投影 + 模拟器） |

- 投影层规格：`failure_spec.lua`（随 `lua tests/run.lua` 跑）。
- 模拟器层规格：`edge_cases.ps1`（退出 0 表示全部通过）。
- fixture 由 `gen_fixtures.lua` 生成，**确定性、字节可复现**。

---

## 9. 相关命令与约定

```powershell
# Tier-2
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1
powershell -ExecutionPolicy Bypass -File tests/tier2/edge_cases.ps1

# 静态检查（tests/tier2/*.lua 也在扫描范围内）
lua tests/lint.lua

# 全量单元测试
lua tests/run.lua
```

`tests/lint.lua` 默认递归扫描 `tests/`，因此 `tests/tier2/` 下的 Lua 文件会被
Cobalt（Lua 5.2 子集）禁用构造检查覆盖；这些文件不得使用 `//`、位运算符、
`utf8.*`、`goto`、`os.exit` 等。
