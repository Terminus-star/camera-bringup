# Windows-side captures (read-only / logging only)

Written on Linux and **UNTESTED**: read each script before running it.  None of them changes a setting, writes a
register or installs anything.  They run in Windows PowerShell (`powershell.exe`), not PowerShell 7.  Copy them to
Windows yourself (the Linux side never writes to the Windows partition).

| step | script | needs | what it gives |
|---|---|---|---|
| 1 | `01-camera-info.ps1` | normal user | camera devices, driver versions, and the stream formats (resolution, fps, pixel format) Windows exposes for the rear camera |
| 2a | `02-trace-start.ps1` | Administrator | starts an ETW trace of the AMD camera driver (WPP control GUID `{0FBF5BB9-E551-475A-A9C0-B98F2EA1A4AD}`) |
| (use the rear camera in the Camera app: preview ~10 s, one photo, ~5 s of video) | | | |
| 2b | `02-trace-stop.ps1` | Administrator | stops the trace and writes `amdcam.etl/.csv/.xml`, a summary and the driver's hash |

Everything is written to `%USERPROFILE%\Documents\camera-bringup-windows\`.  Bring that folder back to Linux
(for example on a USB stick or by copying it into the project), and tell Claude where it is.

Fallback for step 1 without PowerShell: Camera app -> Settings -> Video quality / Photo quality lists the resolutions.

Not covered (higher risk, needs a third-party MMIO tool): a dump of the ISP registers while streaming
(ISP offsets 0x0-0x629a4 and 0x66000-0x67fff, physical base 0xa0300000 as seen from Linux).  Only if wanted.
