#Requires -Version 5.1

<#
.SYNOPSIS
    ASCII 视频播放器 GUI 启动器。

.DESCRIPTION
    WinForms 图形界面，支持拖放视频文件、可视化设置播放参数、
    一键启动播放。使用独立进程运行 Play-AsciiVideo.ps1 以确保
    播放不被 GUI 阻塞。

    功能：
    - 拖放视频文件到窗口
    - 调整帧率、帧数上限、字符梯度等参数
    - ffmpeg 状态检测
    - 缓存选项
    - 一键启动播放

.EXAMPLE
    .\gui\PlayerGui.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# 加载项目模块
# ============================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

# 加载 config
$configPath = Join-Path $projectRoot "config.ps1"
if (Test-Path $configPath) {
    . $configPath
}

# 加载 ffmpeg 发现函数
$ffmpegModule = Join-Path $projectRoot "lib\Invoke-FfmpegExtract.ps1"
if (Test-Path $ffmpegModule) {
    . $ffmpegModule
}

# ============================================================
# 配色方案（深色主题）
# ============================================================

$ColorBg       = [System.Drawing.Color]::FromArgb(30, 30, 30)
$ColorPanel    = [System.Drawing.Color]::FromArgb(45, 45, 45)
$ColorText     = [System.Drawing.Color]::FromArgb(220, 220, 220)
$ColorAccent   = [System.Drawing.Color]::FromArgb(0, 180, 180)
$ColorWarning  = [System.Drawing.Color]::FromArgb(255, 180, 50)
$ColorError    = [System.Drawing.Color]::FromArgb(255, 80, 80)
$ColorSuccess  = [System.Drawing.Color]::FromArgb(80, 220, 80)
$ColorDisabled = [System.Drawing.Color]::FromArgb(100, 100, 100)
$ColorBorder   = [System.Drawing.Color]::FromArgb(70, 70, 70)

# ============================================================
# 主窗口
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "ASCII Video Player"
$form.Size = New-Object System.Drawing.Size(600, 740)
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorBg
$form.ForeColor = $ColorText
$form.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.MinimumSize = New-Object System.Drawing.Size(600, 740)

# ============================================================
# 辅助函数
# ============================================================

function New-Label {
    param($Text, $X, $Y, $Width = 500, $Height = 20, $FontSize = 9.5, $Bold = $false)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, $Height)
    $lbl.ForeColor = $ColorText
    $lbl.BackColor = "Transparent"
    $fontStyle = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $lbl.Font = New-Object System.Drawing.Font("Consolas", $FontSize, $fontStyle)
    return $lbl
}

function New-SectionHeader {
    param($Text, $Y)
    $lbl = New-Label -Text $Text -X 20 -Y $Y -FontSize 11 -Bold $true
    $lbl.ForeColor = $ColorAccent
    return $lbl
}

function New-Separator {
    param($Y)
    $sep = New-Object System.Windows.Forms.Label
    $sep.Location = New-Object System.Drawing.Point(20, $Y)
    $sep.Size = New-Object System.Drawing.Size(504, 1)
    $sep.BorderStyle = "FixedSingle"
    $sep.BackColor = $ColorBorder
    return $sep
}

# ============================================================
# 拖放区域
# ============================================================

$dropLabel = New-SectionHeader -Text "1. 选择视频文件" -Y 12
$form.Controls.Add($dropLabel)

$dropPanel = New-Object System.Windows.Forms.Panel
$dropPanel.Location = New-Object System.Drawing.Point(20, 38)
$dropPanel.Size = New-Object System.Drawing.Size(504, 90)
$dropPanel.BackColor = $ColorPanel
$dropPanel.BorderStyle = "FixedSingle"
$dropPanel.AllowDrop = $true
$dropPanel.Cursor = [System.Windows.Forms.Cursors]::Hand

$dropHint = New-Label -Text "拖放视频文件到此处`n或点击选择文件" -X 0 -Y 22 -Width 504 -Height 46 -FontSize 11 -Bold $true
$dropHint.TextAlign = "MiddleCenter"
$dropHint.ForeColor = $ColorDisabled
$dropPanel.Controls.Add($dropHint)

