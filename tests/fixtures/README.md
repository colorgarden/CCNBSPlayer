# tests/fixtures —— `.nbs` 真实样本语料库

本目录存放 CCNBSPlayer 解码器的**真实 `.nbs` 样本**，覆盖 NBS 格式版本
**v0 到 v6**，以及它们的 golden 数据。目的是让解码器在**真实世界文件**上
得到验证，而不是只靠手工拼字节。

测试规格见 `tests/nbs/fixtures_spec.lua`。测试运行时**完全离线**：所有样本都
已提交进仓库，不会在测试时下载任何东西。

---

## 1. 版本覆盖一览

| 版本 | 代表文件 | 来源 |
|------|----------|------|
| v0（legacy） | `old_new_file.nbs`、`compat_old_demo_song.nbs` | pynbs（上游） |
| v1 | `v1.nbs` | 本地生成 |
| v2 | `v2.nbs` | 本地生成 |
| v3 | `v3.nbs` | 本地生成 |
| v4 | `v4.nbs`、`new_file.nbs`、`compat_demo_song.nbs` | 本地生成 / pynbs（上游） |
| v5 | `v5.nbs` | 本地生成 |
| v6 | `simple.nbs` | nbs.js（上游） |

---

## 2. 上游样本的来源、commit 与许可

两个上游仓库均为 **MIT** 许可。

| 文件名 | 来源仓库 | 仓库内路径 | commit | 许可 | 字节 | 本地 SHA-256 |
|--------|----------|------------|--------|------|------|--------------|
| `compat_old_demo_song.nbs` | `OpenNBS/pynbs` | `tests/resources/compat_old_demo_song.nbs` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 1024 | `32592fb719f771b23dbb5b6a8c67906910832970b0543a2c46b48f4ab7a542a9` |
| `compat_demo_song.nbs` | `OpenNBS/pynbs` | `tests/resources/compat_demo_song.nbs` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 1111 | `d15de57a692d393c0f326acfb2b0b0776587912dc28f86bb8e561d9266ad6223` |
| `song__notes_compat_old_demo_song_nbs__0.txt` | `OpenNBS/pynbs` | `tests/snapshots/song__notes_compat_old_demo_song_nbs__0.txt` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 745 | `e13ae3ae5e5e8e13d4f54a3e950514c3df7f9d5dedbe31a481d9d0c7392afa9b` |
| `song__notes_compat_demo_song_nbs__0.txt` | `OpenNBS/pynbs` | `tests/snapshots/song__notes_compat_demo_song_nbs__0.txt` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 745 | `1ff074e050fc0777a01608daef134cb16d58a228a12559aee66e43204b800e1c` |
| `new_file.nbs` | `OpenNBS/pynbs` | `examples/new_file.nbs` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 133 | `a0e84fff170cce138d308eccd1bd7a7a847f3498732369866e9007b2b7cbb9e5` |
| `old_new_file.nbs` | `OpenNBS/pynbs` | `examples/old_new_file.nbs` | `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` | MIT | 103 | `80318e17f4d780e4de89987eafb7ec669b3dfdfe71f2f10fcb200d478adf5161` |
| `simple.nbs` | `OpenNBS/nbs.js` | `tests/accuracy/samples/simple.nbs` | `c44c59050a3e6895306cc6b985c2b6d6c066e564` | MIT | 876 | `18b0c02f197eaa02fbd3e3f947aedde81a00ea5423b9c2632bf9d67f43cc8920` |

说明：

- pynbs 的提交时间为 2022-04-10；其 `LICENSE` 为 MIT
  （Copyright (c) 2022 Valentin Berlier, Bernardo Costa）。
- nbs.js 的提交时间为 2026-08-06；仓库根没有 `LICENSE` 文件，但
  `package.json` 中声明 `"license": "MIT"`。
- 上述 7 个文件均已用 **git blob SHA-1** 与上游树逐字节比对，全部 **MATCH**
  （校验值与命令见 `.omo/evidence/task-13-ccnbsplayer.txt`）。

下载地址（`<SHA>` 为对应 commit）：

```
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/tests/resources/compat_old_demo_song.nbs
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/tests/resources/compat_demo_song.nbs
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/tests/snapshots/song__notes_compat_old_demo_song_nbs__0.txt
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/tests/snapshots/song__notes_compat_demo_song_nbs__0.txt
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/examples/new_file.nbs
https://raw.githubusercontent.com/OpenNBS/pynbs/<SHA>/examples/old_new_file.nbs
https://raw.githubusercontent.com/OpenNBS/nbs.js/<SHA>/tests/accuracy/samples/simple.nbs
```

### golden 快照（`.txt`）的用法

两个 `song__notes_*.txt` 是 pynbs 自己提交的 golden 快照，内容形如：

```
f.header.song_length = 287
f.header.description = 'This song is use for testing purposes'
len(f.notes) = 76
len(f.layers) = 27
len(f.instruments) = 0
4: [41]
6: [39]
...
```

规格文件**在测试时解析**这些快照（读取 `len(f.notes)` 等行）来得到期望值，
**不硬编码任何记不住的数字**。其中 `f.instruments` 是 pynbs 对**自定义乐器**
的命名，对应解码器的 `song.custom_instruments`。

---

## 3. 本地生成的 v1–v5

**为什么本地生成**：NBS 的 v1、v2、v3、v4、v5 **上游都没有发布任何样本文件**
（pynbs 与 nbs.js 只提供 v0 与 v6 样本）。为了把 v0–v6 的字节布局全部钉死，
缺失的版本用 pynbs 写出。

