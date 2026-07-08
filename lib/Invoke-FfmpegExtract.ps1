#Requires -Version 5.1

<#
.SYNOPSIS
    使用 ffmpeg 将视频文件分解为 PNG 图片帧序列。

.DESCRIPTION
    调用系统 PATH 中的 ffmpeg，按指定帧率将视频分解为连续的 PNG 图片。
    输出文件命名为 frame_000001.png、frame_000002.png 等。

    含 unicode 字符（中文/日文等）的视频路径会被复制到 %TEMP% 的 ASCII 临时路径，
    以避免 Windows CRT 把 UTF-16 命令行按 console code page (cp936) 转 ANSI 时
    损坏日文/中文路径（ffmpeg 是 C 程序，无法处理损坏后的路径）。

.PARAMETER VideoPath
    输入视频文件的完整路径。

.PARAMETER OutputDir
    帧图片输出目录，默认为当前脚本所在目录下的 temp。

.PARAMETER Fps
    目标帧率。值为 0 时自动检测视频原始帧率。
    注意：指定高于原始帧率的值不会提升实际帧数。

.PARAMETER FrameWidth
    输出图片宽度（像素）。值为 0 时使用视频原始宽度。

.PARAMETER FrameHeight
    输出图片高度（像素）。值为 0 时使用视频原始高度。

.PARAMETER PassThru
    如果指定，则额外输出 ffmpeg 的标准错误流到控制台（调试用）。

.EXAMPLE
    Invoke-FfmpegExtract -VideoPath "movie.mp4"

    使用默认参数分解视频。

.EXAMPLE
    Invoke-FfmpegExtract -VideoPath "movie.mp4" -Fps 15 -FrameWidth 240 -FrameHeight 80

    按 15fps、每帧 240×80 像素分解视频。

.OUTPUTS
    System.String[]。输出的帧图片文件完整路径列表。
#>

<#
.SYNOPSIS
    自动发现 ffmpeg 安装路径。

.DESCRIPTION
    先检查系统 PATH，若未找到则搜索常见安装位置（winget、Chocolatey、
    Scoop、C:\ffmpeg 等），找到后自动加入当前会话的 PATH。

.OUTPUTS
     String。ffmpeg 所在目录路径，未找到时返回 $null。

.NOTES
    此函数供 Invoke-FfmpegExtract 和 GUI 启动器共同使用。
#>

function Find-FfmpegPath {
    [CmdletBinding()]
    param()

    # 先检查 PATH
    $ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ffmpegCmd) {
        return (Split-Path -Parent $ffmpegCmd.Source)
    }

    # 搜索常见安装位置
    $searchPaths = @(
        # winget 安装
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\ffmpeg-*\bin\ffmpeg.exe",
        # 手动安装
        "C:\ffmpeg\bin\ffmpeg.exe",
        "C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        # Chocolatey
        "C:\ProgramData\chocolatey\bin\ffmpeg.exe",
        # Scoop
        "$env:USERPROFILE\scoop\apps\ffmpeg\current\ffmpeg.exe"
    )

    foreach ($sp in $searchPaths) {
        $result = Get-Item $sp -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($result) {
            $dir = Split-Path -Parent $result.FullName
            $env:PATH = "$dir;$env:PATH"
            Write-Verbose "ffmpeg 已找到: $dir"
            return $dir
        }
    }

    return $null
}

# ============================================================
# 视频拆帧
# ============================================================