$selectedVideoPath = ""

$dropPanel.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$dropPanel.Add_DragDrop({
    param($sender, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files.Count -gt 0) {
        $script:selectedVideoPath = $files[0]
        $dropHint.Text = "已选择:`n$($files[0])"
        $dropHint.ForeColor = $ColorSuccess
        Update-PlayButtonState
    }
})

$dropPanel.Add_Click({
    $openDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openDialog.Filter = "视频文件|*.mp4;*.mkv;*.avi;*.mov;*.wmv;*.flv;*.webm|所有文件|*.*"
    $openDialog.Title = "选择视频文件"
    if ($openDialog.ShowDialog() -eq "OK") {
        $script:selectedVideoPath = $openDialog.FileName
        $dropHint.Text = "已选择:`n$($openDialog.FileName)"
        $dropHint.ForeColor = $ColorSuccess
        Update-PlayButtonState
    }
})

$form.Controls.Add($dropPanel)

# ============================================================
# 视频信息显示
# ============================================================

$videoInfoLabel = New-Label -Text "" -X 20 -Y 134 -Width 504 -Height 18 -FontSize 9
$videoInfoLabel.ForeColor = $ColorDisabled
$form.Controls.Add($videoInfoLabel)

$sep1 = New-Separator -Y 156
$form.Controls.Add($sep1)

# ============================================================
# 参数设置区域
# ============================================================

$paramHeader = New-SectionHeader -Text "2. 播放参数" -Y 166
$form.Controls.Add($paramHeader)

# --- 帧率 ---
$lblFps = New-Label -Text "帧率 (FPS):  0 = 自动检测" -X 30 -Y 196 -Width 220
$lblFps.AutoSize = $true
$form.Controls.Add($lblFps)

$numFps = New-Object System.Windows.Forms.NumericUpDown
$numFps.Location = New-Object System.Drawing.Point(350, 194)
$numFps.Size = New-Object System.Drawing.Size(80, 24)
$numFps.Minimum = 0
$numFps.Maximum = 120
$numFps.Value = if ($Global:TargetFps) { $Global:TargetFps } else { 0 }
$numFps.BackColor = $ColorBg
$numFps.ForeColor = $ColorText
$numFps.BorderStyle = "FixedSingle"
$form.Controls.Add($numFps)

# --- 最大帧数 ---
$lblMaxFrames = New-Label -Text "最大帧数:" -X 30 -Y 228 -Width 220
$form.Controls.Add($lblMaxFrames)

$numMaxFrames = New-Object System.Windows.Forms.NumericUpDown
$numMaxFrames.Location = New-Object System.Drawing.Point(350, 226)
$numMaxFrames.Size = New-Object System.Drawing.Size(80, 24)
$numMaxFrames.Minimum = 10
$numMaxFrames.Maximum = 100000
$numMaxFrames.Value = if ($Global:MaxFrameCount) { $Global:MaxFrameCount } else { 3000 }
$numMaxFrames.BackColor = $ColorBg
$numMaxFrames.ForeColor = $ColorText
$numMaxFrames.BorderStyle = "FixedSingle"
$numMaxFrames.Increment = 100
$form.Controls.Add($numMaxFrames)

# --- 宽度 ---
$lblWidth = New-Label -Text "输出宽度:  0 = 自动 (控制台宽度)" -X 30 -Y 260 -Width 220
$lblWidth.AutoSize = $true
$form.Controls.Add($lblWidth)

$numWidth = New-Object System.Windows.Forms.NumericUpDown
$numWidth.Location = New-Object System.Drawing.Point(350, 258)
$numWidth.Size = New-Object System.Drawing.Size(80, 24)
$numWidth.Minimum = 0
$numWidth.Maximum = 4096
$numWidth.Value = 0
$numWidth.BackColor = $ColorBg
$numWidth.ForeColor = $ColorText
$numWidth.BorderStyle = "FixedSingle"
$numWidth.Increment = 10
$form.Controls.Add($numWidth)

