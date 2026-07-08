#Requires -Version 5.1

<#
.SYNOPSIS
    PowerShell ASCII 视频播放器

.DESCRIPTION
    在 Windows PowerShell 5.1 控制台中将视频文件实时转换为 ASCII 字符画并播放。
    工作流程：ffmpeg 拆帧 → 图片转 ASCII → 控制台播放。

.PARAMETER VideoPath
    （必填）输入视频文件路径。

.PARAMETER Fps
    目标播放帧率，0 表示自动检测视频原始帧率。默认从 config.ps1 读取。

.PARAMETER Width
    输出字符宽度，0 表示使用控制台窗口宽度。默认从 config.ps1 读取。

.PARAMETER Height
    输出字符高度，0 表示使用控制台窗口高度。默认从 config.ps1 读取。

.PARAMETER CharGradient
    字符梯度串（左暗右亮）。默认从 config.ps1 读取。

.PARAMETER KeepFrames
    保留临时帧文件（调试用）。默认从 config.ps1 读取。

.PARAMETER SkipPlayback
    仅提取帧并转换，不播放（调试用）。

.PARAMETER PassThru
    显示 ffmpeg 详细输出。

.PARAMETER Replay
    从缓存直接播放（跳过拆帧和转换）。

.PARAMETER NoCache
    强制跳过缓存，始终重新拆帧和转换。

.PARAMETER CacheDir
    缓存目录，默认从 config.ps1 读取。

.EXAMPLE
    .\Play-AsciiVideo.ps1 -VideoPath "movie.mp4"

    使用默认参数播放视频。

.EXAMPLE
    .\Play-AsciiVideo.ps1 -VideoPath "movie.mp4" -Fps 24 -CharGradient "@%#*+=-:. "

    指定 24fps 并使用反转梯度。

.EXAMPLE
    .\Play-AsciiVideo.ps1 -VideoPath "movie.mp4" -SkipPlayback

    仅处理帧不播放，用于测试转换效果。

.NOTES
    要求：
    - Windows PowerShell 5.1（非 PowerShell Core）
    - .NET Framework 4.0+（System.Drawing）
    - ffmpeg 在系统 PATH 中
    - 控制台使用等宽字体
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0, HelpMessage = "输入视频文件路径（GUI 启动时可不传，从 ASCII_VIDEO_PATH 环境变量读取）")]
    [string]$VideoPath = "",

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 120)]
    [int]$Fps = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 4096)]
    [int]$Width = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 4096)]
    [int]$Height = 0,

    [Parameter(Mandatory = $false)]
    [string]$CharGradient = "",

    [Parameter(Mandatory = $false)]
    [switch]$KeepFrames,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPlayback,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru,

    [Parameter(Mandatory = $false)]
    [switch]$Replay,

    [Parameter(Mandatory = $false)]
    [switch]$NoCache,

    [Parameter(Mandatory = $false)]
    [string]$CacheDir = ""
)

# ============================================================
# 阶段 0：环境验证与初始化
# ============================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 加载配置（命令行参数将覆盖配置默认值）
$configPath = Join-Path $scriptDir "config.ps1"
if (Test-Path $configPath) {
    . $configPath
    Write-Verbose "已加载配置: $configPath"
}
else {
    Write-Warning "未找到 config.ps1，使用内置默认值"
    if (-not $Global:CharGradient) { $Global:CharGradient = " .:-=+*#%@" }
    if (-not $Global:TargetFps) { $Global:TargetFps = 0 }
    if (-not $Global:MaxFrameWidth) { $Global:MaxFrameWidth = 0 }
    if (-not $Global:MaxFrameHeight) { $Global:MaxFrameHeight = 0 }
    if (-not $Global:MaxFrameCount) { $Global:MaxFrameCount = 3000 }
    if (-not $Global:TempDir) { $Global:TempDir = Join-Path $scriptDir "temp" }
    if (-not $Global:KeepFrames) { $Global:KeepFrames = $false }
    if (-not $Global:HideCursor) { $Global:HideCursor = $true }
    if (-not $Global:ClearScreenBeforePlay) { $Global:ClearScreenBeforePlay = $true }
}

