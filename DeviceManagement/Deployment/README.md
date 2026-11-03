# In-memory CDN entry

GitHub `main` deployment is configured by
[GitHub Actions](GitHub-Actions.md). Local commands below remain available.

Run in 64-bit Windows PowerShell 5.1 as Administrator when performing checks:

```powershell
irm 'https://cdn-ito.selisesme.com/script/DeviceManagement.ps1' -EA Stop | iex
```

Publication history is in [GitHub Actions](https://github.com/Amir-Ahammed/Device-Management-Script/actions/workflows/device-management.yml). The entry includes Edge and Chrome browser choices for the [SaaS](../Installations/KIOSK/SaaS/README.md) and [Subway](../Installations/KIOSK/Subway/README.md) KIOSK setups with prompted inputs. Chrome is temporarily unavailable in the browser menu; Edge remains available. Pushes and merges to `main` build, test and deploy through GitHub Actions.

`/script/DeviceManagement.ps1` is the standard CDN entry for the shared device
and tool menu. The previous `/device-management/Start-DeviceManagement.ps1` and
`/kiosk/Start-DeviceManagement.ps1` entries remain at their last published version
for existing commands; new releases use `/script/DeviceManagement.ps1`.

Thorough Check asks mandatory **Agent Name:** before **Branch Name:** in Audit.
The agent appears as **Prepared by:** in the bordered Client Details table and at the bottom right of Audit, Fix and
Final, including Print. Apply Fix reuses those inputs or
validated metadata from the same client/device's saved Audit without prompting
again. Legacy reports without Agent Name remain supported and show **Not provided**
in newly generated views. The earlier Branch input publication is recorded in
[20261023-audit-client-input-02](../Docs/Deployments/20261023-audit-client-input-02/DEPLOYMENT.md).

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
configuration and both client check sources. PowerShell loads these resources
into memory and verifies their embedded checksums before opening the menu.
There is no additional project download, ZIP extraction, cache directory or
project completion file on the device. Exiting returns to the calling shell.

The menu and each client check use separate PowerShell runspaces in the same
process, with the existing console host for Read-Host and confirmation prompts.
This isolates script/global variables, preferences and native exit-code state.
The checks return a completion result containing their actual exit status and
exact report path. A missing, duplicate or invalid result fails verification.
Each client's KIOSK Installation runs its separate embedded handler and setup source,
validates all four inputs before changes, and returns one verified operation
result. Each client handler selects the embedded Edge or Chrome setup from the browser choice. The bundle now contains 20 runtime resources, including the isolated Payment Cron Job tool. Pending operations remain unavailable.

The repository's file-based launcher and client check sources are unchanged.
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
.\Tests\Test-CdnBootstrap.ps1 -ReleaseId 20261023-script-url-01
```

The output is output/releases/<release-id>/Start-DeviceManagement.ps1 plus
release.json. No ZIP is built. Tests/docs/generated output and local deployment
tools are excluded. The entry includes only the runtime sources it needs.
The local build and private staging filename stays Start-DeviceManagement.ps1;
the publisher exposes those exact bytes as DeviceManagement.ps1. The local
file-based launcher and internal resource paths retain their existing names.

Stage both files and Publish-Release.sh in the server's private directory:
/home/ito_kpi_admin/ito-cdn/.deployments/<release-id>

The publish destination is
`/home/ito_kpi_admin/ito-cdn/files/script/DeviceManagement.ps1`.
Its parent directory must exist as a real directory before activation. The initial
URL migration and endpoint-specific rollback are recorded under
`Docs/Deployments/20261023-script-url-01`. Older deployment records are
historical and retain their original URLs.

Activate using the current entry hash and the new entry hash:

```bash
sudo -n bash /home/ito_kpi_admin/ito-cdn/.deployments/<release-id>/Publish-Release.sh activate <release-id> <previous-sha256> <new-sha256>
```

Use absent instead of a previous hash only for a new endpoint. Activation checks
the current contents, saves an existing entry privately and atomically replaces
it while preserving ownership/mode. Verify the public SHA256 and run an Exit-only
menu smoke test. The same arguments with rollback restore the prior entry only
if the endpoint still matches the new hash. Older deployments keep their own
publisher scripts and rollback arguments. No container restart is required.

Reports write to `C:\Thorough Check\` when requested; restore points use its
`Restore Points` subfolder. Other Tools > Payment Cron Job runs from an isolated
embedded script, reports in the terminal, and asks Y/N before enabling only SIX.
It creates no backup, temporary file or HTML report. Explicit Apply
operations may download/install their actual software and create installation
logs as before; this change removes project-package storage, not those actions.
The Windows 10 local Nmap installer is not included in memory delivery; it is
still unprepared and requires manual installation. Existing Nmap detection and
the Windows 11 winget path are unchanged.