function Invoke-FfmpegExtract {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$VideoPath,

        [Parameter(Mandatory = $false)]
        [string]$OutputDir = "$PSScriptRoot\temp",

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 120)]
        [int]$Fps = 0,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 7680)]
        [int]$FrameWidth = 0,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 4320)]
        [int]$FrameHeight = 0,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    begin {
        # 使用 Find-FfmpegPath 自动发现 ffmpeg
        $ffmpegDir = Find-FfmpegPath
        if (-not $ffmpegDir) {
            Write-Error @"
未找到 ffmpeg。请安装 ffmpeg 并将其加入系统 PATH。

安装方式（任选其一）：
  1. winget: winget install ffmpeg
  2. 下载: https://ffmpeg.org/download.html
  3. Chocolatey: choco install ffmpeg
  4. Scoop: scoop install ffmpeg

安装后请重新打开 PowerShell 终端。
"@
            return $null
        }
        Write-Verbose "ffmpeg 路径: $ffmpegDir"
    }

    process {
        # 含 unicode 字符的路径需复制到 ASCII 临时路径，避免 ffmpeg/ffprobe 命令行
        # 被 Windows CRT 按 console code page (cp936) 转 ANSI 时损坏日文/中文。
        # 纯 ASCII 路径直接使用（零拷贝、零延迟）。
        $asciiVideoPath = $VideoPath
        $isTempCopy = $false
        if ($VideoPath -match '[^\x00-\x7F]') {
            $ext = [System.IO.Path]::GetExtension($VideoPath)
            if (-not $ext) { $ext = ".mp4" }
            $tempName = "ascii_player_{0}_{1}{2}" -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8), $ext
            $asciiVideoPath = Join-Path $env:TEMP $tempName
            Write-Host "  复制视频到临时 ASCII 路径: $asciiVideoPath" -ForegroundColor DarkGray
            [System.IO.File]::Copy($VideoPath, $asciiVideoPath, $true)
            $isTempCopy = $true
        }

        try {
            # 确保输出目录存在
            if (-not (Test-Path $OutputDir)) {
                New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
                Write-Verbose "创建输出目录: $OutputDir"
            }

            # 清空输出目录中的旧帧文件
            Get-ChildItem -Path $OutputDir -Filter "frame_*.png" -ErrorAction SilentlyContinue `
                | Remove-Item -Force -ErrorAction SilentlyContinue

            # 检测视频原始帧率（用 ASCII 路径调 ffmpeg，避免 unicode 路径损坏）
            $effectiveFps = $Fps
            if ($Fps -eq 0) {
                Write-Verbose "检测视频帧率..."
                # ffmpeg 把版本/状态信息输出到 stderr；函数可能被 -ErrorAction Stop 调用，
                # 需要临时抑制 stderr 转 ErrorRecord，避免版本信息被当作异常抛出。
                $oldEap = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                try {
                    $probeResult = & ffmpeg -i $asciiVideoPath 2>&1 | Out-String
                }
                finally {
                    $ErrorActionPreference = $oldEap
                }
                if ($probeResult -match '(\d+(?:\.\d+)?)\s*(?:fps|FPS)') {
                    $detectedFps = [math]::Round([double]$Matches[1])
                    $effectiveFps = [Math]::Max($detectedFps, 1)
                    Write-Host "检测到视频帧率: $effectiveFps fps" -ForegroundColor Cyan
                }
                else {
                    Write-Warning "无法自动检测帧率，使用默认 30fps"
                    $effectiveFps = 30
                }
            }

            # 构建 ffmpeg 参数（使用 ASCII 路径，避开 Windows CRT 命令行 ANSI 转换问题）
            $ffmpegArgs = @(
                "-i",
                $asciiVideoPath,
                "-loglevel", "error",
                "-stats",
                "-y"
            )

            # 帧率滤镜
            $ffmpegArgs += "-vf"
            $vfParts = @("fps=$effectiveFps")

            # 尺寸缩放（如果指定）
            if ($FrameWidth -gt 0 -and $FrameHeight -gt 0) {
                $vfParts += "scale=${FrameWidth}:${FrameHeight}"
            }

            $ffmpegArgs += ($vfParts -join ',')
            $ffmpegArgs += "$OutputDir\frame_%06d.png"

            # 输出文件名格式
            Write-Verbose "ffmpeg 参数: ffmpeg $($ffmpegArgs -join ' ')"

            # 执行 ffmpeg
            Write-Host "开始分解视频帧..." -ForegroundColor Cyan
            Write-Host "  源文件: $VideoPath" -ForegroundColor Gray
            Write-Host "  帧率: $effectiveFps fps" -ForegroundColor Gray
            if ($FrameWidth -gt 0) {
                Write-Host "  尺寸: ${FrameWidth}×${FrameHeight}" -ForegroundColor Gray
            }
            Write-Host "  输出目录: $OutputDir" -ForegroundColor Gray

            # 使用 & 调用 ffmpeg，PowerShell 会自动正确处理含空格的路径参数。
            # 不捕获 stderr，让 ffmpeg 的进度/错误信息直接输出到控制台，避免 -ErrorAction Stop 时把进度行当作异常。
            & ffmpeg @ffmpegArgs

            if ($LASTEXITCODE -ne 0) {
                Write-Error "ffmpeg 退出码: $LASTEXITCODE，视频分解可能未完全成功"
            }

            # 收集输出帧文件
            $frameFiles = @(Get-ChildItem -Path $OutputDir -Filter "frame_*.png" | Sort-Object Name)

            if ($frameFiles.Count -eq 0) {
                Write-Error "未生成任何帧文件。请检查视频文件格式是否受 ffmpeg 支持。"
                return $null
            }

            Write-Host "分解完成: $($frameFiles.Count) 帧图片" -ForegroundColor Green
            return $frameFiles | ForEach-Object { $_.FullName }
        }
        catch {
            Write-Error "视频分解失败: $($_.Exception.Message)"
            throw
        }
        finally {
            # 清理临时 ASCII 副本
            if ($isTempCopy -and (Test-Path $asciiVideoPath)) {
                Remove-Item $asciiVideoPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

<#
.SYNOPSIS
    获取视频文件的基本信息。

.DESCRIPTION
    使用 ffprobe（随 ffmpeg 安装）获取视频的时长、分辨率、帧率等信息。

.PARAMETER VideoPath
    输入视频文件的完整路径。

.EXAMPLE
    Get-VideoInfo -VideoPath "movie.mp4"
#>

function Get-VideoInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$VideoPath
    )

    process {
        # 检查 ffprobe 可用性
        $ffprobeCmd = Get-Command ffprobe -ErrorAction SilentlyContinue
        if (-not $ffprobeCmd) {
            Write-Warning "未找到 ffprobe（通常随 ffmpeg 安装），无法获取视频信息"
            return $null
        }

        $info = [PSCustomObject]@{
            Path       = $VideoPath
            Duration   = 0.0
            Width      = 0
            Height     = 0
            Fps        = 0.0
            Codec      = ""
            FileSizeMB = 0.0
        }

        # 含 unicode 字符的路径复制到 ASCII 临时路径（与 Invoke-FfmpegExtract 同理）
        $asciiVideoPath = $VideoPath
        $isTempCopy = $false
        if ($VideoPath -match '[^\x00-\x7F]') {
            $ext = [System.IO.Path]::GetExtension($VideoPath)
            if (-not $ext) { $ext = ".mp4" }
            $tempName = "ascii_probe_{0}_{1}{2}" -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8), $ext
            $asciiVideoPath = Join-Path $env:TEMP $tempName
            [System.IO.File]::Copy($VideoPath, $asciiVideoPath, $true)
            $isTempCopy = $true
        }

        try {
            # 优先尝试 JSON 格式（更可靠），失败则回退到 CSV
            try {
                $jsonOutput = & ffprobe -v error -select_streams v:0 `
                    -show_entries stream=width,height,r_frame_rate,codec_name `
                    -show_entries format=duration,size `
                    -of json $asciiVideoPath 2>&1 | Out-String

                $probeData = $jsonOutput | ConvertFrom-Json -ErrorAction Stop

                if ($probeData.streams -and $probeData.streams.Count -gt 0) {
                    $stream = $probeData.streams[0]
                    $info.Width = [int]$stream.width
                    $info.Height = [int]$stream.height
                    $info.Codec = $stream.codec_name

                    # 解析帧率（格式: "30000/1001"）
                    if ($stream.r_frame_rate -match '(\d+)/(\d+)') {
                        if ([int]$Matches[2] -ne 0) {
                            $info.Fps = [math]::Round([int]$Matches[1] / [int]$Matches[2], 2)
                        }
                    }
                }

                if ($probeData.format) {
                    $info.Duration = [math]::Round([double]$probeData.format.duration, 2)
                    $info.FileSizeMB = [math]::Round([double]$probeData.format.size / 1MB, 2)
                }
            }
            catch {
                # 回退到 CSV 解析（兼容旧版 ffmpeg）
                Write-Verbose "ffprobe JSON 解析失败，回退到 CSV 模式: $($_.Exception.Message)"

                $probeOutput = (& ffprobe -v error -select_streams v:0 `
                        -show_entries stream=width,height,r_frame_rate,codec_name,duration `
                        -show_entries format=duration,size `
                        -of csv=p=0 $asciiVideoPath 2>&1) -join "`n"

                Write-Verbose "ffprobe 输出:`n$probeOutput"

                $lines = $probeOutput -split "`n"
                if ($lines.Count -ge 2) {
                    $streamParts = $lines[0] -split ','
                    if ($streamParts.Count -ge 4) {
                        $info.Width = [int]$streamParts[0]
                        $info.Height = [int]$streamParts[1]
                        $info.Codec = $streamParts[3]

                        $fpsStr = $streamParts[2]
                        if ($fpsStr -match '(\d+)/(\d+)') {
                            if ([int]$Matches[2] -ne 0) {
                                $info.Fps = [math]::Round([int]$Matches[1] / [int]$Matches[2], 2)
                            }
                        }
                    }

                    $formatParts = $lines[1] -split ','
                    if ($formatParts.Count -ge 2) {
                        $info.Duration = [math]::Round([double]$formatParts[0], 2)
                        $sizeBytes = [double]$formatParts[1]
                        $info.FileSizeMB = [math]::Round($sizeBytes / 1MB, 2)
                    }
                }
            }

            return $info
        }
        finally {
            # 清理临时 ASCII 副本
            if ($isTempCopy -and (Test-Path $asciiVideoPath)) {
                Remove-Item $asciiVideoPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# 注：本文件通过 dot-source 加载（. .\file.ps1），所有函数自动可用
