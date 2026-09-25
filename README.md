# CCNBSPlayer

一个 [CC:Tweaked](https://tweaked.cc/) 音乐播放器：解码
[Note Block Studio](https://noteblock.studio/) 的 `.nbs` 歌曲文件，
并通过游戏内的 `speaker` 外设播放。

> **项目状态：开发中。** 仓库已初始化，实现正在开发。目前尚不可安装使用——
> 播放器完成前，本 README 会持续扩充安装与使用说明。

## 将会实现

- 解码所有已发布的 `.nbs` 格式版本（自 v0 老格式至 v6），涵盖图层、音符
  力度/声像/音高、自定义乐器与循环元数据。
- 通过 `speaker.playNote` / `speaker.playSound` 调度 Minecraft 原生音符盒
  音色来播放，**不打包任何音频采样**，也无需下载音频。
- 加载歌曲时进行分析，并提示无法忠实还原的部分，例如超出原生两个八度的
  音符（需安装扩展音域材质包），或所需扬声器数量多于已挂载数量。
- 当一首歌同一刻的音符数超过单个扬声器上限时，自动把音符分配到多个
  扬声器。

## 不会实现

- 不打包、不播放 PCM/DFPWM 音频采样。
- 不播放 `.nbs` 内自带的自定义乐器。
- v1 不支持跳转进度（seek）与循环播放。
- 不修改 Minecraft、不修改服务端，也不会替你安装材质包。

## 环境要求（计划）

- 一台 CC:Tweaked 电脑，且至少挂载一个 `speaker` 外设。
- 若希望通过 `wget` 安装或更新，需启用 HTTP。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。第三方署名见 [NOTICE](NOTICE)。
