# Device Management Script

Source and GitHub Actions delivery for the shared SELISE Device Management menu.
All application sources and tests are contained in `DeviceManagement`:

```text
Device-Management/
|-- .github/
|   `-- workflows/
|       `-- device-management.yml        # Analysis, release tests and optional CDN deployment
|-- DeviceManagement/                   # Self-contained application and development files
|   |-- Start-DeviceManagement.ps1       # Main menu
|   |-- KioskThoroughCheck.ps1           # Shared SaaS/Subway check engine
|   |-- SaaSKioskThoroughCheckScript.ps1 # Compatibility launcher
|   |-- SubwayKioskThoroughCheck.ps1     # Compatibility launcher
|   |-- Config/                         # Client, operation and package settings
|   |-- Core/                           # Shared modules
|   |-- Checks/KIOSK/                   # Thorough Check dispatcher
|   |-- Installations/KIOSK/            # Shared Edge setup and compatibility wrappers
|   |-- OtherTools/                     # Payment Cron Job tool
|   |-- Handlers/                       # Pending-operation handler
|   |-- Packages/Nmap/                  # Local Nmap package preparation
|   |-- Deployment/
|   |   `-- ScriptAnalysis/             # PSScriptAnalyzer policy and settings
|   |-- Tests/
|   |   |-- Fixtures/                   # Historical renderer reference data
|   |   `-- Legacy/                     # Legacy Pester tests
|   |-- Tools/                          # Report-layout recovery tool
|   |-- Docs/                           # Kiosk operator guide
|   |-- KNOWN-ISSUES.md
|   `-- README.md                       # Detailed architecture and folder structure
|-- .gitattributes
|-- .gitignore
`-- README.md
```

See the [full application folder structure](DeviceManagement/README.md#folder-structure)
for individual scripts and modules. Generated `output`, local `Backups` and local
reference records are excluded from Git. Empty local `Payments` placeholders are
not tracked or implemented payment handlers.

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
