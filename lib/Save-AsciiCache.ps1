#Requires -Version 5.1

<#
.SYNOPSIS
    ASCII 帧缓存模块：持久化转换结果，避免重复拆帧和转换。

.DESCRIPTION
    将 ASCII 帧数组（string[][]）压缩后写入磁盘，并提供加载和校验功能。
    缓存键由视频路径和转换参数（尺寸、帧率、字符梯度）的 SHA256 哈希生成，
    确保相同参数复用缓存，不同参数重新生成。

    文件格式：
    - 前 4 字节：JSON 元数据长度（Int32，大端序）
    - 接下来 N 字节：JSON 元数据（UTF-8）
    - 剩余字节：GZip 压缩的帧数据
#>

# ============================================================
# 缓存键生成
# ============================================================

<#
.SYNOPSIS
    根据视频路径和转换参数生成缓存键（SHA256 哈希）。

.DESCRIPTION
    将视频完整路径、尺寸、帧率、字符梯度拼接后计算 SHA256，
    确保相同输入产生相同键，不同输入产生不同键。

.PARAMETER VideoPath
    视频文件完整路径。

.PARAMETER Width
    输出宽度。

.PARAMETER Height
    输出高度。

.PARAMETER Fps
    目标帧率。

.PARAMETER CharGradient
    字符梯度串。

.PARAMETER MaxFrameCount
    最大帧数上限。

.EXAMPLE
    $key = Get-CacheKey -VideoPath "movie.mp4" -Width 120 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
#>

function Get-CacheKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VideoPath,

        [Parameter(Mandatory = $true)]
        [int]$Width,

        [Parameter(Mandatory = $true)]
        [int]$Height,

        [Parameter(Mandatory = $true)]
        [int]$Fps,

        [Parameter(Mandatory = $true)]
        [string]$CharGradient,

        [Parameter(Mandatory = $false)]
        [int]$MaxFrameCount = 3000
    )

    # 用视频绝对路径确保重命名后缓存失效
    $absolutePath = (Resolve-Path $VideoPath -ErrorAction SilentlyContinue).Path
    if (-not $absolutePath) { $absolutePath = $VideoPath }

    $fingerprint = "$absolutePath|W=$Width|H=$Height|F=$Fps|G=$CharGradient|M=$MaxFrameCount"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprint)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($bytes)
    $sha256.Dispose()

    # 转为十六进制字符串
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    return $hash
}

# ============================================================
# 缓存保存
# ============================================================

<#
.SYNOPSIS
    将 ASCII 帧数组压缩保存到缓存文件。

.DESCRIPTION
    写入格式：
    +----------------------------------+
    | 4 bytes: JSON metadata length    |  (Int32, Big-Endian)
    +----------------------------------+
    | N bytes: JSON metadata (UTF-8)   |
    +----------------------------------+
    | remaining: GZip compressed       |
    |  frame data (one frame per line, |
    |  double-newline between frames)  |
    +----------------------------------+

.PARAMETER Frames
    ASCII 帧数组（string[][]）。

.PARAMETER CacheKey
    缓存键（由 Get-CacheKey 生成）。

.PARAMETER CacheDir
    缓存目录。

.PARAMETER VideoPath
    视频路径（存入元数据）。

.PARAMETER Width
    输出宽度（存入元数据）。

.PARAMETER Height
    输出高度（存入元数据）。

.PARAMETER Fps
    帧率（存入元数据）。

.PARAMETER CharGradient
    字符梯度（存入元数据）。

.PARAMETER MaxFrameCount
    最大帧数上限（存入元数据）。

.EXAMPLE
    Save-AsciiFrameCache -Frames $allFrames -CacheKey $key -CacheDir ".\cache" -VideoPath "movie.mp4" -Width 120 -Height 40 -Fps 30
#>