# --- 高度 ---
$lblHeight = New-Label -Text "输出高度:  0 = 自动 (控制台高度-2)" -X 30 -Y 292 -Width 240
$lblHeight.AutoSize = $true
$form.Controls.Add($lblHeight)

$numHeight = New-Object System.Windows.Forms.NumericUpDown
$numHeight.Location = New-Object System.Drawing.Point(350, 290)
$numHeight.Size = New-Object System.Drawing.Size(80, 24)
$numHeight.Minimum = 0
$numHeight.Maximum = 4096
$numHeight.Value = 0
$numHeight.BackColor = $ColorBg
$numHeight.ForeColor = $ColorText
$numHeight.BorderStyle = "FixedSingle"
$numHeight.Increment = 5
$form.Controls.Add($numHeight)

# --- 字符梯度 ---
$lblGradient = New-Label -Text "字符梯度 (左暗右亮):" -X 30 -Y 324 -Width 500
$form.Controls.Add($lblGradient)

$txtGradient = New-Object System.Windows.Forms.TextBox
$txtGradient.Location = New-Object System.Drawing.Point(30, 346)
$txtGradient.Size = New-Object System.Drawing.Size(320, 24)
$txtGradient.Text = if ($Global:CharGradient) { $Global:CharGradient } else { " .:-=+*#%@" }
$txtGradient.BackColor = $ColorBg
$txtGradient.ForeColor = $ColorText
$txtGradient.BorderStyle = "FixedSingle"
$txtGradient.Font = New-Object System.Drawing.Font("Consolas", 11)
$form.Controls.Add($txtGradient)

$lblGradientPreview = New-Label -Text "" -X 360 -Y 346 -Width 160 -Height 24 -FontSize 14
$lblGradientPreview.ForeColor = $ColorAccent
$form.Controls.Add($lblGradientPreview)

# 梯度预览更新
function Update-GradientPreview {
    $str = $txtGradient.Text
    if ($str.Length -gt 0) {
        $lblGradientPreview.Text = "预览: " + ($str -join " ")
    }
    else {
        $lblGradientPreview.Text = "预览: (空)"
    }
}
$txtGradient.Add_TextChanged({ Update-GradientPreview })
Update-GradientPreview

$sep2 = New-Separator -Y 380
$form.Controls.Add($sep2)

# ============================================================
# 选项区域
# ============================================================

$optionHeader = New-SectionHeader -Text "3. 选项" -Y 390
$form.Controls.Add($optionHeader)

# 缓存选项
$chkCache = New-Object System.Windows.Forms.CheckBox
$chkCache.Text = "使用缓存（二次播放可跳过拆帧和转换）"
$chkCache.Location = New-Object System.Drawing.Point(30, 418)
$chkCache.Size = New-Object System.Drawing.Size(480, 22)
$chkCache.Checked = (-not (Get-Variable -Name "CacheEnabled" -Scope Global -ErrorAction SilentlyContinue) -or $Global:CacheEnabled)
$chkCache.ForeColor = $ColorText
$chkCache.BackColor = "Transparent"
$form.Controls.Add($chkCache)

# 仅回放
$chkReplay = New-Object System.Windows.Forms.CheckBox
$chkReplay.Text = "仅回放 (-Replay: 必须已有缓存, 跳过拆帧和转换)"
$chkReplay.Location = New-Object System.Drawing.Point(30, 444)
$chkReplay.Size = New-Object System.Drawing.Size(480, 22)
$chkReplay.ForeColor = $ColorWarning
$chkReplay.BackColor = "Transparent"
$form.Controls.Add($chkReplay)

# 保留帧文件
$chkKeepFrames = New-Object System.Windows.Forms.CheckBox
$chkKeepFrames.Text = "保留临时帧文件 (调试用)"
$chkKeepFrames.Location = New-Object System.Drawing.Point(30, 470)
$chkKeepFrames.Size = New-Object System.Drawing.Size(480, 22)
$chkKeepFrames.ForeColor = $ColorText
$chkKeepFrames.BackColor = "Transparent"
$form.Controls.Add($chkKeepFrames)

