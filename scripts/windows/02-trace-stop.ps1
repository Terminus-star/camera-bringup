# 02-trace-stop.ps1  --  stop the "amdcam" ETW trace and produce readable exports.   UNTESTED (written on Linux).
#
# Run in an ELEVATED (Administrator) Windows PowerShell, after using the rear camera:
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\02-trace-stop.ps1
#
# Produces, in %USERPROFILE%\Documents\camera-bringup-windows\ :
#   amdcam.etl           the raw trace (the important file; bring it back to Linux)
#   amdcam.csv           tracerpt CSV export
#   amdcam.xml           tracerpt XML export (events with their raw user data)
#   amdcam-summary.txt   event counts
#   driver-info.txt      version / date / hash of amdcamera.sys, so the trace can be matched to the binary
# Without the driver's TMF/PDB the messages are not formatted by Windows; the function names and strings are inside
# the raw user data, which is enough for an offline analysis on the Linux side.

$ErrorActionPreference = 'Continue'
$out = Join-Path $env:USERPROFILE 'Documents\camera-bringup-windows'
$etl = Join-Path $out 'amdcam.etl'

& logman stop amdcam -ets
if (-not (Test-Path $etl)) { throw "No $etl found; did 02-trace-start.ps1 run?" }

& tracerpt $etl -of CSV -o (Join-Path $out 'amdcam.csv') -summary (Join-Path $out 'amdcam-summary.txt') -y
& tracerpt $etl -of XML -o (Join-Path $out 'amdcam.xml') -y

$sys = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
Get-ChildItem -Path $sys -Recurse -Filter amdcamera.sys -ErrorAction SilentlyContinue |
    ForEach-Object {
        '{0}  {1} bytes  {2}  SHA256 {3}' -f $_.FullName, $_.Length, $_.VersionInfo.FileVersion, (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    } | Set-Content -Path (Join-Path $out 'driver-info.txt')

Get-ChildItem $out | Format-Table Name, Length -AutoSize
Write-Output "Done. Copy the folder $out back to the Linux side (the .etl is the one that matters)."