# GUI 启动后备：环境变量形式的参数（避免命令行 ANSI 转换损坏 unicode 路径）
# 注：Windows 控制台默认 code page (cp936) 下，Start-Process 传含日文/中文的 -VideoPath
#     会被损坏为乱码，导致 Test-Path 失败。GUI 改用环境变量传递路径。
if (-not $VideoPath -and $env:ASCII_VIDEO_PATH) {
    $VideoPath = $env:ASCII_VIDEO_PATH
    Write-Verbose "使用环境变量 ASCII_VIDEO_PATH 作为视频路径"
}
if ($Fps -eq 0 -and $env:ASCII_VIDEO_FPS) {
    $Fps = [int]$env:ASCII_VIDEO_FPS
    Write-Verbose "使用环境变量 ASCII_VIDEO_FPS = $Fps"
}
if ($Width -eq 0 -and $env:ASCII_VIDEO_WIDTH) {
    $Width = [int]$env:ASCII_VIDEO_WIDTH
    Write-Verbose "使用环境变量 ASCII_VIDEO_WIDTH = $Width"
}
if ($Height -eq 0 -and $env:ASCII_VIDEO_HEIGHT) {
    $Height = [int]$env:ASCII_VIDEO_HEIGHT
    Write-Verbose "使用环境变量 ASCII_VIDEO_HEIGHT = $Height"
}
if (-not $CharGradient -and $env:ASCII_VIDEO_GRADIENT) {
    $CharGradient = $env:ASCII_VIDEO_GRADIENT
    Write-Verbose "使用环境变量 ASCII_VIDEO_GRADIENT = '$CharGradient'"
}
if (-not $KeepFrames -and $env:ASCII_VIDEO_KEEPFRAMES -eq 'true') {
    $KeepFrames = $true
}
if (-not $Replay -and $env:ASCII_VIDEO_REPLAY -eq 'true') {
    $Replay = $true
}
if (-not $NoCache -and $env:ASCII_VIDEO_NOCACHE -eq 'true') {
    $NoCache = $true
}
if (-not $PassThru -and $env:ASCII_VIDEO_VERBOSE -eq 'true') {
    $PassThru = $true
}

# 显式设置控制台输出编码为 UTF-8，确保中文/日文显示正确
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# GUI 启动时设置 ASCII_VIDEO_PAUSE_ON_ERROR=true，错误时按 Enter 才退出，避免一闪而过
$script:PauseOnError = ($env:ASCII_VIDEO_PAUSE_ON_ERROR -eq 'true')

function Wait-OnGuiError {
    # 错误时暂停，让用户看到错误信息（仅 GUI 启动时启用）
    if ($script:PauseOnError) {
        Write-Host ""
        Write-Host "按 Enter 关闭窗口..." -ForegroundColor Yellow
        try { [Console]::In.ReadLine() | Out-Null } catch {}
    }
}

# 注册全局 trap 捕获未处理的异常（GUI 启动时）
trap {
    Write-Host ""
    Write-Host "[未捕获错误] $($_.Exception.Message)" -ForegroundColor Red
    Wait-OnGuiError
    exit 1
}

