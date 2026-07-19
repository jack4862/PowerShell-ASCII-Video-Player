#Requires -Version 5.1

<#
.SYNOPSIS
    ASCII 视频播放器单元测试。

.DESCRIPTION
    使用 Pester 5.x/6.x 测试框架验证核心模块的正确性。
    运行方式: Invoke-Pester .\tests\AsciiVideo.Tests.ps1

.NOTES
    测试通过 System.Drawing 动态创建测试图片，无需外部测试文件。

    Pester v6 兼容性说明：
    Pester v6 的 Invoke-InNewScriptScope 隔离了 BeforeAll/AfterAll
    的变量作用域，因此每个 Describe 块在其 BeforeAll 中独立加载
    模块并通过环境变量获取项目根路径。
#>

# ============================================================
# 路径解析和模块预加载
# ============================================================

if ($PSScriptRoot) {
    $env:ASCIITEST_ROOT = Split-Path -Parent $PSScriptRoot
}
elseif (Test-Path (Join-Path $PWD "Play-AsciiVideo.ps1")) {
    $env:ASCIITEST_ROOT = $PWD
}
elseif (Test-Path (Join-Path $PWD "..\Play-AsciiVideo.ps1")) {
    $env:ASCIITEST_ROOT = (Resolve-Path (Join-Path $PWD "..")).Path
}
else {
    throw "无法确定项目根路径。请从项目根目录或 tests 目录运行测试。"
}

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# 预加载帮助函数和核心模块到脚本作用域（Pester v6 会隔离 BeforeAll，
# 但顶层作用域的函数仍能被 Describe 块外部的代码使用）
. (Join-Path $env:ASCIITEST_ROOT "tests\TestHelpers.ps1")
. (Join-Path $env:ASCIITEST_ROOT "lib\ConvertTo-AsciiFrame.ps1")
. (Join-Path $env:ASCIITEST_ROOT "lib\Save-AsciiCache.ps1")
. (Join-Path $env:ASCIITEST_ROOT "lib\Invoke-FfmpegExtract.ps1")
. (Join-Path $env:ASCIITEST_ROOT "lib\Write-ConsoleFrame.ps1")

# ============================================================
# ConvertTo-AsciiFrame 测试
# ============================================================