function Save-AsciiFrameCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[][]]$Frames,

        [Parameter(Mandatory = $true)]
        [string]$CacheKey,

        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $true)]
        [string]$VideoPath,

        [Parameter(Mandatory = $true)]
        [int]$Width,

        [Parameter(Mandatory = $true)]
        [int]$Height,

        [Parameter(Mandatory = $true)]
        [int]$Fps,

        [Parameter(Mandatory = $true)]
        [string]$CharGradient,

        [Parameter(Mandatory = $false)]
        [int]$MaxFrameCount = 3000
    )

    begin {
        Write-Verbose "保存缓存: $CacheKey"
    }

    process {
        try {
            # 确保缓存目录存在
            if (-not (Test-Path $CacheDir)) {
                New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            }

            $cachePath = Join-Path $CacheDir "$CacheKey.cache"

            # 构建 JSON 元数据
            $metadata = [PSCustomObject]@{
                Version       = 1
                CreatedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                VideoPath     = $VideoPath
                Width         = $Width
                Height        = $Height
                Fps           = $Fps
                CharGradient  = $CharGradient
                MaxFrameCount = $MaxFrameCount
                FrameCount    = $Frames.Count
            }
            $metadataJson = $metadata | ConvertTo-Json -Compress
            $metadataBytes = [System.Text.Encoding]::UTF8.GetBytes($metadataJson)

            # 组装帧数据：每帧用换行符连接，帧之间用两个换行符分隔
            $frameStrings = New-Object System.Collections.Generic.List[string]($Frames.Count)
            foreach ($frame in $Frames) {
                $frameStrings.Add(($frame -join [Environment]::NewLine))
            }
            $frameData = $frameStrings -join "`n`n"
            $frameBytes = [System.Text.Encoding]::UTF8.GetBytes($frameData)

            # GZip 压缩帧数据
            $compressedStream = New-Object System.IO.MemoryStream
            $gzipStream = $null
            try {
                $gzipStream = New-Object System.IO.Compression.GZipStream(
                    $compressedStream,
                    [System.IO.Compression.CompressionMode]::Compress
                )
                $gzipStream.Write($frameBytes, 0, $frameBytes.Length)
            }
            finally {
                if ($gzipStream) { $gzipStream.Dispose() }
                $compressedStream.Dispose()
            }
            $compressedBytes = $compressedStream.ToArray()

            # 写入文件：元数据长度（Big-Endian Int32）+ 元数据 JSON + 压缩帧数据
            $fileStream = [System.IO.File]::Create($cachePath)
            $writer = $null
            try {
                $writer = New-Object System.IO.BinaryWriter($fileStream)

                # 写入元数据长度（Big-Endian）
                $lengthBytes = [System.BitConverter]::GetBytes($metadataBytes.Length)
                if ([System.BitConverter]::IsLittleEndian) {
                    [Array]::Reverse($lengthBytes)
                }
                $writer.Write($lengthBytes)

                # 写入元数据
                $writer.Write($metadataBytes)

                # 写入压缩帧数据
                $writer.Write($compressedBytes)
            }
            finally {
                if ($writer) { $writer.Dispose() }
                $fileStream.Dispose()
            }

            $cacheSizeKB = [math]::Round((Get-Item $cachePath).Length / 1KB, 1)
            $msg = "缓存已保存: $cachePath ($cacheSizeKB KB)"
            Write-Verbose $msg
            Write-Host $msg -ForegroundColor Gray
        }
        catch {
            Write-Error "缓存保存失败: $($_.Exception.Message)"
            # 不抛出，缓存失败不应中断播放
        }
    }
}

# ============================================================
# 缓存加载
# ============================================================

<#
.SYNOPSIS
    从缓存文件加载 ASCII 帧数组。

.PARAMETER CacheKey
    缓存键。

.PARAMETER CacheDir
    缓存目录。

.EXAMPLE
    $frames = Load-AsciiFrameCache -CacheKey $key -CacheDir ".\cache"

.OUTPUTS
    PSCustomObject { Frames: string[][], Metadata: PSCustomObject }
    缓存失效时返回 $null。
#>

