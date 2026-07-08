# PowerShell ASCII 视频播放器

Windows PowerShell 5.1 控制台 ASCII 视频播放器 —— 将视频帧实时转换为字符画并播放。

## 功能特性

- **GUI 图形界面**：拖放视频、可视化调整参数、一键播放
- **命令行播放**：支持丰富的参数和缓存控制
- **自动帧率检测**：未指定帧率时自动读取视频原始帧率
- **自动搜索 ffmpeg**：即使 ffmpeg 未加入系统 PATH，也会自动搜索常见安装位置
- **帧缓存机制**：相同参数二次播放时跳过拆帧和转换，大幅提升启动速度
- **Unicode 路径支持**：中文、日文等特殊路径通过临时 ASCII 副本机制正常处理
- **多种快捷启动**：提供 `.bat` 文件，双击或拖放即可启动

## 系统要求

| 依赖                 | 要求          | 备注                                 |
| ------------------ | ----------- | ---------------------------------- |
| Windows PowerShell | 5.1（非 Core） | 依赖 .NET Framework 的 System.Drawing |
| ffmpeg + ffprobe   | 任意版本        | 脚本会自动搜索常见安装路径                      |
| .NET Framework     | 4.0+        | 用于 System.Drawing 图像处理             |

## 安装

1. 下载或克隆本项目到本地目录。
2. 安装 ffmpeg（任选一种）：
   - `winget install ffmpeg`
   - `choco install ffmpeg`
   - `scoop install ffmpeg`
   - 或从 [ffmpeg.org](https://ffmpeg.org/download.html) 手动下载并解压到 `C:\ffmpeg`
3. 确认 PowerShell 执行策略允许运行脚本（必要时以管理员运行）：
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## 使用方式

### 方式一：GUI 启动器（推荐）

双击项目根目录的 [`启动GUI.bat`](启动GUI.bat)，打开图形界面：

1. 拖放视频文件到窗口，或点击选择文件
2. 调整帧率、输出尺寸、字符梯度等参数
3. 点击「开始播放」

### 方式二：拖放播放

把任意视频文件拖到 [`拖放播放.bat`](拖放播放.bat) 上松手，即可按默认参数播放。

### 方式三：命令行

```powershell
# 使用默认参数播放
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4"

# 指定帧率
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -Fps 15

# 指定输出尺寸
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -Width 160 -Height 45

# 使用自定义字符梯度（左暗右亮）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -CharGradient "@%#*+=-:. "

# 仅处理不播放（调试用）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -SkipPlayback

# 从缓存直接播放（需之前已生成缓存）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -Replay

# 强制重新处理，不使用缓存
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -NoCache
```

## 命令行参数

| 参数              | 类型     | 说明                       | 默认值            |
| --------------- | ------ | ------------------------ | -------------- |
| `-VideoPath`    | string | 输入视频文件路径                 | 必填             |
| `-Fps`          | int    | 目标播放帧率，`0` = 自动检测        | `0`            |
| `-Width`        | int    | 输出字符宽度，`0` = 自动（控制台宽度）   | `0`            |
| `-Height`       | int    | 输出字符高度，`0` = 自动（控制台高度-2） | `0`            |
| `-CharGradient` | string | 字符梯度串，从左到右表示从暗到亮         | `" .:-=+*#%@"` |
| `-KeepFrames`   | switch | 保留临时 PNG 帧文件             | 否              |
| `-SkipPlayback` | switch | 仅提取并转换帧，不播放              | 否              |
| `-Replay`       | switch | 从缓存直接播放，跳过拆帧和转换          | 否              |
| `-NoCache`      | switch | 强制跳过缓存，重新拆帧转换            | 否              |
| `-PassThru`     | switch | 显示 ffmpeg 详细输出           | 否              |
| `-CacheDir`     | string | 自定义缓存目录                  | 见 `config.ps1` |

## 配置文件

所有默认参数集中在 [`config.ps1`](config.ps1) 中管理。修改后无需改动主脚本即可生效。

| 配置项                             | 说明                 | 默认值                     |
| ------------------------------- | ------------------ | ----------------------- |
| `$Global:CharGradient`          | 字符梯度               | `" .:-=+*#%@"`          |
| `$Global:TargetFps`             | 默认目标帧率             | `0`（自动）                 |
| `$Global:MaxFrameWidth`         | 默认输出宽度             | `0`（自动）                 |
| `$Global:MaxFrameHeight`        | 默认输出高度             | `0`（自动）                 |
| `$Global:MaxFrameCount`         | 最大处理帧数，防止长视频占用过多内存 | `3000`                  |
| `$Global:TempDir`               | 临时帧图片目录            | `"$PSScriptRoot\temp"`  |
| `$Global:KeepFrames`            | 是否保留临时帧            | `$false`                |
| `$Global:HideCursor`            | 播放时是否隐藏控制台光标       | `$true`                 |
| `$Global:ClearScreenBeforePlay` | 播放前是否清屏            | `$true`                 |
| `$Global:CacheEnabled`          | 是否启用帧缓存            | `$true`                 |
| `$Global:CacheDir`              | 缓存文件目录             | `"$PSScriptRoot\cache"` |
| `$Global:CacheExpireDays`       | 缓存过期天数，`0` 表示永不过期  | `30`                    |
| `$Global:ColorMode`             | 实验性彩色输出（未完全实现）     | `$false`                |

**配置优先级**：命令行参数 > `config.ps1` 全局变量 > 内置默认值。

## 缓存机制

启用缓存后，首次播放会生成 `.cache` 文件。二次播放时，如果以下参数完全一致，则直接加载缓存，跳过 ffmpeg 拆帧和 ASCII 转换：

- 视频文件路径
- 输出宽度 / 高度
- 目标帧率
- 字符梯度
- 最大帧数

缓存文件位于 `cache/` 目录，每次播放时会自动清理超过 `CacheExpireDays` 天的过期缓存。

## 目录结构

```
PowerShell-ASCII-Video-Player/
├── Play-AsciiVideo.ps1      # 主播放脚本
├── config.ps1               # 默认配置
├── 启动GUI.bat              # 双击启动 GUI
├── 拖放播放.bat             # 拖放视频到此文件播放
├── gui/
│   └── PlayerGui.ps1        # WinForms GUI 启动器
├── lib/
│   ├── Invoke-FfmpegExtract.ps1   # ffmpeg 拆帧与自动发现
│   ├── ConvertTo-AsciiFrame.ps1   # 图片转 ASCII
│   ├── Write-ConsoleFrame.ps1     # 控制台输出与播放控制
│   └── Save-AsciiCache.ps1        # 缓存读写
├── tests/
│   ├── AsciiVideo.Tests.ps1 # Pester 单元测试
│   ├── TestHelpers.ps1      # 测试辅助函数
│   ├── fix_bom.ps1          # UTF-8 BOM 修复工具
│   ├── run_tests.ps1        # 测试运行脚本
│   └── syntax_check.ps1     # 语法检查脚本
├── cache/                   # 帧缓存目录（自动生成，已忽略）
└── temp/                    # 临时帧目录（自动生成，已忽略）
```

<br />

## 测试

项目使用 Pester 5.4+ 进行单元测试：

```powershell
# 运行全部测试
Invoke-Pester .\tests\AsciiVideo.Tests.ps1

# 详细输出
Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -Output Detailed

# 运行指定测试组
Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -TestName "Get-CacheKey"
```

## 注意事项

- **仅支持 Windows PowerShell 5.1**，不支持 PowerShell Core / 跨平台。
- **播放过程中请勿调整控制台窗口大小**，否则可能触发 PowerShell 5.1 底层异常导致崩溃。
- 控制台字符并非正方形，画面会有轻微拉伸，属于正常现象。
- 大视频处理需要足够的磁盘空间存放临时 PNG 帧文件。
- 含中文、日文等 Unicode 字符的视频路径会自动复制到 `%TEMP%` 的 ASCII 临时路径再交给 ffmpeg，处理结束后自动清理。
- `$Global:ColorMode` 为实验性预留配置，当前未实现彩色输出。

