# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目简介

Windows PowerShell 5.1 控制台 ASCII 视频播放器 — 将视频帧实时转为字符画播放。

## 常用命令

```powershell
# 播放视频（自动检测帧率、适配窗口）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4"

# 指定帧率播放
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -Fps 15

# 从缓存直接播放（跳过拆帧和转换，缓存不存在则报错）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -Replay

# 强制跳过缓存（始终重新拆帧和转换）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -NoCache

# 仅处理帧不播放（调试用）
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -SkipPlayback

# 保留临时帧文件用于调试
.\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4" -KeepFrames

# 启动 GUI 启动器
.\gui\PlayerGui.ps1

# 运行全部测试
Invoke-Pester .\tests\AsciiVideo.Tests.ps1

# 运行指定测试组
Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -TestName "Get-CacheKey"

# 带详细输出运行测试
Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -Output Detailed
```

## 核心架构：Dot-Source 模块加载

所有 `.ps1` 文件不导出模块，而是通过 **dot-source (`. \path\to\file.ps1`)** 加载，类似于 C 语言的 `#include`。函数被注入到当前脚本作用域，无需 `Import-Module`。

**加载链**：

```
Play-AsciiVideo.ps1
  ├── . .\config.ps1                        # 全局配置变量（$Global:XXX）
  ├── . .\lib\Invoke-FfmpegExtract.ps1       # → Find-FfmpegPath, Invoke-FfmpegExtract, Get-VideoInfo
  ├── . .\lib\ConvertTo-AsciiFrame.ps1       # → ConvertTo-AsciiFrame, ConvertTo-AsciiFrameBatch
  ├── . .\lib\Write-ConsoleFrame.ps1         # → Get-ConsoleCharSize, Initialize-ConsoleForPlayback,
  │                                           #    Start-FramePlayback, Restore-ConsoleState
  └── . .\lib\Save-AsciiCache.ps1            # → Get-CacheKey, Save-AsciiFrameCache, Load-AsciiFrameCache,
                                              #    Test-CacheValid, Clear-ExpiredCache
```

**关键影响**：
- 模块文件中不应有顶层可执行代码，只应定义函数
- `$PSScriptRoot` 在 dot-source 加载的文件中指向该文件自己的目录（不是调用者目录）。例如 `Invoke-FfmpegExtract` 内部 `$PSScriptRoot\temp` 指向 `lib\temp`，实际使用由调用者通过 `-OutputDir` 覆盖
- 测试文件中由于 Pester v6 的 `Invoke-InNewScriptScope` 会隔离 `BeforeAll`/`AfterAll` 作用域，每个 `Describe` 块需在其 `BeforeAll` 中独立 dot-source 所需模块

## 流水线

0. **验证与初始化** — 检查 PS 5.1（非 Core）、ffmpeg 可用性（通过 `Find-FfmpegPath` 自动搜索 winget/Chocolatey/Scoop/`C:\ffmpeg`）、控制台尺寸
1. **视频拆帧** — ffmpeg 按目标帧率 + 控制台尺寸输出 PNG 序列到 `temp/`
2. **ASCII 转换** — LockBits + `Marshal.Copy` 批量读取像素（比 GetPixel 快 ~30-50×），BT.601 灰度计算，预计算的灰度→字符查找表（`byte[256]`）
3. **控制台播放** — `SetCursorPosition(0,0)` + 整帧 `[Console]::Write`（比逐行 Write-Host 快 ~10×）+ `Start-Sleep` 控制帧间隔

### 缓存分支

如果缓存启用（`$Global:CacheEnabled = $true`），在阶段 1 之前插入缓存检查：

```
缓存键 (SHA256) → Test-CacheValid?
  ├── 命中 → Load-AsciiFrameCache (GZip 解压) → 跳过阶段 1+2 → 直接播放
  └── 未命中 → 正常阶段 1+2 → Save-AsciiFrameCache → 播放
```

缓存文件格式（`.cache`）：

```
┌────────────────────────────────┐
│ 4 bytes: JSON 元数据长度 (Big-Endian Int32) │
├────────────────────────────────┤
│ N bytes: JSON 元数据 (UTF-8)              │
├────────────────────────────────┤
│ remaining: GZip 压缩的帧数据              │
│  (帧内用换行符连接，帧之间用双换行符分隔)   │
└────────────────────────────────┘
```

