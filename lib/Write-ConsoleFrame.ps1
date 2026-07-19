#Requires -Version 5.1

<#
.SYNOPSIS
    控制台帧渲染与播放管理模块。

.DESCRIPTION
    提供控制台初始化、帧渲染、资源清理和播放循环的完整实现。
    通过 SetCursorPosition 避免全屏刷新闪烁，支持可中断的播放流程。

.NOTES
    此模块依赖 .NET Framework 的 System.Console API，
    仅在 Windows PowerShell 5.1+ 中可用。
#>

# ============================================================
# 模块级状态变量
# ============================================================

$script:_originalCursorVisible = $true
$script:_isInitialized = $false
$script:_originalOutputEncoding = $null

# ============================================================
# 初始化 / 清理
# ============================================================

<#
.SYNOPSIS
    初始化控制台，准备播放 ASCII 视频。

.DESCRIPTION
    保存并修改控制台状态：编码设为 UTF-8、可隐藏光标、
    设窗口标题。返回初始化前的状态对象用于复原。

.PARAMETER HideCursor
    是否隐藏控制台光标。

.PARAMETER ClearScreen
    是否先清屏。

.EXAMPLE
    $state = Initialize-ConsoleForPlayback -HideCursor -ClearScreen
#>

function Initialize-ConsoleForPlayback {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [bool]$HideCursor = $true,

        [Parameter(Mandatory = $false)]
        [bool]$ClearScreen = $true
    )

    # 保存原始状态
    $script:_originalCursorVisible = [Console]::CursorVisible
    $script:_originalOutputEncoding = [Console]::OutputEncoding

    # 设置 UTF-8 编码确保字符正常显示
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # 设置窗口标题
    $originalTitle = [Console]::Title
    [Console]::Title = "ASCII Video Player"

    # 隐藏光标
    if ($HideCursor) {
        [Console]::CursorVisible = $false
    }

    # 清屏
    if ($ClearScreen) {
        Clear-Host
        # 额外确保光标在左上角
        [Console]::SetCursorPosition(0, 0)
    }

    $script:_isInitialized = $true

    # 返回状态快照
    $state = [PSCustomObject]@{
        OriginalCursorVisible  = $script:_originalCursorVisible
        OriginalOutputEncoding = $script:_originalOutputEncoding
        OriginalTitle          = $originalTitle
    }
    return $state
}

<#
.SYNOPSIS
    恢复控制台到播放前的状态。

.DESCRIPTION
    显示光标、恢复原始编码、恢复窗口标题。
    应在播放结束或用户中断时调用。

.PARAMETER State
    Initialize-ConsoleForPlayback 返回的状态对象。

.EXAMPLE
    Restore-ConsoleState -State $state
#>

function Restore-ConsoleState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        $State
    )

    try {
        # 恢复光标
        if ($script:_originalCursorVisible) {
            [Console]::CursorVisible = $true
        }

        # 恢复编码
        if ($null -ne $script:_originalOutputEncoding) {
            [Console]::OutputEncoding = $script:_originalOutputEncoding
        }

        # 恢复标题
        if ($State -and $State.OriginalTitle) {
            [Console]::Title = $State.OriginalTitle
        }

        $script:_isInitialized = $false
    }
    catch {
        # 清理阶段静默处理错误
        Write-Verbose "恢复控制台状态时出错（可忽略）: $($_.Exception.Message)"
    }
}

# ============================================================
# 帧渲染
# ============================================================

<#
.SYNOPSIS
    在控制台中渲染单帧 ASCII 字符。

.DESCRIPTION
    将光标定位到左上角 (0, 0)，一次性输出整帧字符串。
    此方式避免 Clear-Host 造成的闪烁。

.PARAMETER Frame
    ASCII 字符帧（string[]），每个元素是一行。

.PARAMETER CursorTop
    渲染起始行，默认 0（控制台顶部）。

.EXAMPLE
    Write-ConsoleFrame -Frame $asciiLines
#>

