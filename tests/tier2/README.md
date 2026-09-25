# Tier-2 集成测试（CraftOS-PC 无头跑真实播放）

本目录是 CCNBSPlayer 的 **Tier-2 集成测试**：在真实的 CraftOS-PC 模拟器里
加载**真实的播放器代码**，对着**真实的 `.nbs` 样本**在**真实的模拟 speaker
外设**上跑一遍，把每一次 `peripheral` 调用记进 `result.txt`，最后用退出码
判定成败。

- `record.lua` —— 在 CraftOS-PC **内部**运行的启动脚本（`--script`）。
- `run.ps1` —— Windows 宿主机上的运行器。
- `README.md` —— 本文档。

---

## 1. 怎么跑

在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1
```

默认使用小样本 `tests/fixtures/v4.nbs`（5 个音符）。可选参数：

```powershell
# 指定其它 fixture（相对仓库根或绝对路径）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 tests/fixtures/new_file.nbs

# 改超时（秒）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -TimeoutSec 180

# 只要求 STATUS ok（-Assert 目前即此含义）
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Assert

# 未来任务用：把记录到的 CALL 序列与期望文件逐行比对
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1 -Assert -ExpectedFile tests/tier2/expected/v4.txt
```

退出码：`0` 仅当一切通过；非 0 为失败（见下节）。最后一行会打印
`=== PASS: ... ===` 或 `=== FAIL: ... ===`。

---

## 2. 四条硬性运行规则（都是踩过坑换来的）

### 2.1 必须用 console 版二进制

- 必须使用 `D:\tools\CraftOS-PC\CraftOS-PC_console.exe`（控制台子系统）。
- **不要**用 `CraftOS-PC.exe`（GUI 子系统版）：它拒绝 `--headless`，会弹出
  一个**模态对话框**并**阻塞进程**，直到有人手动点“确定”。退出码为 5。
- `run.ps1` 里把 console 版路径写死为绝对路径，就是为了避免这个坑。

### 2.2 脚本必须调用 `os.shutdown(N)`

- `record.lua` 的**每一条路径**最后都必须调用 `os.shutdown`：成功 `0`，
  任意失败 `1`。
- 如果没有调用就返回，模拟器会停在交互式 shell 里并**永久挂起**
  （这正是 `run.ps1` 必须设置超时、超时就杀进程的原因）。
- 已实测 `os.shutdown(N)` 会把退出码 `N` 传回宿主机。

### 2.3 绝不截断管道读取 stdout

- **不要**把原生进程的 stdout 管进 `Select-Object -First N` 之类的截断命令：
  提前杀死进程会得到一个**假的 `$LASTEXITCODE = -1`**。
- `run.ps1` 的做法：用 .NET `Process` 重定向 stdout/stderr，异步读到字符串，
  进程结束后再写进临时目录的 `emulator.log`。

### 2.4 绝不解析 stdout

- 无头渲染器输出的是屏幕差分流（启动横幅、"Welcome to CraftOS-PC!" 逐字符
  展开、成百上千个 CR/LF），**无法可靠解析**。
- **结果通道是文件**：`record.lua` 用
  `fs.open("result.txt","w")` 写出。宿主机上它出现在
  `<--directory DIR>\computer\<ID>\result.txt`，内容是干净的 LF。
  `run.ps1` 固定传 `--id 0`，所以路径可预测。

---

## 3. 结果文件格式

`result.txt` 每行一条调用，最后一行是状态：

```
CALL - getNames
CALL back getType
CALL back wrap
CALL back playNote harp 3 12
CALL back playNote harp 3 12
CALL back playNote harp 3 12
CALL back playNote harp 3 12
CALL back playNote harp 3 12
STATUS ok
```

- `CALL <side> <method> <args...>`：`side` 为 `-` 表示该 API 没有方位
  （`getNames`）。数字做了归一化，保证逐字节可复现。
- `STATUS ok` 表示成功；失败时为 `STATUS fail:<原因>`（原因折成一行）。

**拦截点说明**：项目里只有 `player/speaker.lua` 会碰全局 `peripheral`
（`getNames` / `getType` / `wrap`），所以 `record.lua` 把全局替换成代理以
记录这三者；而真正的演奏调用是从 `peripheral.wrap(side)` 返回的**对象**上发出的
（`playNote` / `playSound` / `stop`），因此**同时**包装了那个对象——只包全局会
漏掉所有演奏调用，只包对象会漏掉方位发现信息。CraftOS 的 `peripheral.wrap`
内部会回调全局 `peripheral`（`getMethods`/`getType`/`call`），这些内部调用
会被临时抑制，不会污染记录。

---

## 4. 这个 harness 到底跑了什么

`ccnbs.lua` 与 `player/runtime.lua` / `player/fanout.lua` 等尚未存在，因此
`record.lua` 直接驱动已经冻结的下层模块：

```
nbs.decode -> nbs.analyze -> player.plan -> player.dispatch
```

演奏侧使用 `player/clock` 的**虚拟时钟**喂给 `player/tempo` 调度，再把每个
事件交给 `player.dispatch`，最终落到 `player/speaker` 从真实外设发现的记录上。
虚拟时钟会被**同步推进到最后一拍**，所以整个播放是瞬间完成的，**不会**真实等待
一首歌的时间。虚拟时钟捕获到的回调异常（例如 dispatch 报错）会让本次运行失败。

---

## 5. 已知限制（如实记录，不掩盖）

1. **音频收尾需要一点真实时间。** CraftOS-PC 2.8.3 在还有排队音频时调用
   `os.shutdown` 会以访问违例（`0xC0000005`）崩溃。实测 `playNote` 后立刻
   `os.shutdown` 必崩，而 `playNote` 后空转约 1 秒再关就正常。因此
   `record.lua` 在**所有**路径（成功与失败）关停前都固定 `os.sleep(1.5)`。
   这是固定收尾等待，**不是**等歌曲放完。
2. **模拟 speaker 拒绝负音高。** CraftOS-PC 2.8.3 的模拟 speaker 对
   `playNote` 的负音高会抛 `invalid pitch -1`；而本项目的
   `player/mapping.lua` 出于“扩展音域材质包”的考虑**刻意不夹取**音高。
   因此含超出原生音域音符的样本（例如 `tests/fixtures/simple.nbs`）会在
   模拟器里失败并给出 `STATUS fail:...invalid pitch...`。默认样本
   `v4.nbs` / `new_file.nbs` 都在原生音域内，正常通过。
3. `maxNotesPerTick` 固定为 8（与 CC:T 一致），**不得调高**——调高会掩盖
   “每 tick 音符上限”这一被测特性本身。

---

## 6. 相关命令与约定

```powershell
# Tier-2
powershell -ExecutionPolicy Bypass -File tests/tier2/run.ps1

# 静态检查（tests/tier2/record.lua 也在扫描范围内）
lua tests/lint.lua

# 全量单元测试
lua tests/run.lua
```

`tests/lint.lua` 默认递归扫描 `tests/`，因此 `tests/tier2/record.lua` 会被
Cobalt（Lua 5.2 子集）禁用构造检查覆盖；本文件不得使用 `//`、位运算符、
`utf8.*`、`goto`、`os.exit` 等。