## 关键实现细节

### ffmpeg 自动发现

`Find-FfmpegPath`（被 `Invoke-FfmpegExtract` 和 GUI 公用）先检查 PATH，再搜索常见安装位置（winget glob 匹配 `$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\`、Chocolatey、Scoop、`C:\ffmpeg`），找到后自动加入 `$env:PATH`。因此即使 ffmpeg 未配置系统 PATH，脚本通常也能正常运行。

### Unicode 路径处理

含非 ASCII 字符（中文/日文等）的视频路径会被**自动复制到 `%TEMP%` 的 ASCII 临时路径**，再传给 ffmpeg/ffprobe。原因：ffmpeg 是 C 程序，Windows CRT 将 UTF-16 命令行按 console code page (cp936) 转 ANSI 时会损坏非 ASCII 路径。纯 ASCII 路径直接使用，零拷贝开销。临时副本在 ffmpeg 调用结束后（`finally` 块）自动清理。

### 全局异常捕获

主脚本注册了全局 `trap` 捕获未处理异常。GUI 启动时配合 `Wait-OnGuiError` 暂停等待用户确认，防止错误窗口一闪而过。

### ffprobe 视频信息

`Get-VideoInfo` 优先使用 JSON 输出（`ffprobe -of json`），解析失败时回退到 CSV 模式以兼容旧版 ffmpeg。

### 字符梯度映射

10 级梯度 ` .:-=+*#%@`，灰度 0-255 线性映射。`ConvertTo-AsciiFrame` 通过预计算的 `$charLut[256]` 查找表避免每像素除法计算。

### LockBits 像素读取

`Format32bppArgb` 布局为 B G R A（每像素 4 字节）。**已知 Bug**：目标高度 = 1 时输出被截断（实际使用中不会遇到，测试已改为 Height ≥ 2）。

### 窗口尺寸变更保护

PS 5.1 的 `Write-Progress` 在控制台窗口尺寸变化时触发 `IndexOutOfRangeException`。所有 `Write-Progress` 调用已用 `try/catch` 包裹。播放前显示警告提示用户不要调整窗口。

### 编码: UTF-8 BOM

PowerShell 5.1 **必须**使用 UTF-8 with BOM 编码才能正确处理脚本中的中文字符。写入工具默认不包含 BOM，修改含中文的文件后需运行 `fix_bom.ps1`：

```powershell
.\tests\fix_bom.ps1
```

### MaxFrameCount 的作用域

`$Global:MaxFrameCount`（默认 3000）在多个阶段生效：
- **拆帧阶段**：`ConvertTo-AsciiFrameBatch` 限制处理的帧数，超过上限时截断并警告
- **缓存键计算**：`Get-CacheKey` 将 `MaxFrameCount` 纳入指纹，不同上限产生不同缓存键
- **缓存元数据**：`Save-AsciiFrameCache` 将 `MaxFrameCount` 写入元数据，校验时比对

这意味着修改 `MaxFrameCount` 会使已有缓存失效。

## 辅助文件

| 文件 | 用途 |
|------|------|
| `启动GUI.bat` | 双击启动 GUI（`powershell -File gui\PlayerGui.ps1`） |
| `拖放播放.bat` | 拖放视频到此文件播放（`powershell -File Play-AsciiVideo.ps1 -VideoPath %1`） |
| `tests/syntax_check.ps1` | 检查 GUI 脚本语法（`[PSParser]::Tokenize`），用于快速验证语法正确性 |
| `tests/fix_bom.ps1` | 为所有 `.ps1` 文件添加 UTF-8 BOM |
| `tests/run_tests.ps1` | 从项目根目录运行测试的快捷脚本 |

## GUI 启动器

`gui/PlayerGui.ps1` — WinForms 深色主题窗口：
- 拖放视频文件（或点击选择）
- 可视化调整帧率、输出尺寸、最大帧数、字符梯度（实时预览）
- 缓存/Replay/KeepFrames/Verbose 复选框
- ffmpeg 状态检测（绿/红灯）
- 点击"开始播放"→ `Start-Process` 独立进程运行 `Play-AsciiVideo.ps1`，GUI 最小化等待

