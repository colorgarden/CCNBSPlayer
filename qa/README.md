# 质量保证（qa）

本目录存放**游戏内验收工件**。它**不属于自动化测试门**（Tier-1 / Tier-2），而是给
项目所有者与人工验收使用的工具。

| 文件 | 用途 |
|---|---|
| `ingame.lua` | 即拷即用的验收探针：发现扬声器 → 读取 `.nbs` → 解码分析 → 打印警告 → 播放 → 输出稳定摘要 |
| [`../docs/UAT.md`](../docs/UAT.md) | 真实游戏内的分阶段验收步骤与 PASS 判据 |

## 人工使用（真实游戏）

把 `ingame.lua` 复制到电脑上，任意位置运行即可（它会自动把 `/lib` 加入模块搜索路径）：

```text
ingame.lua /我的歌.nbs
```

不带参数时会提示输入 `.nbs` 路径。它**不依赖任何测试脚手架**。

## 无头模式（供自动化验证）

```text
ingame.lua --harness --result=<结果文件> <歌曲.nbs>
```

- `--harness`：改用**虚拟时钟**瞬间跑完整首歌；结束时调用 `os.shutdown` 让无头进程退出
  （并遵守 CraftOS-PC 2.8.3 的「关机前 `os.sleep(1.5)`」音频收尾宽限）。
- `--result=<路径>`：把 `INGAME ...` 摘要写入该文件，默认 `ingame.txt`。

**稳定输出形状**（每行以 `INGAME ` 开头，便于 grep）：

```text
INGAME version=1.0.0
INGAME speakers=1
INGAME file=/fixture.nbs
INGAME song=demo notes=76 peak=3 tick_ms=100
INGAME warn=WARN[<code>] <说明>
INGAME status=ok speakers=1 song=demo notes=76 events=76 warnings=1
INGAME status=no-speaker
INGAME status=missing-file path=/nope.nbs
INGAME status=decode-failed error=<code>
```

> `--harness` 会关闭电脑，**仅供无头测试**；真实玩家请勿使用。

## 本地复现（CraftOS-PC 无头）

```powershell
# 1) 准备一个 /lib 已安装布局：<temp>\computer\0\lib\{ccnbs.lua,ccnbsplayer.lua,nbs,player}
#    再把 qa/ingame.lua 放到 <temp>\computer\0\qa\ingame.lua，
#    把样本放到 <temp>\computer\0\fixture.nbs
# 2) 用启动器调用（shell.run 传入参数）：
#    shell.run("/qa/ingame.lua","--harness","--result=ingame_result.txt","/fixture.nbs")
# 3) 读取 <temp>\computer\0\ingame_result.txt
```

播放类断言必须使用**全部落在原生 key 33..57** 的样本：CraftOS-PC 的扬声器对
0..24 之外的音高会抛 `invalid pitch`（见 `../docs/COMPAT.md`）。
`tests/fixtures/compat_demo_song.nbs`（key 33..56）满足条件；`simple.nbs` 不满足。
