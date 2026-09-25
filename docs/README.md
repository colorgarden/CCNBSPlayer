# 文档

本目录存放 CCNBSPlayer 的对外文档，面向使用者与需要排查平台差异的人。

| 文件 | 用途 |
|---|---|
| [`API.md`](API.md) | `ccnbs` 公共 API 参考：`decode` / `analyze` / `plan` / `play`、接缝注入、警告码、返回形状；含可直接运行的示例 |
| [`UAT.md`](UAT.md) | 真实游戏内的分阶段验收步骤与每一步的 PASS 判据（游戏内人工执行，不属于自动化测试） |
| [`COMPAT.md`](COMPAT.md) | 平台兼容性记录：CraftOS-PC 与真实 CC:Tweaked 在扬声器音高、节拍粒度、`-o` 参数等方面的**实测差异**与原始输出 |

入门与安装请看仓库根目录的 [`../README.md`](../README.md)。

> 提示：`COMPAT.md` 记录的是实测结论。若你在真实 CC:Tweaked 上遇到差异，
> 该文件里很可能已经有对应的说明与探测方法。