**生成器**：`tests/fixtures/generate.py`（已提交）。

**解释器**：`C:\Program Files\Python311\python.exe`，pynbs 版本为
`1.0.0-beta.0`。

**重新生成命令**（在仓库根目录执行）：

```
python tests/fixtures/generate.py
# 或显式指定解释器：
"C:\Program Files\Python311\python.exe" tests/fixtures/generate.py
```

生成内容：5 个音符，均在 layer 0、instrument 0、key 45，tick 依次为
`0, 2, 4, 6, 8`；输出具有确定性（相同 pynbs 版本得到逐字节相同的文件）。

**生成结果**：

| 文件名 | 字节 | 本地 SHA-256 |
|--------|------|--------------|
| `v1.nbs` | 112 | `a3d0e8b7d32568a9f4dbbd03902088285e2e9921d803284ec7a58ddef8c5d064` |
| `v2.nbs` | 113 | `0a41dbd2f840f9f66243be7cc1447d69aa1f1b7fc059cd56d5ab52f9d654027d` |
| `v3.nbs` | 115 | `bd79597ee1e6ab3b73ba8b3e2607117e448a51a2895545cabab356ddaff1cd3c` |
| `v4.nbs` | 140 | `b3d52250cd7a2767ed6770ee71762ae25a8fcf68eddb72e2d486ddc81339f1c4` |
| `v5.nbs` | 140 | `fd3599bb8f295d4cc4a7a757b3ea184fdec6bffa79178ea9148265b2fd8883c9` |

### v3/v4/v5 生成时对 `song_length` 的一处刻意后处理

`pynbs` 的 `File.save(path, version=N)` 会调用 `update_header`，写入
`song_length = notes[-1].tick`，即**最后一个 tick 的下标**，比真实 tick 数
（`max_tick + 1`）**少 1**。而本项目解码器采用 “reconstruct-if-shorter”
规则：

```
音符推导长度 > 头里存的长度  ->  song_length_source = "notes"
否则                        ->  song_length_source = "header"
```

若使用 pynbs 的默认（少 1）值，**任何非空的 v3+ 歌曲**（无论本地生成还是
上游真实样本）都会落入 `"notes"` 分支，v3 要求的
`song_length_source == "header"` 将**永远无法被验证**。因此生成器在 v3+ 上
把 `song_length` 两字节改写成真实 tick 数（`9`）；文件其余部分与 pynbs 输出
逐字节一致。生成器源码中有同样的注释。

---

## 4. 已知偏差与上游事实（重要）

写规格时**先运行、再断言真实观测值**，以下是观测到的、与任务书描述不一致的
地方：

1. **`examples/new_file.nbs` 实际是 v4，不是 v5。**
   任务书称它是 “133 字节、v5”。该文件在 commit
   `bd39731f25c8b4d56ad8b50c25e978f82a5cea98` 下的首 8 字节为
   `00 00 04 10 08 00 01 00`：`00 00` 表示新格式，紧随的版本字节是
   **`04`**，即 **v4**。因此 v5 的覆盖改由本地生成的 `v5.nbs` 承担。
   （`new_file.nbs` 仍作为“最小对照”之一保留：它是新格式的最小文件，
   `old_new_file.nbs` 是 legacy 最小文件。）

2. **`simple.nbs` 的有效长度是 63，不是 62。**
   nbs.js 文档写 “size = 62”，文件里**存储的** `header.song_length` 确实是
   `62`；但磁盘上的音符最大 tick 也是 62，解码器按 reconstruct-if-shorter
   得到**有效长度 63**。规格同时断言 `header.song_length == 62`（存储值）
   与 `song.song_length == 63`（有效值），并把该差异记录在案，而不是把断言
   硬拗成 62。

3. **pynbs 实际安装版本是 `1.0.0-beta.0`，不是任务书说的 `1.1.0`。**
   其 `CURRENT_NBS_VERSION = 5`。

4. **`default_instruments`（vanilla_instrument_count）**：本地生成的 v1–v5
   写入了 pynbs 默认值 `16`；v6 的 `simple.nbs` 观测到的是 `0x14 = 20`；
   v0 legacy 按格式恒为 `10`。

---

## 5. 目录内文件清单

| 文件 | 说明 |
|------|------|
| `compat_old_demo_song.nbs` | 上游真实 v0 样本（golden 由同名 `.txt` 提供） |
| `compat_demo_song.nbs` | 上游真实 v4 样本（golden 由同名 `.txt` 提供） |
| `song__notes_compat_old_demo_song_nbs__0.txt` | 上面的 golden 快照 |
| `song__notes_compat_demo_song_nbs__0.txt` | 上面的 golden 快照 |
| `new_file.nbs` | 上游“最小新格式”文件（实为 v4） |
| `old_new_file.nbs` | 上游“最小 legacy”文件（v0） |
| `simple.nbs` | 上游 nbs.js v6 样本 |
| `v1.nbs` … `v5.nbs` | 本地生成的缺失版本 |
| `generate.py` | v1–v5 的确定性生成器 |
| `README.md` | 本文件 |

---

## 6. 维护约定

- 本目录在 `tests/lint.lua` 中**整目录跳过**（`/tests/fixtures/` 位于
  `SKIP_DIRS`），因此 `generate.py` 不会被 Cobalt 禁止构造检查扫描。
- 这些样本在测试中是**只读、固定**的输入。若确需更新，请同时更新本文件的
  commit / 哈希与规格中的期望值。
- 不要在此目录放置期望被 lint 的 Lua 源码。
