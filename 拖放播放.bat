@echo off
if "%~1"=="" (
    powershell.exe -Command "Write-Host '请把视频文件拖放到此 bat 文件上' -ForegroundColor Yellow"
    pause
    exit /b 1
)
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Play-AsciiVideo.ps1" -VideoPath "%~1"
pause
