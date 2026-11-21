# Device Management application

SaaS and Subway share one check engine and one kiosk installation. Client URLs
and payment discovery preferences are data in `Config/KioskClients.psd1`.
Microsoft Edge is the default kiosk browser; there is no browser selection screen.

## Start

Run from this folder in 64-bit Windows PowerShell 5.1:

```powershell
.\Start-DeviceManagement.ps1
```

Standalone checks select the client explicitly:

```powershell
.\KioskThoroughCheck.ps1 -ClientType SaaS -AuditOnly
.\KioskThoroughCheck.ps1 -ClientType Subway -Apply
```

Audit reads current configuration and offers optional HTML output. Apply verifies
repairs and saves a report. Reports use `C:\Thorough Check`. Copy this whole
application folder for local delivery, including `Core/Kiosk` and `Config`.
The CDN bundle embeds these dependencies in memory.

## Folder structure

| Folder / file | Purpose |
| --- | --- |
| `Start-DeviceManagement.ps1` | Client/device/operation menu and navigation. |
| `KioskThoroughCheck.ps1` | Loads shared functions, controls mode gates, runs checks and finalizes reports. |
| `Config/` | Client/device rules, operation availability, kiosk URLs and payment catalog. The empty payment catalog is still required. |
| `Core/` | Context, menu, configuration validation, dispatch and standard result modules. |
| `Core/Kiosk/Accounts.ps1` | Account discovery, password-policy checks, profiles and auto-login inspection. |
| `Core/Kiosk/Services.ps1` | Services, recovery settings, payment discovery/tasks, Zabbix, firewall and Nmap helpers. |
| `Core/Kiosk/Launcher.ps1` | Launcher parsing, safe text changes, hostname/URL repair, launch tasks and Edge policies. |
| `Core/Kiosk/Reporting.ps1` | Report snapshots, tables, grouping, comparisons and combined report storage. |
| `Core/Kiosk/Common.ps1` | Console progress, apply confirmation, result objects and shared utilities. |
| `Checks/KIOSK/` | Executes the shared engine for the selected client and mode. |
| `Installations/KIOSK/` | Shared installation handler, Edge setup and [setup instructions](Installations/KIOSK/README.md). |
| `OtherTools/` | Payment Cron Job, kiosk launch-task maintenance, Zabbix and Nmap installation. |
| `Packages/Nmap/` | Instructions and preparation script for an optional verified local installer. Installer binaries are ignored by Git. |
| `Handlers/` | Returns Unavailable for operations that are not implemented. |
| `Tests/` | Current isolated regression scripts, shared helpers and historical renderer fixtures. |
| `Deployment/` | Release building, analysis, in-memory execution and controlled CDN publication. |
| `Deployment/ScriptAnalysis/` | Pinned analyzer version, rules and source coverage policy. |
| `Docs/` | Operator and developer guides. |
| `output/` | Disposable builds, reports and fixture files; generated and ignored by Git. |
| `KNOWN-ISSUES.md` | Remaining operational limitations and deferred findings. |

Client-specific runtime launchers are removed. Client names in tests describe
configuration scenarios; they do not supply separate implementations.

## Guides

- [Operator guide](<Docs/Device Management - Kiosk Thorough Check Guide.md>)
- [Shared architecture and module loading](Docs/Architecture.md)
- [Tests and CI](Docs/Testing.md)
- [Local records, archives and recovery](Docs/Maintenance.md)
- [Deployment](Deployment/README.md)

POS/KDS checks, payment-package operations and other unsupported client/device
selections remain unavailable. An unavailable selection performs no device changes.
