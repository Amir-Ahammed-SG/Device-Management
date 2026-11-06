# Device Management Script

Source and GitHub Actions delivery for the shared SELISE Device Management menu.
All application sources and tests are contained in `DeviceManagement`:

```text
DeviceManagement/
  KioskThoroughCheck.ps1              # Shared engine
  SaaSKioskThoroughCheckScript.ps1    # Compatibility launcher
  SubwayKioskThoroughCheck.ps1        # Compatibility launcher
  Start-DeviceManagement.ps1
  Core/
  Config/                            # Includes KioskClients.psd1
  Checks/
  Deployment/
  Tests/
    Legacy/
```

Run the published entry in 64-bit Windows PowerShell 5.1:

```powershell
irm 'https://cdn-ito.selisesme.com/script/DeviceManagement.ps1' -EA Stop | iex
```

For local file-based execution, run `DeviceManagement/Start-DeviceManagement.ps1`.
Copy the entire `DeviceManagement` folder for local execution; no application source files from the repository root are required.

## Delivery

Pull requests to `main` build and run isolated fixtures. Pushes and merges to
`main` do the same, then publish the tested artifact when deployment is enabled.
Actions also offers **Run workflow** on `main`.

The Windows job uses Windows PowerShell 5.1, checks syntax, creates the existing
in-memory bundle, verifies source and resource hashes, and runs fixture checks.
It never runs a production client check or repair. The Linux job uploads that
same artifact, verifies staging checksums, uses the existing atomic publisher,
and verifies the public HTTPS response. Failed activation or verification attempts
the checksum-guarded rollback and leaves the Actions run failed. A deployment
receipt records the commit, release ID, candidate hash, previous hash and outcome.

See [GitHub deployment setup](DeviceManagement/Deployment/GitHub-Actions.md) and
the [operator guide](<DeviceManagement/Docs/Device Management - Kiosk Thorough Check Guide.md>).

Generated reports, device data, local backups, installers and credentials are
excluded by `.gitignore`. GitHub Actions retains only the verified release and
deployment receipt as artifacts for 30 days.