Describe "ConvertTo-AsciiFrame" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "tests\TestHelpers.ps1")
        . (Join-Path $root "lib\ConvertTo-AsciiFrame.ps1")

        $testDir = Join-Path $root "tests\test_temp"
        if (-not (Test-Path $testDir)) {
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        }
        $testBlack   = Join-Path $testDir "test_black.png"
        $testWhite   = Join-Path $testDir "test_white.png"
        $testMidGray = Join-Path $testDir "test_midgray.png"
        $testGradient = Join-Path $testDir "test_gradient.png"

        New-TestImage -Path $testBlack -Color ([System.Drawing.Color]::Black) -Width 20 -Height 10
        New-TestImage -Path $testWhite -Color ([System.Drawing.Color]::White) -Width 20 -Height 10
        New-TestImage -Path $testMidGray -Color ([System.Drawing.Color]::FromArgb(128, 128, 128)) -Width 20 -Height 10
        New-GradientTestImage -Path $testGradient -Width 10 -Height 1
    }

    AfterAll {
        if (Test-Path $testDir) {
            Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "基本功能" {
        It "返回正确的行数" {
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 10 -Height 5
            $result.Count | Should -Be 5
        }
        It "返回的每行长度正确" {
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 15 -Height 8
            foreach ($line in $result) { $line.Length | Should -Be 15 }
        }
        It "接受默认参数" {
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack
            $result.Count | Should -Be 40
            $result[0].Length | Should -Be 80
        }
    }

    Context "灰度映射" {
        It "纯黑图片映射到最暗字符" {
            $gradient = " .:-=+*#%@"
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 1 -Height 1 -CharGradient $gradient
            $result[0] | Should -Be $gradient[0]
        }
        It "纯白图片映射到最亮字符" {
            $gradient = " .:-=+*#%@"
            $result = ConvertTo-AsciiFrame -ImagePath $testWhite -Width 1 -Height 1 -CharGradient $gradient
            $result[0] | Should -Be $gradient[-1]
        }
        It "中间灰映射在梯度中间区域" {
            $gradient = " .:-=+*#%@"
            $result = ConvertTo-AsciiFrame -ImagePath $testMidGray -Width 1 -Height 1 -CharGradient $gradient
            $actualIndex = $gradient.IndexOf($result[0])
            $actualIndex | Should -BeIn (3..5)
        }
    }

    Context "边界条件" {
        It "梯度为两个字符时正确工作" {
            $gradient = " ."
            $blackResult = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 1 -Height 1 -CharGradient $gradient
            $whiteResult = ConvertTo-AsciiFrame -ImagePath $testWhite -Width 1 -Height 1 -CharGradient $gradient
            $blackResult[0] | Should -Be ' '
            $whiteResult[0] | Should -Be '.'
        }
        It "宽度为 1 时也正常工作" {
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 1 -Height 20
            $result.Count | Should -Be 20
            $result[0].Length | Should -Be 1
        }
        It "高度为 2 时也正常工作" {
            $result = ConvertTo-AsciiFrame -ImagePath $testBlack -Width 30 -Height 2
            $result.Count | Should -Be 2
            $result[0].Length | Should -Be 30
        }
    }

    Context "错误处理" {
        It "文件不存在时抛出错误" {
            $nonExistent = Join-Path $testDir "does_not_exist.png"
            { ConvertTo-AsciiFrame -ImagePath $nonExistent -Width 10 -Height 10 } | Should -Throw
        }
    }

    Context "梯度一致性" {
        It "灰度渐变的各像素灰度值递增" {
            $gradient = " .:-=+*#%@"
            $result = ConvertTo-AsciiFrame -ImagePath $testGradient -Width 10 -Height 2 -CharGradient $gradient
            $prevIndex = -1
            for ($i = 0; $i -lt 10; $i++) {
                $currentIndex = $gradient.IndexOf($result[0][$i])
                $currentIndex | Should -BeGreaterOrEqual $prevIndex
                $prevIndex = $currentIndex
            }
        }
    }
}

# ============================================================
# Get-ConsoleCharSize 测试
# ============================================================

Describe "Get-ConsoleCharSize" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Write-ConsoleFrame.ps1")
        # 检测是否在控制台环境中（Pester headless 模式下控制台不可用）
        $consoleAvailable = $true
        try {
            $null = [Console]::WindowHeight
        } catch {
            $consoleAvailable = $false
        }
    }

    It "返回正数的宽度和高度" -Skip:(-not $consoleAvailable) {
        $size = Get-ConsoleCharSize -HeightMargin 2
        $size.Width | Should -BeGreaterThan 0
        $size.Height | Should -BeGreaterThan 0
    }

    It "高度应等于控制台窗口高度减去边距" -Skip:(-not $consoleAvailable) {
        $expectedHeight = [Console]::WindowHeight - 2
        $size = Get-ConsoleCharSize -HeightMargin 2
        $size.Height | Should -Be $expectedHeight
    }
}

# ============================================================
# BT.601 灰度公式验证
# ============================================================

