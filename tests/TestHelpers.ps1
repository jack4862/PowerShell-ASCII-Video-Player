# Test Helpers — dot-source in Pester BeforeAll blocks
function New-TestImage {
    param (
        [string]$Path,
        [System.Drawing.Color]$Color,
        [int]$Width = 10,
        [int]$Height = 10
    )
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear($Color)
    $graphics.Dispose()
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

function New-GradientTestImage {
    param (
        [string]$Path,
        [int]$Width = 256,
        [int]$Height = 1
    )
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    for ($x = 0; $x -lt $Width; $x++) {
        $gray = [Math]::Min($x, 255)
        $color = [System.Drawing.Color]::FromArgb($gray, $gray, $gray)
        for ($y = 0; $y -lt $Height; $y++) {
            $bitmap.SetPixel($x, $y, $color)
        }
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
