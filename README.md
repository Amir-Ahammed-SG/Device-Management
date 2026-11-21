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
|-- .github/workflows/          # CI analysis, regression tests, and CDN publication workflow
|-- DeviceManagement/           # Shared application, tests, and maintenance tools
|   |-- Checks/KIOSK/          # Dispatches selected check modes (Audit/Apply) to the engine
|   |-- Config/                # Client configurations, URLs, device rules, and operations
|   |-- Core/                  # Context, menu, validation, and modular kiosk components
|   |   `-- Kiosk/             # Extracted modular libraries (Accounts, Services, Launcher, etc.)
|   |-- Deployment/            # Build scripts, PSScriptAnalyzer policy, release validation
|   |-- Docs/                  # Operator guide, architecture, testing, and maintenance docs
|   |-- Handlers/              # Fallback handlers for unsupported/unavailable operations
|   |-- Installations/KIOSK/   # Unified kiosk setup and Edge browser configuration
|   |-- OtherTools/            # Payment cron job and standalone maintenance tools
|   |-- Packages/Nmap/         # Prepares a verified local Nmap installer
|   |-- Tests/                 # Isolated regression tests, browser suites, and fixture data
|   |-- KioskThoroughCheck.ps1 # Central execution engine (orchestrates checks and reports)
|   |-- Start-DeviceManagement.ps1 # Interactive CLI entry point and navigation menu
|   |-- KNOWN-ISSUES.md        # Documented operational limits and deferred findings
|   `-- README.md              # Detailed application guide and component documentation
|-- Backups/                    # Local CDN recovery and verified archives; ignored by Git
|-- .gitattributes              # Source encoding and line-ending rules
`-- .gitignore                  # Excludes generated/device-specific/private files
```

### Component Overview

| Folder / File | Description & Purpose |
| --- | --- |
| `Start-DeviceManagement.ps1` | Interactive terminal menu to select clients (SaaS/Subway), devices, and operations. |
| `KioskThoroughCheck.ps1` | Central check engine. Loads modular libraries, handles pre-flight checks, and generates reports. |
| `Core/` | Core framework modules (`Context.psm1`, `Menu.psm1`, `Validation.psm1`, `Reporting.psm1`, `KioskClient.psm1`). |
| `Core/Kiosk/` | Shared modular engine functions: `Accounts.ps1`, `Services.ps1`, `Launcher.ps1`, `Reporting.ps1`, `Common.ps1`. |
| `Config/` | Client rules, operation availability, kiosk URLs, and payment package data. |
| `Checks/KIOSK/` | Dispatcher invoking the shared check engine for the selected client and mode. |
| `Installations/KIOSK/` | Shared kiosk installation scripts using Microsoft Edge. |
| `OtherTools/` | Payment cron job and standalone maintenance utilities (`KioskMaintenance.ps1`). |
| `Packages/Nmap/` | Preparation tools for an optional verified local offline Nmap installer. |
| `Tests/` | Automated regression test suites, synthetic data fixtures, and browser-based test runners. |
| `Deployment/` | Release building tools, in-memory bundler, and PSScriptAnalyzer policy. |
| `Docs/` | Operator and developer guides covering architecture, validation, testing, and maintenance. |

> [!NOTE]
> The application is located directly at `DeviceManagement/`. The previous `Scripts/DeviceManagement/` hierarchy has been retired and removed.

- [Application files and usage](DeviceManagement/README.md)
- [Operator guide](<DeviceManagement/Docs/Device Management - Kiosk Thorough Check Guide.md>)
- [Architecture](DeviceManagement/Docs/Architecture.md)
- [Tests and CI](DeviceManagement/Docs/Testing.md)
- [Latest local verification](DeviceManagement/Docs/Validation.md)
- [Local records and recovery](DeviceManagement/Docs/Maintenance.md)
- [Release building and deployment](DeviceManagement/Deployment/README.md)

Releases built from this repository are published via the OrderMonkey Dokploy deployment in the `ordermonkey-issue` repository. Generated `output/` folders are
recreated by builds/tests and are excluded from source control.
