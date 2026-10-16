# 02-trace-start.ps1  --  start an ETW trace of the AMD camera driver (amdcamera.sys).   UNTESTED (written on Linux).
#
# Run in an ELEVATED (Administrator) Windows PowerShell:
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\02-trace-start.ps1
#
# What it does: starts an ETW session named "amdcam" that listens to the driver's WPP control GUID
#     {0FBF5BB9-E551-475A-A9C0-B98F2EA1A4AD}
# (read from the amdcamera.sys installed on this machine, SHA256 2376fd79...4263: the driver stores it in .rdata at
# 0x1400aaa20 and registers it in its WPP init; all flags, level 5).  If the installed driver has changed since,
# this GUID may no longer match.  The session is "-ets" = created directly in memory-backed form, nothing is
# installed or changed permanently; it disappears at reboot or with 02-trace-stop.ps1.
# Output file:  %USERPROFILE%\Documents\camera-bringup-windows\amdcam.etl
#
# Then:  1. open the Camera app, switch to the REAR camera, let the preview run ~10 s
#        2. take one photo, record ~5 s of video (the driver may use other sensor modes for these)
#        3. close the app
#        4. run 02-trace-stop.ps1
# Why: the driver logs its own function names and the firmware's log through WPP.  This gives a working-run
# reference (command order, buffer types/sizes, selected sensor mode, firmware messages) to diff against Linux.
# Does not read or write any hardware register.

$ErrorActionPreference = 'Stop'
$guid = '{0FBF5BB9-E551-475A-A9C0-B98F2EA1A4AD}'
$out  = Join-Path $env:USERPROFILE 'Documents\camera-bringup-windows'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$etl  = Join-Path $out 'amdcam.etl'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated (Administrator) PowerShell.' }

# remove a stale session of the same name; "no such session" is normal, so errors must not stop the script here
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & logman stop amdcam -ets 2>&1 | Out-Null } catch { }
$ErrorActionPreference = $prev

# 0xFFFFFFFF = all flags, 0x5 = level 5 (verbose).  Large buffers so a short run is not truncated.
& logman create trace amdcam -p $guid 0xFFFFFFFF 0x5 -o $etl -ets -bs 256 -nb 64 256 -max 512
if ($LASTEXITCODE -ne 0) { throw "logman failed with exit code $LASTEXITCODE" }

Write-Output "Trace 'amdcam' is running -> $etl"
Write-Output 'Now use the REAR camera in the Camera app (preview ~10 s, one photo, ~5 s video), close the app, then run 02-trace-stop.ps1'
