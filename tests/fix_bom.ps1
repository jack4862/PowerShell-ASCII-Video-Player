# Fix: strip any existing BOM, then re-save with single UTF-8 BOM
$utf8BOM = New-Object System.Text.UTF8Encoding $true

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

# 扫描项目下所有 .ps1 文件
$files = Get-ChildItem -Path $projectRoot -Filter "*.ps1" -Recurse |
    Select-Object -ExpandProperty FullName

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f)

    # Strip BOM(s) — look for 0xEF,0xBB,0xBF prefix
    while ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($f, $text, $utf8BOM)

    # Verify
    $check = [System.IO.File]::ReadAllBytes($f)[0..2]
    Write-Host ("$f : BOM check = " + ($check[0]) + "," + ($check[1]) + "," + ($check[2]))
}
