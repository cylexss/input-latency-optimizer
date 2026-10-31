# Input Latency Optimizer - web launcher
# Usage (normal PowerShell window):
#   irm https://raw.githubusercontent.com/cylexss/input-latency-optimizer/main/install.ps1 | iex
#
# Downloads the app from the latest GitHub release to %TEMP% and starts it with an admin prompt.
# Wrapped in & { } so nothing leaks into (or closes) the PowerShell window you ran it from.
& {
    $ErrorActionPreference = 'Stop'
    $url  = 'https://github.com/cylexss/input-latency-optimizer/releases/latest/download/InputLatencyOptimizer.ps1'
    $file = Join-Path $env:TEMP 'InputLatencyOptimizer.ps1'

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        Write-Host 'Downloading Input Latency Optimizer...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        Write-Host 'Starting - approve the administrator prompt.' -ForegroundColor Cyan
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$file`"")
    } catch {
        Write-Host "Could not start Input Latency Optimizer: $($_.Exception.Message)" -ForegroundColor Red
    }
}