### GUI 与播放进程通信

GUI 通过**环境变量**向子进程传递参数，而非命令行参数。原因：Windows 控制台默认 code page (cp936) 下，`Start-Process -ArgumentList` 传递含中文/日文的路径会被 ANSI 转换损坏。.NET 进程环境变量以 UTF-16 存储，跨进程传递完整无损。

环境变量列表：`ASCII_VIDEO_PATH`、`ASCII_VIDEO_FPS`、`ASCII_VIDEO_WIDTH`、`ASCII_VIDEO_HEIGHT`、`ASCII_VIDEO_GRADIENT`、`ASCII_VIDEO_KEEPFRAMES`、`ASCII_VIDEO_VERBOSE`、`ASCII_VIDEO_REPLAY`、`ASCII_VIDEO_NOCACHE`、`ASCII_VIDEO_PAUSE_ON_ERROR`。

播放结束后 GUI 清理所有 `ASCII_VIDEO_*` 环境变量，避免污染后续 PowerShell 会话。

### GUI 错误暂停

GUI 启动时设置 `ASCII_VIDEO_PAUSE_ON_ERROR=true`，主脚本在 `exit 1` 前调用 `Wait-OnGuiError`，提示用户按 Enter 关闭窗口。这防止错误信息一闪而过。命令行直接运行时该机制不激活。

## 测试

Pester 5.4+（测试使用了 `-BeIn`、`-BeOfType` 操作符）。

测试辅助文件：
- `tests/TestHelpers.ps1` — `New-TestImage`、`New-GradientTestImage` 函数（被各 Describe 的 BeforeAll dot-source 加载）
- `tests/fix_bom.ps1` — 为所有 `.ps1` 文件添加 UTF-8 BOM
- `tests/run_tests.ps1` — 从项目根目录运行测试的快捷脚本

Pester v6 兼容性与 Pester 5.x 不同：`$PSScriptRoot` 和 `$MyInvocation` 在 `BeforeAll`/`AfterAll` 中不可用。解决方案是用 `$env:ASCIITEST_ROOT` 环境变量传递项目根路径，每个 `Describe` 块的 `BeforeAll` 中独立 dot-source 所需模块和 `TestHelpers.ps1`。

控制台相关测试（`Get-ConsoleCharSize`）在 headless 环境中自动跳过。

## 依赖

| 依赖 | 要求 | 备注 |
|------|------|------|
| Windows PowerShell | 5.1（非 Core） | 依赖 .NET Framework 的 System.Drawing |
| ffmpeg + ffprobe | 任意版本 | 脚本自动搜索常见安装路径 |
| Pester | 5.4+ | 测试使用了 `-BeIn`/`-BeOfType` 操作符 |

## 配置优先级

命令行参数 > 环境变量（`$env:ASCII_VIDEO_*`）> `config.ps1` 全局变量 > 内置默认值。`config.ps1` 是可选的，缺失时主脚本自动使用内置默认值。

环境变量层主要用于 GUI 启动器向子进程传递参数（见下方"GUI 与播放进程通信"）。

## 编码规范

- UTF-8 BOM 编码（Windows PowerShell 5.1 兼容性要求）
- 函数名 `Verb-Noun`，变量 `camelCase`，参数 `PascalCase`
- 每个 `.ps1` 以 `#Requires -Version 5.1` 开头
- 注释用中文，代码标识符用英文
- 模块文件以 `<# .SYNOPSIS .DESCRIPTION .PARAMETER .EXAMPLE #>` 注释块开头
- 所有路径使用 `Join-Path` 或 `$PSScriptRoot`，禁止硬编码绝对路径

## 已知限制

- 仅 Windows PowerShell 5.1，不支持 PowerShell Core / 跨平台
- 大视频需足够磁盘空间存放临时帧 PNG
- 播放期间改变控制台窗口大小会导致崩溃（PS 5.1 底层 bug，已用 try/catch 缓解 Write-Progress 部分）
- 控制台字符非正方形，画面有轻微拉伸
- `$ColorMode` 配置项存在但未实现（实验性预留）
- LockBits 在目标高度 = 1 时输出截断（不影响实际播放场景）
