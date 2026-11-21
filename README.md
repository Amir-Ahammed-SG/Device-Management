# SELISE Device Management

Shared Windows PowerShell 5.1 tools for SaaS and Subway kiosks. Select the client
in the menu; checks and installation use the same implementation. KIOSK
Installation uses Microsoft Edge directly.

## Run

From a local checkout, run in 64-bit Windows PowerShell:

```powershell
.\DeviceManagement\Start-DeviceManagement.ps1
```

For an installed device, the published menu is:

```powershell
irm 'https://cdn-ito.selisesme.com/script/DeviceManagement.ps1' -EA Stop | iex
```

Use an Administrator terminal for device checks and installation. Audit reads
configuration; Apply repairs selected settings and verifies the result.

## Folder structure

```text
System Check/
|-- .github/workflows/           # CI analysis, regression and optional CDN publication
|-- DeviceManagement/            # Shared application, tests and development tools
|   |-- Config/                 # Client URLs, device rules and available operations
|   |-- Core/                   # Menu, validation, dispatch and shared kiosk functions
|   |   `-- Kiosk/              # Accounts, Services, Launcher, Reporting and Common
|   |-- Checks/KIOSK/           # Dispatches selected check modes to the shared engine
|   |-- Installations/KIOSK/    # Shared kiosk installation and default Edge setup
|   |-- OtherTools/             # Payment cron and standalone maintenance tools
|   |-- Packages/Nmap/          # Prepares a verified local Nmap installer
|   |-- Handlers/               # Reports operations that are not implemented
|   |-- Tests/                  # Isolated regression tests and fixture data
|   |-- Deployment/             # Build, analysis, release validation and CDN scripts
|   `-- Docs/                   # Operator, architecture, testing and maintenance guides
|-- Backups/                     # Local CDN recovery and verified archives; ignored by Git
|-- .gitattributes               # Source encoding and line-ending rules
`-- .gitignore                   # Excludes generated/device-specific/private files
```

- [Application files and usage](DeviceManagement/README.md)
- [Operator guide](<DeviceManagement/Docs/Device Management - Kiosk Thorough Check Guide.md>)
- [Architecture](DeviceManagement/Docs/Architecture.md)
- [Tests and CI](DeviceManagement/Docs/Testing.md)
- [Latest local verification](DeviceManagement/Docs/Validation.md)
- [Local records and recovery](DeviceManagement/Docs/Maintenance.md)
- [CDN deployment configuration](DeviceManagement/Deployment/GitHub-Actions.md)

Changes here do not publish themselves. CI publishes only when the existing
repository deployment settings permit it. Generated `output/` folders are
recreated by builds/tests and are excluded from source control.