# Verbose (PassThru)
$chkVerbose = New-Object System.Windows.Forms.CheckBox
$chkVerbose.Text = "显示 ffmpeg 详细输出"
$chkVerbose.Location = New-Object System.Drawing.Point(30, 496)
$chkVerbose.Size = New-Object System.Drawing.Size(480, 22)
$chkVerbose.ForeColor = $ColorText
$chkVerbose.BackColor = "Transparent"
$form.Controls.Add($chkVerbose)

$sep3 = New-Separator -Y 524
$form.Controls.Add($sep3)

# ============================================================
# 状态区域
# ============================================================

$statusHeader = New-SectionHeader -Text "4. 状态" -Y 534
$form.Controls.Add($statusHeader)

# ffmpeg 状态
$ffmpegStatusLabel = New-Label -Text "正在检测 ffmpeg..." -X 30 -Y 560 -Width 540
$ffmpegStatusLabel.AutoEllipsis = $true
$form.Controls.Add($ffmpegStatusLabel)

$ffmpegPath = $null
try {
    $ffmpegPath = Find-FfmpegPath
    if ($ffmpegPath) {
        $ffmpegStatusLabel.Text = "ffmpeg: 已找到 ($ffmpegPath)"
        $ffmpegStatusLabel.ForeColor = $ColorSuccess
    }
    else {
        $ffmpegStatusLabel.Text = "ffmpeg: 未找到！请安装 ffmpeg"
        $ffmpegStatusLabel.ForeColor = $ColorError
    }
}
catch {
    $ffmpegStatusLabel.Text = "ffmpeg: 未检测"
    $ffmpegStatusLabel.ForeColor = $ColorDisabled
}

# 缓存目录状态
$cacheDir = if ($Global:CacheDir) { $Global:CacheDir } else { Join-Path $projectRoot "cache" }
$cacheLabel = New-Label -Text "缓存目录: $cacheDir" -X 30 -Y 582 -Width 480
$cacheLabel.ForeColor = $ColorDisabled
$form.Controls.Add($cacheLabel)

# ============================================================
# 播放按钮
# ============================================================

$btnPlay = New-Object System.Windows.Forms.Button
$btnPlay.Text = "▶ 开始播放"
$btnPlay.Location = New-Object System.Drawing.Point(170, 615)
$btnPlay.Size = New-Object System.Drawing.Size(260, 40)
$btnPlay.BackColor = $ColorAccent
$btnPlay.ForeColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$btnPlay.FlatStyle = "Flat"
$btnPlay.FlatAppearance.BorderSize = 0
$btnPlay.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Bold)
$btnPlay.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPlay.Enabled = $false
$form.Controls.Add($btnPlay)

# 播放按钮悬停效果
$btnPlay.Add_MouseEnter({
    $btnPlay.BackColor = [System.Drawing.Color]::FromArgb(0, 210, 210)
})
$btnPlay.Add_MouseLeave({
    $btnPlay.BackColor = $ColorAccent
})

function Update-PlayButtonState {
    $hasVideo = $script:selectedVideoPath -and (Test-Path $script:selectedVideoPath -PathType Leaf)
    $hasFfmpeg = $null -ne $script:ffmpegPath
    $btnPlay.Enabled = $hasVideo -and $hasFfmpeg

    if ($btnPlay.Enabled) {
        $btnPlay.BackColor = $ColorAccent
    }
    else {
        $btnPlay.BackColor = $ColorDisabled
    }

    # 更新视频信息
    if ($hasVideo) {
        $file = Get-Item $script:selectedVideoPath
        $sizeMB = [math]::Round($file.Length / 1MB, 1)
        $videoInfoLabel.Text = "文件: $($file.Name)  |  大小: ${sizeMB} MB"
        $videoInfoLabel.ForeColor = $ColorSuccess
    }
}

