$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$guiScript = Join-Path $projectRoot "gui\PlayerGui.ps1"

$errors = $null
$tokens = [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content $guiScript -Raw),
    [ref]$errors
)
if ($errors.Count -eq 0) {
    Write-Host "Syntax OK - $(Get-Date)"
} else {
    foreach ($err in $errors) {
        Write-Host "ERROR: $($err.Message)"
    }
}