# 验证视频路径（手动验证，避免 param 阶段就因 unicode 路径报错）
if (-not $VideoPath) {
    Write-Error @"
未提供视频文件路径。

用法 1（命令行）:
  .\Play-AsciiVideo.ps1 -VideoPath "path\to\video.mp4"

用法 2（环境变量，由 GUI 启动）:
  设置 `$env:ASCII_VIDEO_PATH = "path\to\video.mp4" 后直接运行此脚本
"@
    Wait-OnGuiError
    exit 1
}
if (-not (Test-Path $VideoPath -PathType Leaf)) {
    Write-Error "视频文件不存在: $VideoPath"
    Wait-OnGuiError
    exit 1
}

# 命令行参数覆盖配置
$effectiveFps = if ($Fps -gt 0) { $Fps } else { $Global:TargetFps }
$effectiveWidth = if ($Width -gt 0) { $Width } else { $Global:MaxFrameWidth }
$effectiveHeight = if ($Height -gt 0) { $Height } else { $Global:MaxFrameHeight }
$effectiveGradient = if ($CharGradient) { $CharGradient } else { $Global:CharGradient }
$effectiveKeepFrames = if ($KeepFrames) { $true } else { $Global:KeepFrames }
$effectiveTempDir = $Global:TempDir
$effectiveCacheDir = if ($CacheDir) { $CacheDir } else { $Global:CacheDir }
$effectiveCacheEnabled = (-not $NoCache) -and $Global:CacheEnabled

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   PowerShell ASCII 视频播放器     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan

# 检查运行时（必须是 Windows PowerShell 5.1）
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Error @"
检测到 PowerShell Core (v$($PSVersionTable.PSVersion))。
此脚本依赖 .NET Framework 的 System.Drawing，仅在 Windows PowerShell 5.1 中可用。

请使用 Windows PowerShell 运行此脚本：
  powershell.exe -File "$($MyInvocation.MyCommand.Path)" -VideoPath "$VideoPath"
"@
    Wait-OnGuiError
    exit 1
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) | $($PSVersionTable.PSEdition)" -ForegroundColor Gray

# 加载依赖模块
$libDir = Join-Path $scriptDir "lib"
$requiredModules = @(
    "ConvertTo-AsciiFrame.ps1",
    "Invoke-FfmpegExtract.ps1",
    "Write-ConsoleFrame.ps1",
    "Save-AsciiCache.ps1"
)

foreach ($module in $requiredModules) {
    $modulePath = Join-Path $libDir $module
    if (-not (Test-Path $modulePath)) {
        Write-Error "缺少模块: $modulePath"
        Wait-OnGuiError
        exit 1
    }
    . $modulePath
    Write-Verbose "已加载模块: $module"
}

# 检查 System.Drawing 可用性
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Write-Verbose "System.Drawing 可用"
}
catch {
    Wait-OnGuiError
    Write-Error "System.Drawing 不可用。请确保使用 Windows PowerShell 5.1（非 PowerShell Core）。"
    exit 1
}

# 获取控制台尺寸（无控制台环境时回退到默认值）
try {
    $consoleSize = Get-ConsoleCharSize -HeightMargin 2 -ErrorAction Stop
    if ($effectiveWidth -eq 0) { $effectiveWidth = $consoleSize.Width }
    if ($effectiveHeight -eq 0) { $effectiveHeight = $consoleSize.Height }
} catch {
    if ($effectiveWidth -eq 0) { $effectiveWidth = 120 }
    if ($effectiveHeight -eq 0) { $effectiveHeight = 40 }
    Write-Verbose "无法获取控制台尺寸，使用默认值: ${effectiveWidth}×${effectiveHeight}"
}

# 确保最小尺寸
$effectiveWidth = [Math]::Max($effectiveWidth, 20)
$effectiveHeight = [Math]::Max($effectiveHeight, 10)

Write-Host "视频文件  : $VideoPath" -ForegroundColor Gray
Write-Host "输出尺寸  : ${effectiveWidth}×${effectiveHeight}" -ForegroundColor Gray
Write-Host "字符梯度  : '$effectiveGradient'" -ForegroundColor Gray
Write-Host "帧率      : $(if ($effectiveFps -gt 0) { $effectiveFps } else { '自动检测' })" -ForegroundColor Gray

# ============================================================
# 阶段 1-2：获取帧数据（缓存优先）
# ============================================================

# 获取视频信息（缓存和拆帧都需要）
$videoInfo = Get-VideoInfo -VideoPath $VideoPath -ErrorAction SilentlyContinue
if ($videoInfo) {
    Write-Host "视频信息  : $($videoInfo.Width)×$($videoInfo.Height), $($videoInfo.Fps) fps, $($videoInfo.Duration)s" -ForegroundColor Gray
}

# 计算缓存键
$cacheKey = $null
$cacheLoaded = $false

if ($effectiveCacheEnabled) {
    $cacheKey = Get-CacheKey -VideoPath $VideoPath `
        -Width $effectiveWidth -Height $effectiveHeight `
        -Fps $effectiveFps -CharGradient $effectiveGradient `
        -MaxFrameCount $Global:MaxFrameCount

    # 定期清理过期缓存（每次播放时检查）
    $removed = Clear-ExpiredCache -CacheDir $effectiveCacheDir -ExpireDays $Global:CacheExpireDays

    # 检查缓存有效性
    if (Test-CacheValid -CacheKey $cacheKey -CacheDir $effectiveCacheDir `
            -ExpireDays $Global:CacheExpireDays -VideoPath $VideoPath `
            -Width $effectiveWidth -Height $effectiveHeight `
            -Fps $effectiveFps -CharGradient $effectiveGradient) {
        Write-Host "`n--- 缓存命中，加载帧数据 ---" -ForegroundColor Yellow
        $cacheResult = Load-AsciiFrameCache -CacheKey $cacheKey -CacheDir $effectiveCacheDir
        if ($cacheResult) {
            $allFrames = $cacheResult.Frames
            $cacheLoaded = $true
            Write-Host "跳过拆帧和转换阶段" -ForegroundColor Green
        }
    }
    elseif ($Replay) {
        Write-Error "Replay 模式要求缓存存在，但未找到有效缓存。请先正常播放一次以生成缓存。"
        Wait-OnGuiError
        exit 1
    }
}