Describe "灰度计算公式验证" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "tests\TestHelpers.ps1")
        . (Join-Path $root "lib\ConvertTo-AsciiFrame.ps1")

        $testDir = Join-Path $root "tests\test_temp_bt601"
        if (-not (Test-Path $testDir)) {
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        }
        $redImage   = Join-Path $testDir "test_red.png"
        $greenImage = Join-Path $testDir "test_green.png"
        $blueImage  = Join-Path $testDir "test_blue.png"

        New-TestImage -Path $redImage -Color ([System.Drawing.Color]::Red) -Width 1 -Height 1
        New-TestImage -Path $greenImage -Color ([System.Drawing.Color]::Lime) -Width 1 -Height 1
        New-TestImage -Path $blueImage -Color ([System.Drawing.Color]::Blue) -Width 1 -Height 1
    }

    AfterAll {
        if (Test-Path $testDir) {
            Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "BT.601 公式对纯红色计算结果约为 76" {
        $result = ConvertTo-AsciiFrame -ImagePath $redImage -Width 1 -Height 1 -CharGradient " .:-=+*#%@"
        $actualIndex = " .:-=+*#%@".IndexOf($result[0])
        $actualIndex | Should -BeIn @(2, 3)
    }

    It "BT.601 公式对纯绿色计算结果约为 150" {
        $result = ConvertTo-AsciiFrame -ImagePath $greenImage -Width 1 -Height 1 -CharGradient " .:-=+*#%@"
        $actualIndex = " .:-=+*#%@".IndexOf($result[0])
        $actualIndex | Should -BeIn @(4, 5, 6)
    }

    It "BT.601 公式对纯蓝色计算结果约为 29" {
        $result = ConvertTo-AsciiFrame -ImagePath $blueImage -Width 1 -Height 1 -CharGradient " .:-=+*#%@"
        $actualIndex = " .:-=+*#%@".IndexOf($result[0])
        $actualIndex | Should -BeIn @(0, 1, 2)
    }
}

# ============================================================
# Get-CacheKey 测试
# ============================================================

Describe "Get-CacheKey" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Save-AsciiCache.ps1")
    }

    It "相同参数产生相同键" {
        $key1 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key2 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key1 | Should -Be $key2
    }

    It "不同视频路径产生不同键" {
        $key1 = Get-CacheKey -VideoPath "a.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key2 = Get-CacheKey -VideoPath "b.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key1 | Should -Not -Be $key2
    }

    It "不同尺寸产生不同键" {
        $key1 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key2 = Get-CacheKey -VideoPath "test.mp4" -Width 200 -Height 80 -Fps 30 -CharGradient " .:-=+*#%@"
        $key1 | Should -Not -Be $key2
    }

    It "不同帧率产生不同键" {
        $key1 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 15 -CharGradient " .:-=+*#%@"
        $key2 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key1 | Should -Not -Be $key2
    }

    It "不同字符梯度产生不同键" {
        $key1 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key2 = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient "@%#*+=-:. "
        $key1 | Should -Not -Be $key2
    }

    It "返回的是 SHA256 格式的十六进制字符串" {
        $key = Get-CacheKey -VideoPath "test.mp4" -Width 100 -Height 40 -Fps 30 -CharGradient " .:-=+*#%@"
        $key.Length | Should -Be 64
        $key -match '^[0-9a-f]{64}$' | Should -BeTrue
    }
}

# ============================================================
# Save-AsciiFrameCache / Load-AsciiFrameCache 测试
# ============================================================

