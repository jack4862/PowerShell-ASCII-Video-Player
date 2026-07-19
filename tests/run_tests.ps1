Set-Location $PSScriptRoot\..
$result = Invoke-Pester .\tests\AsciiVideo.Tests.ps1 -Output Detailed 2>&1
$result | Out-String
if ($result.FailedCount -gt 0) { exit 1 }