if (-not $cacheLoaded) {
    # ============================================================
    # 阶段 1：视频分解
    # ============================================================

    Write-Host "`n⚠ 注意：播放过程中请勿改变控制台窗口大小，否则会崩溃！" -ForegroundColor DarkYellow
    Write-Host "--- 阶段 1: 视频分解 ---" -ForegroundColor Yellow

    $ffmpegParams = @{
        VideoPath = $VideoPath
        OutputDir = $effectiveTempDir
        Fps       = $effectiveFps
        ErrorAction = "Stop"
    }

    if ($effectiveWidth -gt 0 -and $effectiveHeight -gt 0) {
        $ffmpegParams.FrameWidth = $effectiveWidth
        $ffmpegParams.FrameHeight = $effectiveHeight
    }

    if ($PassThru) {
        $ffmpegParams.PassThru = $true
    }

    $frameFiles = Invoke-FfmpegExtract @ffmpegParams

    if (-not $frameFiles -or $frameFiles.Count -eq 0) {
        Write-Error "视频分解失败，退出。"
        exit 1
    }

    # ============================================================
    # 阶段 2：ASCII 转换
    # ============================================================

    Write-Host "`n--- 阶段 2: ASCII 转换 ---" -ForegroundColor Yellow

    $allFrames = ConvertTo-AsciiFrameBatch -FrameDir $effectiveTempDir `
        -Width $effectiveWidth `
        -Height $effectiveHeight `
        -CharGradient $effectiveGradient `
        -MaxFrameCount $Global:MaxFrameCount

    if (-not $allFrames -or $allFrames.Count -eq 0) {
        Write-Error "ASCII 转换失败，退出。"
        Wait-OnGuiError
        exit 1
    }

    # 保存缓存（如果启用）
    if ($effectiveCacheEnabled -and $cacheKey) {
        Write-Verbose "保存帧缓存: $cacheKey"
        Save-AsciiFrameCache -Frames $allFrames -CacheKey $cacheKey `
            -CacheDir $effectiveCacheDir `
            -VideoPath $VideoPath `
            -Width $effectiveWidth -Height $effectiveHeight `
            -Fps $effectiveFps -CharGradient $effectiveGradient `
            -MaxFrameCount $Global:MaxFrameCount
    }
}

# 验证第一帧
$firstFrame = $allFrames[0]
Write-Verbose "第一帧: $($firstFrame.Count) 行 × $($firstFrame[0].Length) 列"

# ============================================================
# 阶段 3：控制台播放
# ============================================================

if ($SkipPlayback) {
    Write-Host "`n--- 阶段 3: 跳过播放 (--SkipPlayback) ---" -ForegroundColor Yellow
    Write-Host "帧处理完成，临时文件保留于: $effectiveTempDir" -ForegroundColor Gray

    # 显示第一帧预览
    Write-Host "`n第一帧预览:" -ForegroundColor Cyan
    [Console]::WriteLine(($firstFrame -join [Environment]::NewLine))
}
else {
    Write-Host "`n--- 阶段 3: 控制台播放 ---" -ForegroundColor Yellow

    # 确定播放帧率
    $playbackFps = if ($effectiveFps -gt 0) { $effectiveFps } else { 30 }
    if ($videoInfo -and $videoInfo.Fps -gt 0) {
        $playbackFps = [int]$videoInfo.Fps
    }

    # 初始化控制台
    $consoleState = Initialize-ConsoleForPlayback `
        -HideCursor:$Global:HideCursor `
        -ClearScreen:$Global:ClearScreenBeforePlay

    try {
        # 开始播放
        Start-FramePlayback -Frames $allFrames `
            -Fps $playbackFps `
            -ConsoleState $consoleState `
            -TempDir $effectiveTempDir `
            -KeepFrames:$effectiveKeepFrames
    }
    finally {
        # 确保恢复控制台
        Restore-ConsoleState -State $consoleState
    }
}

Write-Host "`n完成。" -ForegroundColor Green
