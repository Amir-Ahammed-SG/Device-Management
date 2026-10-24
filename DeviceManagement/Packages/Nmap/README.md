# Local Nmap package for Windows 10

Prepare the package on an internet-connected Windows PC:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Save-NmapPackage.ps1
```

The preparation script downloads the official Nmap 7.992 Windows installer and
its published checksum from nmap.org using certificate-validated HTTPS. It
verifies SHA256 and the Insecure.Com LLC Authenticode signature before saving
`nmap-7.992-setup.exe`, its digest, and `NmapPackage.psd1` in this folder. It does
not install software. It preserves a prepared package if a download fails.
An already verified package is reused without downloading again. A different
official version can be prepared with `-Version`.

Keep this layout when copying the scripts to a device:

```text
System Check/
  SaaSKioskThoroughCheckScript.ps1
  SubwayKioskThoroughCheck.ps1
  DeviceManagement/
    Packages/Nmap/
      NmapPackage.psd1
      nmap-7.992-setup.exe
```

On Windows 10, Apply Fix checks the local package checksum, opens the standard
setup wizard, waits for completion, then locates Nmap and runs `nmap --version`.
Complete the wizard, including its bundled dependencies. Cancellation, a failed
installer, a missing executable or failed version readback produces Fail.
Audit never downloads, prepares or installs this package. Existing Nmap
installations are checked and retained in both modes. The Windows 11 installation
path remains winget.

The standard installer requires interaction; `/S` requires
[Nmap OEM](https://nmap.org/oem/). The Windows installer includes Npcap; its
[redistribution terms](https://nmap.org/book/man-legal.html) apply when distributing
the package with software or devices. This folder is not published automatically.

The actual installer is present only after preparation succeeds. A certificate
or download error leaves the folder unprepared; certificate verification is
never disabled. The preparation command can be retried when the official server
is available.