function Write-ConsoleFrame {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Frame,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 32767)]
        [int]$CursorTop = 0
    )

    try {
        # 光标定位到左上角
        [Console]::SetCursorPosition(0, $CursorTop)

        # 一次性输出整帧（比逐行 Write-Host 快 ~10 倍）
        $output = $Frame -join [Environment]::NewLine
        [Console]::Write($output)
    }
    catch {
        # 控制台写入失败通常是因为窗口被关闭
        Write-Verbose "帧渲染错误: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    播放 ASCII 帧序列的完整循环。

.DESCRIPTION
    遍历预处理的 ASCII 帧数组，按指定帧间隔依次渲染。
    注册 Ctrl+C 中断处理，确保控制台状态被恢复。

.PARAMETER Frames
    ASCII 帧数组（string[][]），外层是帧索引，内层是行字符串。

.PARAMETER Fps
    播放帧率。

.PARAMETER ConsoleState
    Initialize-ConsoleForPlayback 返回的状态对象。

.PARAMETER TempDir
    临时帧目录（用于清理）。

.PARAMETER KeepFrames
    是否保留临时帧文件。

.EXAMPLE
    Start-FramePlayback -Frames $allFrames -Fps 30 -ConsoleState $state
#>

function Start-FramePlayback {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[][]]$Frames,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$Fps = 30,

        [Parameter(Mandatory = $false)]
        $ConsoleState,

        [Parameter(Mandatory = $false)]
        [string]$TempDir = "",

        [Parameter(Mandatory = $false)]
        [bool]$KeepFrames = $false
    )

    # 帧间隔（毫秒）
    $frameDelayMs = [int](1000.0 / $Fps)
    $totalFrames = $Frames.Count

    Write-Host "开始播放: $totalFrames 帧 @ $Fps fps (间隔 ${frameDelayMs}ms)" -ForegroundColor Cyan
    Write-Host "按 Ctrl+C 停止播放" -ForegroundColor Yellow

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $frameIndex = 0
    $aborted = $false

    try {
        # Ctrl+C 通过 MethodInvocationException（Start-Sleep 中断抛出）捕获
        $global:AbortPlayback = $false

        for ($frameIndex = 0; $frameIndex -lt $totalFrames; $frameIndex++) {
            # 检查中断标志
            if ($global:AbortPlayback) {
                $aborted = $true
                break
            }

            # 渲染当前帧
            Write-ConsoleFrame -Frame $Frames[$frameIndex]

            # 等待下一帧
            Start-Sleep -Milliseconds $frameDelayMs
        }
    }
    catch [System.Management.Automation.MethodInvocationException] {
        # Start-Sleep 被 Ctrl+C 中断时抛出此异常
        $aborted = $true
    }
    finally {
        $stopwatch.Stop()
        $elapsed = $stopwatch.Elapsed

        # 恢复光标位置（在画面下方）
        [Console]::SetCursorPosition(0, [Math]::Min(($Frames[0].Count), [Console]::WindowHeight - 1))

        if ($aborted) {
            Write-Host "`n播放中断 (已播放 $frameIndex / $totalFrames 帧, 耗时 $($elapsed.ToString('mm\:ss')))" -ForegroundColor Yellow
        }
        else {
            $actualFps = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($frameIndex / $elapsed.TotalSeconds, 1) } else { $Fps }
            Write-Host "`n播放完成: $totalFrames 帧, 实际 $actualFps fps, 耗时 $($elapsed.ToString('mm\:ss'))" -ForegroundColor Green
        }

        # 清理临时文件
        if (-not $KeepFrames -and $TempDir -and (Test-Path $TempDir)) {
            Write-Host "清理临时文件..." -ForegroundColor Gray
            Get-ChildItem -Path $TempDir -Filter "frame_*.png" -ErrorAction SilentlyContinue `
                | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "清理完成" -ForegroundColor Gray
        }
    }
}

# ============================================================
# 辅助函数
# ============================================================

<#
.SYNOPSIS
    获取当前控制台的字符网格尺寸。

.DESCRIPTION
    返回控制台窗口宽度和高度（以字符为单位）。
    高度会减去 2 以在底部留出状态栏空间。

.EXAMPLE
    $size = Get-ConsoleCharSize
    # $size.Width = 120, $size.Height = 38
#>

function Get-ConsoleCharSize {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 10)]
        [int]$HeightMargin = 2
    )

    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight - $HeightMargin

    # 最小尺寸检查
    if ($width -lt 40 -or $height -lt 10) {
        Write-Warning "控制台窗口较小 (${width}×$($height + $HeightMargin))，建议拉大窗口以获得更好效果"
    }

    return [PSCustomObject]@{
        Width  = [Math]::Max($width, 1)
        Height = [Math]::Max($height, 1)
    }
}

<#
.SYNOPSIS
    设置控制台窗口大小。

.DESCRIPTION
    调整 PowerShell 控制台窗口大小。
    注意：某些终端宿主（如 Windows Terminal）可能不支持编程式调整。

.PARAMETER Width
    目标宽度（字符数）。

.PARAMETER Height
    目标高度（字符数）。

.EXAMPLE
    Set-ConsoleWindowSize -Width 150 -Height 50
#>

function Set-ConsoleWindowSize {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateRange(10, 4096)]
        [int]$Width,

        [Parameter(Mandatory = $true)]
        [ValidateRange(5, 4096)]
        [int]$Height
    )

    try {
        # 先尝试设置窗口大小
        [Console]::SetWindowSize($Width, $Height)

        # 再尝试设置缓冲区大小（防止滚动条出现）
        if ([Console]::BufferWidth -lt $Width) {
            [Console]::BufferWidth = $Width
        }
        if ([Console]::BufferHeight -lt $Height) {
            [Console]::BufferHeight = $Height
        }

        Write-Verbose "控制台窗口设为: ${Width}×${Height}"
    }
    catch {
        Write-Warning "无法设置控制台窗口大小: $($_.Exception.Message)"
        Write-Warning "请手动调整窗口大小以获得最佳效果"
    }
}

# 注：本文件通过 dot-source 加载（. .\file.ps1），所有函数自动可用