function Load-AsciiFrameCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CacheKey,

        [Parameter(Mandatory = $true)]
        [string]$CacheDir
    )

    begin {
        Write-Verbose "加载缓存: $CacheKey"
    }

    process {
        try {
            $cachePath = Join-Path $CacheDir "$CacheKey.cache"

            if (-not (Test-Path $cachePath -PathType Leaf)) {
                Write-Verbose "缓存文件不存在: $cachePath"
                return $null
            }

            # 读取文件
            $fileBytes = [System.IO.File]::ReadAllBytes($cachePath)
            $stream = New-Object System.IO.MemoryStream(@(, $fileBytes))
            $reader = New-Object System.IO.BinaryReader($stream)

            # 读取元数据长度（Big-Endian Int32）
            $lengthBytes = $reader.ReadBytes(4)
            if ([System.BitConverter]::IsLittleEndian) {
                [Array]::Reverse($lengthBytes)
            }
            $metadataLength = [System.BitConverter]::ToInt32($lengthBytes, 0)

            # 读取并解析 JSON 元数据
            $metadataJsonBytes = $reader.ReadBytes($metadataLength)
            $metadataJson = [System.Text.Encoding]::UTF8.GetString($metadataJsonBytes)
            $metadata = $metadataJson | ConvertFrom-Json

            # 读取压缩帧数据
            $remainingLength = $stream.Length - $stream.Position
            $compressedBytes = $reader.ReadBytes([int]$remainingLength)

            $reader.Close()
            $stream.Dispose()

            # GZip 解压
            $compressedStream = New-Object System.IO.MemoryStream(@(, $compressedBytes))
            $gzipStream = New-Object System.IO.Compression.GZipStream(
                $compressedStream,
                [System.IO.Compression.CompressionMode]::Decompress
            )
            $outputStream = New-Object System.IO.MemoryStream
            $gzipStream.CopyTo($outputStream)
            $gzipStream.Close()
            $compressedStream.Dispose()

            $frameData = [System.Text.Encoding]::UTF8.GetString($outputStream.ToArray())
            $outputStream.Dispose()

            # 拆分帧数据：双换行符分隔各帧
            $frameStrings = $frameData -split "`r`n`r`n|`n`n"
            $frames = New-Object System.Collections.Generic.List[string[]]
            foreach ($fs in $frameStrings) {
                $lines = $fs -split "`r`n|`n"
                $frames.Add([string[]]$lines)
            }

            Write-Host "缓存已加载: $($frames.Count) 帧 (创建于 $($metadata.CreatedAt))" -ForegroundColor Green

            return [PSCustomObject]@{
                Frames   = $frames.ToArray()
                Metadata = $metadata
            }
        }
        catch {
            Write-Warning "缓存加载失败: $($_.Exception.Message)，将重新生成"
            return $null
        }
    }
}

# ============================================================
# 缓存校验
# ============================================================

<#
.SYNOPSIS
    校验缓存是否有效（存在、未过期、参数匹配）。

.PARAMETER CacheKey
    缓存键。

.PARAMETER CacheDir
    缓存目录。

.PARAMETER ExpireDays
    缓存过期天数，超过此天数自动失效。

.PARAMETER VideoPath
    视频路径（用于额外验证）。

.PARAMETER Width
    Width（用于额外验证）。

.PARAMETER Height
    Height（用于额外验证）。

.PARAMETER Fps
    Fps（用于额外验证）。

.PARAMETER CharGradient
    CharGradient（用于额外验证）。

.EXAMPLE
    if (Test-CacheValid -CacheKey $key -CacheDir ".\cache" -ExpireDays 30) { ... }

.OUTPUTS
    bool。有效返回 $true，无效返回 $false。
#>