# 连接 ffmpeg 状态和按钮状态
function Update-FfmpegStatus {
    if ($script:ffmpegPath) {
        $ffmpegStatusLabel.Text = "ffmpeg: 已找到 ($($script:ffmpegPath))"
        $ffmpegStatusLabel.ForeColor = $ColorSuccess
    }
    else {
        $ffmpegStatusLabel.Text = "ffmpeg: 未找到！请安装 ffmpeg"
        $ffmpegStatusLabel.ForeColor = $ColorError
    }
    Update-PlayButtonState
}
Update-FfmpegStatus

$btnPlay.Add_Click({
    # 通过环境变量传递所有参数（避免命令行 ANSI 转换损坏 unicode 路径）
    # 原因：Windows console 默认 code page (cp936) 下，Start-Process -ArgumentList
    #       传含中文/日文的 -VideoPath 时会被损坏为乱码，Test-Path 失败。
    #       .NET 进程环境变量用 UTF-16 存储，跨进程传递完整无损。
    $env:ASCII_VIDEO_PATH = $script:selectedVideoPath
    $env:ASCII_VIDEO_FPS = $numFps.Value.ToString()
    $env:ASCII_VIDEO_WIDTH = $numWidth.Value.ToString()
    $env:ASCII_VIDEO_HEIGHT = $numHeight.Value.ToString()
    $env:ASCII_VIDEO_GRADIENT = $txtGradient.Text
    $env:ASCII_VIDEO_KEEPFRAMES = $chkKeepFrames.Checked.ToString().ToLower()
    $env:ASCII_VIDEO_VERBOSE = $chkVerbose.Checked.ToString().ToLower()
    $env:ASCII_VIDEO_REPLAY = $chkReplay.Checked.ToString().ToLower()
    $env:ASCII_VIDEO_NOCACHE = (-not $chkCache.Checked).ToString().ToLower()
    # GUI 启动：让脚本错误时暂停，避免一闪而过看不到错误信息
    $env:ASCII_VIDEO_PAUSE_ON_ERROR = 'true'

    # 不传 -VideoPath 等参数，所有参数从环境变量读取
    $playerScript = Join-Path $projectRoot "Play-AsciiVideo.ps1"
    $argsList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$playerScript`""
    )

    # 最小化 GUI 窗口
    $form.WindowState = "Minimized"

    # 启动播放（独立进程不阻塞 GUI）。用数组传参而非 -join 字符串，
    # 避免 PowerShell 在字符串 join 时引入额外 ANSI 转换。
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argsList -PassThru

    # 等待播放进程结束后恢复 GUI
    $process.WaitForExit()

    # 清理环境变量（避免污染后续启动的 PowerShell 会话）
    @(
        'ASCII_VIDEO_PATH',
        'ASCII_VIDEO_FPS',
        'ASCII_VIDEO_WIDTH',
        'ASCII_VIDEO_HEIGHT',
        'ASCII_VIDEO_GRADIENT',
        'ASCII_VIDEO_KEEPFRAMES',
        'ASCII_VIDEO_VERBOSE',
        'ASCII_VIDEO_REPLAY',
        'ASCII_VIDEO_NOCACHE',
        'ASCII_VIDEO_PAUSE_ON_ERROR'
    ) | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    # 恢复窗口
    $form.WindowState = "Normal"
    $form.Activate()
})

# 双击拖放区选择文件
# (handled by Click event above)

# ============================================================
# 快捷键提示
# ============================================================

$hintLabel = New-Label -Text "提示: 先拖放视频 → 调整参数 → 点击播放 | 缓存位于: $($Global:CacheDir)" -X 20 -Y 655 -Width 504 -Height 40
$hintLabel.ForeColor = $ColorDisabled
$hintLabel.TextAlign = "TopCenter"
$form.Controls.Add($hintLabel)

# ============================================================
# 启动窗口
# ============================================================

$form.Add_Shown({
    $form.Activate()
    Update-PlayButtonState
})

[void]$form.ShowDialog()
