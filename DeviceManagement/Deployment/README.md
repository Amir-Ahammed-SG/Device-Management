# In-memory bundle and deployment

This directory contains the release build tools that package the application into a
single in-memory executable script for web distribution.

The active deployment is served by **Dokploy** via the Nginx static file container
maintained in `OrdermonkeyDeploy/All-In-One/`. The previous SSH/CDN publisher and
legacy server scripts have been retired.

Run in 64-bit Windows PowerShell 5.1 as Administrator when performing checks:

```powershell
irm 'https://<your-domain>/DeviceManagement.ps1' -EA Stop | iex
```

Releases are built locally or in CI from the maintained source and published via the
OrderMonkey Dokploy deployment.

`/script/DeviceManagement.ps1` is the standard CDN entry for the shared device
and tool menu. The previous `/device-management/Start-DeviceManagement.ps1` and
`/kiosk/Start-DeviceManagement.ps1` entries remain at their last published version
for existing commands; new releases use `/script/DeviceManagement.ps1`.

Thorough Check asks mandatory **Agent Name:** before **Branch Name:** in Audit.
The agent appears as **Prepared by:** in the bordered Client Details table of Audit, Fix and
Final, including Print. Apply Fix reuses those inputs or
validated metadata from the same client/device's saved Audit without prompting
again. Legacy reports without Agent Name remain supported and show **Not provided**
in newly generated views. The earlier Branch input publication is recorded in
the local recovery archive; see [records and recovery](../Docs/Maintenance.md).

The Thorough Check terminal menu offers Audit Report and Apply Fix. Audit saves
Audit-derived Fix and Final views immediately; Apply replaces them with its
actual readback. Final remains a printable HTML tab. Original report files do
not show the sample preview's Client selector.

Fix lists unresolved/manual checks and repairs recorded during Apply, omitting
healthy unchanged components and empty sections. A clean observed state shows
No fixes required. Audit and Final retain all components.

Fix uses Component, Shortcut / Command, Setting, Findings and Applied. Applied
contains recorded post-fix property values; pending/read-only values are Not applied
and unavailable readback is Not verified. Final uses Component, Setting and Status,
where Status is the latest recorded property value. Both retain the approved column
colors, thin borders, record grouping and component hover. Repair rules are unchanged.

The CDN serves one self-contained script containing the current project modules,
configuration and the shared kiosk check source. PowerShell loads these resources
into memory and verifies their embedded checksums before opening the menu.
There is no additional project download, ZIP extraction, cache directory or
project completion file on the device. Exiting returns to the calling shell.

The menu and each client check use separate PowerShell runspaces in the same
process, with the existing console host for Read-Host and confirmation prompts.
This isolates script/global variables, preferences and native exit-code state.
The checks return a completion result containing their actual exit status and
exact report path. A missing, duplicate or invalid result fails verification.
KIOSK Installation runs the shared embedded handler and Edge
setup with explicit client settings, validates all four inputs before changes,
and returns one verified operation result. The bundle contains 23 runtime
resources, including `KioskClients.psd1`, its loader, and the isolated Payment
Cron Job tool. Only shared runtime entry points are provided. Pending operations
remain unavailable.

Local file execution uses the same shared check and installation sources.
Build-Release.ps1 adapts only these delivery boundaries in the emitted script:

- Load modules and configuration from embedded memory resources.
- Dispatch the selected client/mode in an isolated runspace.
- Return from the menu instead of closing the caller's shell.
- Replace the check's final exit with a completion result. No completion-file
  path is supplied, so its existing file signal is never written.

The builder validates the expected syntax boundaries and fails if they change.
Original and emitted resource hashes are recorded in release.json. Device
checks, account/service repairs and report rendering are retained from source.

Build and validate a version:

```powershell
.\Deployment\Build-Release.ps1 -ReleaseId 20261023-script-url-01
.\Tests\Test-MemoryDelivery.ps1 -ReleaseId 20261023-script-url-01
```

The output is output/releases/<release-id>/Start-DeviceManagement.ps1 plus
release.json. No ZIP is built. Tests/docs/generated output and local deployment
tools are excluded. The entry includes only the runtime sources it needs.
The local build and private staging filename stays Start-DeviceManagement.ps1;
the publisher exposes those exact bytes as DeviceManagement.ps1. The local
file-based launcher and internal resource paths retain their existing names.

To deploy the built release to the OrderMonkey Dokploy server:

1. Copy the generated `Start-DeviceManagement.ps1` to `All-In-One/public/DeviceManagement.ps1` in the `OrdermonkeyDeploy` checkout.
2. Copy `release.json` to `All-In-One/release.json`.
3. Verify that the copied script SHA256 matches `BootstrapSHA256` in `release.json`.
4. Commit and push `All-In-One/` in the `ordermonkey-issue` repository. Dokploy automatically builds and deploys the Nginx container serving the updated bundle.

Reports write to `C:\Thorough Check\` when requested; restore points use its
`Restore Points` subfolder. Other Tools > Payment Cron Job runs from an isolated
embedded script, reports in the terminal, and asks Y/N before enabling only SIX.
It creates no configuration backup, temporary configuration copy or HTML report.
The tool also offers a separate Y/N restart of only the selected service, with
new-process/state readback and fresh process-owned SIX registration log checks.
Unavailable evidence stays unverified; no test payment/balance is requested.
Explicit Apply operations may download/install their actual software and create installation
logs as before; this change removes project-package storage, not those actions.
The Windows 10 local Nmap installer is not included in memory delivery; it is
still unprepared and requires manual installation. Existing Nmap detection and
the Windows 11 winget path are unchanged.
