# Shared architecture

## Runtime flow

The menu validates the selected client, device, operation and mode against Config.
Core/Context creates an operation context. Core/PackageLoader dispatches to the
configured handler. Checks/KIOSK/ThoroughCheck starts the shared engine in a child
PowerShell process and verifies its completion signal, exit status and report.
The menu then presents result navigation.

KioskThoroughCheck loads five function libraries from Core/Kiosk: Common,
Reporting, Launcher, Accounts and Services. These `.ps1` libraries contain
function definitions and are dot-sourced into the existing engine scope. This
preserves script variables, mock boundaries and the Audit/Apply gates; importing
an isolated PowerShell module would change that state contract. Function bodies
were extracted without changing the check ordering in the engine.

The engine retains comments naming the original function boundaries. Tests use
KioskTestSupport to reconstruct a source view for AST inspection of individual
check blocks without running the engine. Production execution loads the actual
libraries. Shared-module loading is separately tested in local and embedded
runspaces, including missing dependencies and client isolation.

## Local and in-memory delivery

Local execution resolves libraries relative to the engine, so copy the whole
application folder. Deployment/Build-Release embeds the entry, five kiosk
libraries, shared modules, settings, dispatcher and installation/tools. The
manifest lists 23 resources with source/runtime hashes. Embedded execution loads
libraries from the verified resource map and writes no extracted project files.
Missing or malformed local libraries and missing embedded resources fail before a device check runs. Standalone maintenance tools read the same libraries and select named definitions without executing engine orchestration.

## Behavior boundaries

- SaaS/Subway differences are configuration values, never duplicated engines.
- Audit is read-only. Declining optional HTML output creates no report directory.
- Apply preflights, preserves recovery state, changes only selected managed
  settings and verifies readback before reporting success.
- Disabled accounts remain read-only; no account or group membership is created.
- The launcher hostname may use confirmed operator input. Zabbix has a separate
  monitoring-hostname prompt during installation or missing-hostname repair in
  Apply/Tools; Windows DNS is only the suggested default. Existing explicit names
  are preserved. Neither operation renames Windows.
- KIOSK installation uses the shared Edge setup with four direct input prompts.
- Result Back returns to the operation menu after installation.
- Report snapshots retain their own observations. Regenerating a view never
  implies that a check, repair or installation executed.

The [operator guide](<Device Management - Kiosk Thorough Check Guide.md>) describes
current device-facing behavior. Historical source/validation records in local
archives are evidence, not active requirements.