Describe "Save-AsciiFrameCache / Load-AsciiFrameCache" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Save-AsciiCache.ps1")
        . (Join-Path $root "config.ps1")

        $saveTestDir = Join-Path $root "tests\test_temp_cache_save"
        if (-not (Test-Path $saveTestDir)) {
            New-Item -ItemType Directory -Path $saveTestDir -Force | Out-Null
        }
    }

    AfterAll {
        if (Test-Path $saveTestDir) {
            Remove-Item -Path $saveTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "保存并加载的帧数据一致" {
        $originalFrames = @(
            @("abc", "def", "ghi"),
            @("123", "456", "789"),
            @("xyz", "uvw", "rst")
        )
        $key = Get-CacheKey -VideoPath "roundtrip.mp4" -Width 3 -Height 3 -Fps 30 -CharGradient " .:-=+*#%@"
        Save-AsciiFrameCache -Frames $originalFrames -CacheKey $key -CacheDir $saveTestDir -VideoPath "roundtrip.mp4" -Width 3 -Height 3 -Fps 30 -CharGradient " .:-=+*#%@"
        $result = Load-AsciiFrameCache -CacheKey $key -CacheDir $saveTestDir

        $result | Should -Not -BeNullOrEmpty
        $result.Frames.Count | Should -Be 3
        $result.Frames[0][0] | Should -Be "abc"
        $result.Frames[1][1] | Should -Be "456"
        $result.Frames[2][2] | Should -Be "rst"
    }

    It "元数据正确保存" {
        $originalFrames = @(@("line1"), @("line2"))
        $key = Get-CacheKey -VideoPath "meta.mp4" -Width 5 -Height 2 -Fps 24 -CharGradient "@#"
        Save-AsciiFrameCache -Frames $originalFrames -CacheKey $key -CacheDir $saveTestDir -VideoPath "meta.mp4" -Width 5 -Height 2 -Fps 24 -CharGradient "@#" -MaxFrameCount 5000
        $result = Load-AsciiFrameCache -CacheKey $key -CacheDir $saveTestDir

        $result.Metadata.Width | Should -Be 5
        $result.Metadata.Height | Should -Be 2
        $result.Metadata.Fps | Should -Be 24
        $result.Metadata.CharGradient | Should -Be "@#"
        $result.Metadata.MaxFrameCount | Should -Be 5000
        $result.Metadata.FrameCount | Should -Be 2
    }

    It "不存在的缓存文件返回 null" {
        $result = Load-AsciiFrameCache -CacheKey "nonexistent_key" -CacheDir $saveTestDir
        $result | Should -BeNullOrEmpty
    }
}

# ============================================================
# Test-CacheValid 测试
# ============================================================

Describe "Test-CacheValid" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Save-AsciiCache.ps1")

        $validTestDir = Join-Path $root "tests\test_temp_cache_valid"
        if (-not (Test-Path $validTestDir)) {
            New-Item -ItemType Directory -Path $validTestDir -Force | Out-Null
        }
    }

    AfterAll {
        if (Test-Path $validTestDir) {
            Remove-Item -Path $validTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "不存在的缓存返回 false" {
        Test-CacheValid -CacheKey "not_exist" -CacheDir $validTestDir -ExpireDays 30 | Should -BeFalse
    }

    It "有效缓存返回 true" {
        $key = Get-CacheKey -VideoPath "valid.mp4" -Width 10 -Height 10 -Fps 30 -CharGradient " .:"
        $frames = @(@("abc"))
        Save-AsciiFrameCache -Frames $frames -CacheKey $key -CacheDir $validTestDir -VideoPath "valid.mp4" -Width 10 -Height 10 -Fps 30 -CharGradient " .:"
        Test-CacheValid -CacheKey $key -CacheDir $validTestDir -ExpireDays 30 -VideoPath "valid.mp4" -Width 10 -Height 10 -Fps 30 -CharGradient " .:" | Should -BeTrue
    }

    It "参数不匹配返回 false" {
        $key = Get-CacheKey -VideoPath "mismatch.mp4" -Width 10 -Height 10 -Fps 30 -CharGradient " .:"
        $frames = @(@("abc"))
        Save-AsciiFrameCache -Frames $frames -CacheKey $key -CacheDir $validTestDir -VideoPath "mismatch.mp4" -Width 10 -Height 10 -Fps 30 -CharGradient " .:"
        Test-CacheValid -CacheKey $key -CacheDir $validTestDir -ExpireDays 30 -VideoPath "mismatch.mp4" -Width 99 -Height 10 -Fps 30 -CharGradient " .:" | Should -BeFalse
    }
}

# ============================================================
# Clear-ExpiredCache 测试
# ============================================================

Describe "Clear-ExpiredCache" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Save-AsciiCache.ps1")

        $clearTestDir = Join-Path $root "tests\test_temp_cache_clear"
        if (-not (Test-Path $clearTestDir)) {
            New-Item -ItemType Directory -Path $clearTestDir -Force | Out-Null
        }
    }

    AfterAll {
        if (Test-Path $clearTestDir) {
            Remove-Item -Path $clearTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "返回清理数量（整数）" {
        $count = Clear-ExpiredCache -CacheDir $clearTestDir -ExpireDays 30
        $count | Should -BeOfType ([int])
    }
}

# ============================================================
# Find-FfmpegPath 测试
# ============================================================

Describe "Find-FfmpegPath" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "lib\Invoke-FfmpegExtract.ps1")
    }

    It "函数存在且可调用" {
        { Find-FfmpegPath } | Should -Not -Throw
    }

    It "返回 string 或 null" {
        $result = Find-FfmpegPath
        if ($null -ne $result) {
            $result | Should -BeOfType ([string])
        }
    }
}

