#Requires -Version 5.1

<#
.SYNOPSIS
    将图片文件转换为 ASCII 字符帧。

.DESCRIPTION
    加载指定图片，缩放至目标尺寸，逐像素计算灰度值（BT.601 公式），
    并将灰度值映射到字符梯度串中的对应字符，返回字符串数组。
    每行字符串长度等于目标宽度，数组长度等于目标高度。

.PARAMETER ImagePath
    输入图片文件的完整路径（支持 PNG、JPG、BMP 等常见格式）。

.PARAMETER Width
    输出字符帧的宽度（列数），默认 80。

.PARAMETER Height
    输出字符帧的高度（行数），默认 40。

.PARAMETER CharGradient
    字符梯度串，从左到右表示从暗到亮。默认 " .:-=+*#%@"。
    灰度值 0-255 将线性映射到此字符串。

.EXAMPLE
    ConvertTo-AsciiFrame -ImagePath "frame_000001.png" -Width 120 -Height 40

    将 frame_000001.png 转为 120 列 × 40 行的 ASCII 字符帧。

.EXAMPLE
    ConvertTo-AsciiFrame -ImagePath "photo.jpg" -CharGradient "@%#*+=-:. "

    使用反转梯度（亮→暗）转换图片。

.OUTPUTS
    System.String[]。每个元素是一行 ASCII 字符。
#>

function ConvertTo-AsciiFrame {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ImagePath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4096)]
        [int]$Width = 80,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4096)]
        [int]$Height = 40,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CharGradient = " .:-=+*#%@"
    )

    begin {
        $gradientLength = $CharGradient.Length
        Write-Verbose "转换图片: $ImagePath → ${Width}×${Height} (梯度: $gradientLength 级)"
    }

    process {
        try {
            # 加载并缩放图片
            $originalImage = [System.Drawing.Image]::FromFile($ImagePath)
            $bitmap = New-Object System.Drawing.Bitmap($originalImage, $Width, $Height)
            $originalImage.Dispose()

            # 预分配结果数组
            $result = New-Object string[] $Height

            # 构建灰度→字符索引查找表（避免每像素除法计算）
            $charLut = New-Object char[] 256
            for ($i = 0; $i -lt 256; $i++) {
                $idx = [Math]::Floor($i / 255.0 * ($gradientLength - 1))
                if ($idx -ge $gradientLength) { $idx = $gradientLength - 1 }
                $charLut[$i] = $CharGradient[$idx]
            }

            # LockBits 批量读取像素（比 GetPixel 快 ~30-50 倍）
            $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
            $bmpData = $bitmap.LockBits(
                $rect,
                [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
            )

            $stride = $bmpData.Stride
            $bufferSize = $stride * $Height
            $pixelBytes = New-Object byte[] $bufferSize
            [System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $pixelBytes, 0, $bufferSize)
            $bitmap.UnlockBits($bmpData)

            # 逐行构建 ASCII 字符
            # Format32bppArgb 布局: B G R A (每像素 4 字节)
            for ($y = 0; $y -lt $Height; $y++) {
                $sb = New-Object System.Text.StringBuilder($Width)
                $rowOffset = $y * $stride

                for ($x = 0; $x -lt $Width; $x++) {
                    $pixelOffset = $rowOffset + $x * 4
                    $B = $pixelBytes[$pixelOffset]
                    $G = $pixelBytes[$pixelOffset + 1]
                    $R = $pixelBytes[$pixelOffset + 2]

                    # BT.601 亮度公式
                    $gray = [int](0.299 * $R + 0.587 * $G + 0.114 * $B)
                    [void]$sb.Append($charLut[$gray])
                }

                $result[$y] = $sb.ToString()
                try {
                    Write-Progress -Activity "转换图片为 ASCII" `
                        -Status "$($y + 1) / $Height 行" `
                        -PercentComplete (($y + 1) / $Height * 100)
                } catch {
                    # 控制台尺寸变化可能导致 Write-Progress 失败，静默忽略
                }
            }

            try {
                Write-Progress -Activity "转换图片为 ASCII" -Completed
            } catch { }
            return $result
        }
        catch {
            Write-Error "图片转换失败: $($_.Exception.Message)"
            throw
        }
        finally {
            # 确保释放 GDI+ 资源
            if ($bitmap) { $bitmap.Dispose() }
        }
    }
}

<#
.SYNOPSIS
    批量将帧图片目录转换为 ASCII 字符帧数组。

.DESCRIPTION
    扫描指定目录中的帧图片文件（frame_*.png），
    按文件名排序后逐一调用 ConvertTo-AsciiFrame 转换，
    返回字符串数组的数组（每一帧是一个 string[]）。

.PARAMETER FrameDir
    帧图片所在目录。

.PARAMETER Width
    输出字符帧的宽度。

.PARAMETER Height
    输出字符帧的高度。

.PARAMETER CharGradient
    字符梯度串。

.PARAMETER MaxFrameCount
    最大处理帧数上限。

.EXAMPLE
    $frames = ConvertTo-AsciiFrameBatch -FrameDir ".\temp" -Width 120 -Height 40

.OUTPUTS
    System.String[][]，外层是帧索引，内层是行字符串。
#>

function ConvertTo-AsciiFrameBatch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$FrameDir,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4096)]
        [int]$Width = 80,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4096)]
        [int]$Height = 40,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CharGradient = " .:-=+*#%@",

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100000)]
        [int]$MaxFrameCount = 3000,

        [Parameter(Mandatory = $false)]
        [switch]$CacheResult
    )

    begin {
        Write-Verbose "扫描帧图片目录: $FrameDir"
    }

    process {
        try {
            # 获取并排序帧文件
            $frameFiles = @(Get-ChildItem -Path $FrameDir -Filter "frame_*.png" `
                | Sort-Object Name)

            if ($frameFiles.Count -eq 0) {
                Write-Error "目录 $FrameDir 中未找到帧图片（frame_*.png）"
                return $null
            }

            # 限制帧数
            if ($frameFiles.Count -gt $MaxFrameCount) {
                Write-Warning "帧数 $($frameFiles.Count) 超过上限 $MaxFrameCount，仅处理前 $MaxFrameCount 帧"
                $frameFiles = $frameFiles[0..($MaxFrameCount - 1)]
            }

            Write-Host "共 $($frameFiles.Count) 帧待转换" -ForegroundColor Cyan

            # 逐帧转换
            $allFrames = New-Object System.Collections.Generic.List[string[]]
            $frameIndex = 0

            foreach ($file in $frameFiles) {
                $frameIndex++
                try {
                    Write-Progress -Activity "批量转换帧" `
                        -Status "第 $frameIndex / $($frameFiles.Count) 帧 ($($file.Name))" `
                        -PercentComplete ($frameIndex / $frameFiles.Count * 100)
                } catch { }

                $asciiFrame = ConvertTo-AsciiFrame -ImagePath $file.FullName `
                    -Width $Width -Height $Height -CharGradient $CharGradient
                $allFrames.Add($asciiFrame)
            }

            try {
                Write-Progress -Activity "批量转换帧" -Completed
            } catch { }
            Write-Host "转换完成: $($allFrames.Count) 帧" -ForegroundColor Green
            return $allFrames.ToArray()
        }
        catch {
            Write-Error "批量转换失败: $($_.Exception.Message)"
            throw
        }
    }
}

# 注：本文件通过 dot-source 加载（. .\file.ps1），所有函数自动可用