function Test-CacheValid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CacheKey,

        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $false)]
        [int]$ExpireDays = 30,

        [Parameter(Mandatory = $false)]
        [string]$VideoPath,

        [Parameter(Mandatory = $false)]
        [int]$Width,

        [Parameter(Mandatory = $false)]
        [int]$Height,

        [Parameter(Mandatory = $false)]
        [int]$Fps,

        [Parameter(Mandatory = $false)]
        [string]$CharGradient
    )

    $cachePath = Join-Path $CacheDir "$CacheKey.cache"

    # 检查文件存在
    if (-not (Test-Path $cachePath -PathType Leaf)) {
        Write-Verbose "缓存未命中: 文件不存在"
        return $false
    }

    # 检查是否过期
    if ($ExpireDays -gt 0) {
        $fileAge = (Get-Date) - (Get-Item $cachePath).LastWriteTime
        if ($fileAge.TotalDays -gt $ExpireDays) {
            $age = [math]::Round($fileAge.TotalDays, 1)
            Write-Verbose "缓存已过期 ($ExpireDays 天): $age 天前"
            return $false
        }
    }

    # 如果提供了参数，进行深度校验（读取元数据比对）
    if ($VideoPath) {
        try {
            $fileBytes = [System.IO.File]::ReadAllBytes($cachePath)
            $stream = New-Object System.IO.MemoryStream(@(, $fileBytes))
            $reader = New-Object System.IO.BinaryReader($stream)

            $lengthBytes = $reader.ReadBytes(4)
            if ([System.BitConverter]::IsLittleEndian) {
                [Array]::Reverse($lengthBytes)
            }
            $metadataLength = [System.BitConverter]::ToInt32($lengthBytes, 0)
            $metadataJsonBytes = $reader.ReadBytes($metadataLength)
            $reader.Close()
            $stream.Dispose()

            $metadataJson = [System.Text.Encoding]::UTF8.GetString($metadataJsonBytes)
            $metadata = $metadataJson | ConvertFrom-Json

            # 逐字段比对
            $videoAbsPath = (Resolve-Path $VideoPath -ErrorAction SilentlyContinue).Path
            if (-not $videoAbsPath) { $videoAbsPath = $VideoPath }

            if ($metadata.VideoPath -ne $videoAbsPath) {
                Write-Verbose "缓存参数不匹配: VideoPath"
                return $false
            }
            if ($Width -gt 0 -and $metadata.Width -ne $Width) {
                Write-Verbose "缓存参数不匹配: Width ($($metadata.Width) vs $Width)"
                return $false
            }
            if ($Height -gt 0 -and $metadata.Height -ne $Height) {
                Write-Verbose "缓存参数不匹配: Height ($($metadata.Height) vs $Height)"
                return $false
            }
            if ($Fps -gt 0 -and $metadata.Fps -ne $Fps) {
                Write-Verbose "缓存参数不匹配: Fps ($($metadata.Fps) vs $Fps)"
                return $false
            }
            if ($CharGradient -and $metadata.CharGradient -ne $CharGradient) {
                Write-Verbose "缓存参数不匹配: CharGradient"
                return $false
            }
        }
        catch {
            Write-Verbose "缓存元数据读取失败，视为无效: $($_.Exception.Message)"
            return $false
        }
    }

    return $true
}

# ============================================================
# 缓存清理
# ============================================================

<#
.SYNOPSIS
    清理过期的缓存文件。

.DESCRIPTION
    扫描缓存目录，删除超过指定天数的缓存文件。

.PARAMETER CacheDir
    缓存目录。

.PARAMETER ExpireDays
    过期天数。

.EXAMPLE
    $removed = Clear-ExpiredCache -CacheDir ".\cache" -ExpireDays 30

.OUTPUTS
    int。清理的缓存文件数量。
#>

function Clear-ExpiredCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $false)]
        [int]$ExpireDays = 30
    )

    if (-not (Test-Path $CacheDir)) { return 0 }

    $cutoff = (Get-Date).AddDays(-$ExpireDays)
    $expiredFiles = @(Get-ChildItem -Path $CacheDir -Filter "*.cache" `
        | Where-Object { $_.LastWriteTime -lt $cutoff })

    foreach ($file in $expiredFiles) {
        Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
        Write-Verbose "已删除过期缓存: $($file.Name)"
    }

    if ($expiredFiles.Count -gt 0) {
        Write-Host "已清理 $($expiredFiles.Count) 个过期缓存" -ForegroundColor Gray
    }
    return $expiredFiles.Count
}

# 注：本文件通过 dot-source 加载（. .\file.ps1），所有函数自动可用