# ============================================================
# LockBits 重构验证
# ============================================================

Describe "LockBits 重构验证" {

    BeforeAll {
        $root = $env:ASCIITEST_ROOT
        . (Join-Path $root "tests\TestHelpers.ps1")
        . (Join-Path $root "lib\ConvertTo-AsciiFrame.ps1")

        $lockTestDir = Join-Path $root "tests\test_temp_lockbits"
        if (-not (Test-Path $lockTestDir)) {
            New-Item -ItemType Directory -Path $lockTestDir -Force | Out-Null
        }

        $testBlack2   = Join-Path $lockTestDir "test_black.png"
        $testWhite2   = Join-Path $lockTestDir "test_white.png"
        $testMidGray2 = Join-Path $lockTestDir "test_midgray.png"
        $testGradient2 = Join-Path $lockTestDir "test_gradient.png"

        New-TestImage -Path $testBlack2 -Color ([System.Drawing.Color]::Black) -Width 20 -Height 10
        New-TestImage -Path $testWhite2 -Color ([System.Drawing.Color]::White) -Width 20 -Height 10
        New-TestImage -Path $testMidGray2 -Color ([System.Drawing.Color]::FromArgb(128, 128, 128)) -Width 20 -Height 10
        New-GradientTestImage -Path $testGradient2 -Width 10 -Height 1
    }

    AfterAll {
        if (Test-Path $lockTestDir) {
            Remove-Item -Path $lockTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "纯黑图片转换结果不变" {
        $gradient = " .:-=+*#%@"
        $result = ConvertTo-AsciiFrame -ImagePath $testBlack2 -Width 1 -Height 1 -CharGradient $gradient
        $result[0] | Should -Be $gradient[0]
    }

    It "纯白图片转换结果不变" {
        $gradient = " .:-=+*#%@"
        $result = ConvertTo-AsciiFrame -ImagePath $testWhite2 -Width 1 -Height 1 -CharGradient $gradient
        $result[0] | Should -Be $gradient[-1]
    }

    It "中间灰图片映射结果在中间范围" {
        $gradient = " .:-=+*#%@"
        $result = ConvertTo-AsciiFrame -ImagePath $testMidGray2 -Width 1 -Height 1 -CharGradient $gradient
        $actualIndex = $gradient.IndexOf($result[0])
        $actualIndex | Should -BeIn (3..5)
    }

    It "灰度渐变保持非递减" {
        $gradient = " .:-=+*#%@"
        $result = ConvertTo-AsciiFrame -ImagePath $testGradient2 -Width 10 -Height 2 -CharGradient $gradient
        $prevIndex = -1
        for ($i = 0; $i -lt 10; $i++) {
            $currentIndex = $gradient.IndexOf($result[0][$i])
            $currentIndex | Should -BeGreaterOrEqual $prevIndex
            $prevIndex = $currentIndex
        }
    }
}

# ============================================================
# 测试运行说明
# ============================================================
# 运行所有测试:
#   Invoke-Pester .\tests\AsciiVideo.Tests.ps1
#
# 运行特定 Describe:
#   Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -TestName "灰度映射"
#
# 带详细输出:
#   Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -Output Detailed
