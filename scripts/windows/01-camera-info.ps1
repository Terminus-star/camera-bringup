# 01-camera-info.ps1  --  READ-ONLY inventory of the cameras and the resolutions Windows exposes.
#
# Run in WINDOWS POWERSHELL 5.1 (the blue "Windows PowerShell", NOT "PowerShell 7"): the WinRT camera API is not
# available in PowerShell 7.  Normal user is enough.   UNTESTED on this machine (written on Linux).
#
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\01-camera-info.ps1
#
# What it does (it changes nothing):
#   1. writes a report to  %USERPROFILE%\Documents\camera-bringup-windows\camera-info.txt
#   2. lists the camera devices (PnP) with driver name / version / date, for the AMD ISP, the sensor driver and the
#      USB webcam
#   3. for every video-capture device, opens it briefly through the WinRT MediaCapture API (this powers the camera
#      path, like opening the Camera app, but does not stream) and lists the stream formats Windows offers for the
#      preview / record / photo streams: width x height, frame rate, pixel format.
# Why: the Windows driver's sensor plug-in exposes three resolution lists (preview up to 2560x1440, video up to
# 3264x2448, stills up to 4208x3120).  We want to see what Windows really exposes for the REAR camera.
# NOTE: this does not tell which SENSOR MODE (0 = 1120 Mbps, 1 = 560 Mbps) the driver uses; that needs the driver
# trace (02-trace-start.ps1).

$ErrorActionPreference = 'Continue'
$out = Join-Path $env:USERPROFILE 'Documents\camera-bringup-windows'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$report = Join-Path $out 'camera-info.txt'
Start-Transcript -Path $report -Force | Out-Null

Write-Output ("=== camera-info  {0}  PowerShell {1}  Windows {2}" -f (Get-Date -Format s), $PSVersionTable.PSVersion, [Environment]::OSVersion.Version)

Write-Output "`n=== 1. Camera / imaging devices (PnP)"
Get-PnpDevice -Class Camera, Image, Sensor -ErrorAction SilentlyContinue |
    Sort-Object Class, FriendlyName |
    Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 250

Write-Output "`n=== 2. Drivers (AMD ISP / camera / sensor / webcam)"
Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { ($_.DeviceName -match 'ISP|Camera|OV13|OmniVision|webcam|Imaging') -or
                   ($_.InfName -match 'amdcamera|amdisp|sensorov') -or
                   ($_.DeviceClass -match '^(CAMERA|IMAGE|SENSOR)$') } |
    Sort-Object DeviceName |
    Format-Table -AutoSize DeviceName, DeviceClass, DriverVersion, DriverDate, InfName, Manufacturer | Out-String -Width 250

# --- WinRT helpers (Windows PowerShell 5.1) ---
$haveWinRt = $true
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    [void][Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
    [void][Windows.Media.MediaProperties.VideoEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
} catch {
    $haveWinRt = $false
    Write-Output "WinRT is not available in this shell: $($_.Exception.Message)"
}

if ($haveWinRt) {
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await-Op($op, [Type]$resultType) {
        $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
        [void]$task.Wait(-1)
        return $task.Result
    }
    # PowerShell 5.1 cannot pick the AsTask(IAsyncAction) overload by itself, so find it by reflection as above
    $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    function Await-Action($action) {
        $task = $asTaskAction.Invoke($null, @($action))
        [void]$task.Wait(-1)
    }

    Write-Output "`n=== 3. Video-capture devices and their stream formats (WinRT MediaCapture)"
    try {
        $devs = Await-Op ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    } catch {
        $devs = @()
        Write-Output "Enumeration failed: $($_.Exception.Message)"
    }
    foreach ($d in $devs) {
        $panel = try { $d.EnclosureLocation.Panel } catch { 'unknown' }
        Write-Output ("`n--- {0}   panel={1}   id={2}" -f $d.Name, $panel, $d.Id)
        $mc = $null
        try {
            $mc = New-Object Windows.Media.Capture.MediaCapture
            $s = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
            $s.VideoDeviceId = $d.Id
            $s.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
            Await-Action ($mc.InitializeAsync($s))
            foreach ($t in 'VideoPreview', 'VideoRecord', 'Photo') {
                Write-Output ("  [{0}]" -f $t)
                $props = $mc.VideoDeviceController.GetAvailableMediaStreamProperties([Windows.Media.Capture.MediaStreamType]::$t)
                $rows = foreach ($p in $props) {
                    $v = $p -as [Windows.Media.MediaProperties.VideoEncodingProperties]
                    if ($v) {
                        $fps = if ($v.FrameRate.Denominator) { [math]::Round($v.FrameRate.Numerator / $v.FrameRate.Denominator, 2) } else { 0 }
                        '{0,5} x {1,-5}  {2,6} fps  {3}' -f $v.Width, $v.Height, $fps, $v.Subtype
                    }
                }
                $rows | Sort-Object -Unique | ForEach-Object { "    $_" }
            }
        } catch {
            Write-Output "  could not open/enumerate: $($_.Exception.Message)"
        } finally {
            if ($mc) { $mc.Dispose() }
        }
    }
}

Stop-Transcript | Out-Null
Write-Output "`nReport written to $report  -- copy the folder $out back to the Linux side."
