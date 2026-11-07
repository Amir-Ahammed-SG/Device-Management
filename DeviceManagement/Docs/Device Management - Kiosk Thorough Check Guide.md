# Device Management — Kiosk Thorough Check Guide

An operator guide for **Subway** and **SaaS** KIOSK Thorough Check.

The 24 Oct 2026 hostname, account and report updates are published on the CDN. The [verified GitHub Actions deployment](https://github.com/Amir-Ahammed/Device-Management-Script/actions/runs/40073441632) records the build and publication results.

## 1. Prepare the device

- Use the existing kiosk account, normally `SELISE` or `SELISE-KIOSK`. If its Windows profile has never been initialized, sign in once using its current password, wait for the desktop to load, then sign out. Leave the password blank only if no password is set. Then sign in to the Windows account you will use to run Device Management.
- Have administrator credentials and an internet connection available.
- Run **Apply Fix** during a maintenance window: it can start, stop or restart services and change device settings.

Thorough Check checks an existing kiosk installation and repairs supported settings. Missing accounts and profiles require manual setup. For launcher/Startup setup, use the client-specific [SaaS](../Installations/KIOSK/SaaS/README.md) or [Subway](../Installations/KIOSK/Subway/README.md) KIOSK Installation. Both clients support **KIOSK → Thorough Check** and **KIOSK → KIOSK Installation**; other operations marked **Not available** cannot be run.

## 2. Open Device Management

Open **64-bit Windows PowerShell 5.1 → Run as administrator**, then paste:

```powershell
irm 'https://cdn-ito.selisesme.com/script/DeviceManagement.ps1' -EA Stop | iex
```

Select the options by their displayed names:

**Client: Subway or SaaS → Device: KIOSK → Operation: Thorough Check**

The mode menu contains:

| Option | Purpose |
| --- | --- |
| **[1] Audit Report** | Check the current configuration without changing device settings. Saving the HTML report is optional. |
| **[2] Apply Fix** | Apply supported repairs, verify the resulting configuration and save the report automatically. |

Use **[8] Back** to return to the previous screen and **[0] Exit** to leave. The completion screen also offers **[3] Main Menu**. After a completed Thorough Check Audit, **[2] Apply Fix** is available directly in this footer.

## 3. Run Audit first

1. Select **[1] Audit Report**.
2. At **Agent Name:**, enter the name of the person preparing the report. A blank name is not accepted.
3. At **Branch Name:**, enter the branch label to display in the report, for example `Glatt` or `Redo - FRANK`.
4. Wait for the checks to finish and review the terminal findings.
5. At **Generate HTML report? [Y/N]**, enter **Y** to save the report. **N** leaves any existing report unchanged and creates no new report.
6. Open the saved HTML file and review its **Audit** and **Fix** tabs. Each report view keeps **Prepared by** in the Client Details header. The bottom-right footer shows **Generated Time** only, including when printing Final.

Before Apply Fix has been run, the **Fix** and **Final** tabs are generated from the Audit observations and labelled **Based on Audit**. This does not mean a repair has been performed.

If the Fix tab says **No fixes required**, you can use the Final tab and print it without running Apply Fix.

The Final tab's **KIOSK Account** section shows only the confirmed kiosk account
selected by the existing user-selection logic for the launcher, Startup folder
and launch task. Other detected kiosk accounts remain in Audit and relevant Fix
findings. Administrative accounts retain their separate reporting. If selection
is unverified, missing or ambiguous, Final shows **Kiosk user not verified** and
does not guess the default `SELISE-KIOSK` user. Failed/unavailable account readback
remains **Not verified**. This is a report projection only: Windows accounts,
selection rules and saved Audit records are not changed. Generate a new report
with the updated script to see this layout.

## 4. Apply fixes when needed

1. From the completed Audit screen, select **[2] Apply Fix**. You can also select **[8] Back**, then **[2] Apply Fix**.
2. Review **URL Origin**, then verify **Restaurant ID**, **Kiosk ID** and **Hostname**, in that order. Missing IDs require input. Press Enter to keep a suggested value, or enter a replacement. The hostname suggestion is the active Windows DNS hostname. These prompts appear only in Apply Fix.
3. Wait for the initial read-only inspection, supported repairs and verification to finish.
4. Read the saved report path in the terminal, then reopen or refresh that HTML file.
5. Review **Fix → Findings** and **Applied**, then check **Final → Status**.

Apply Fix reuses the Branch Name from the same client selection and does not ask again. This also works in the same session if you declined to save the Audit report. In a new session, it can reuse a validated saved Audit for the same client and device. If the information is missing or conflicting, Branch is shown as **Not provided**; run Audit to enter the correct branch.

Agent Name is reused in the same session or read from the uniquely identified saved Audit in a new session. Apply Fix does not ask for Agent Name. For older reports that have no agent information, newly generated views show **Prepared by: Not provided** in the header; run Audit to enter a name. Existing saved Audit content is preserved when applying fixes.

Apply prompts:

| Prompt | What to enter |
| --- | --- |
| **Restaurant ID [existing value]** | Verify the branch-specific ID for the selected client, or enter its replacement. Missing IDs are required. When the URL changes between SaaS and Subway, check this ID carefully: the two clients can use different restaurant IDs. |
| **Kiosk ID [existing value]** | Verify the kiosk ID, or enter its replacement. Missing IDs are required. |
| **EXACT Service Name for Payment Middleware** | The Windows service's **Service name**, available in `services.msc`. Enter `skip` if you cannot identify it; do not guess. |
| **Hostname [current Windows DNS name]** | Confirm the suggestion or enter the approved launcher hostname. Existing `host=` is replaced with the confirmed value, or added when missing. This does not rename Windows. |

Apply validates all confirmed launcher inputs before starting component repairs. A known SaaS/Subway URL origin is corrected for the selected client; the onboarding route must already be valid. Restaurant ID, Kiosk ID and host are then updated together, with URI encoding, an exact original-file backup, readback and rollback on failure. Unrelated query parameters, command arguments and file encoding are preserved. Unknown sites, signed/dynamic/ambiguous launchers, duplicate recognized parameters and concurrent edits require manual review. Audit never asks for these Apply-only values or changes the launcher/computer name.

Hostname confirmation updates only the launcher URL. Windows keeps its computer name, and the auto-login domain is preserved. No domain credentials, Windows rename, pending-name checks, computer restart prompt or Windows Computer Name report check are part of this flow. Restart Edge to load launcher changes. Audit continues to compare the launcher hostname with the current Windows DNS hostname; a deliberately different custom launcher hostname will therefore remain a hostname mismatch in a subsequent Audit. Zabbix continues to use the actual Windows computer name.

An existing Zabbix Agent's single explicit `Hostname` setting can be updated to the Windows computer name, followed by an agent restart and readback. Dynamic, duplicate or multi-host configurations require manual review. Only the hostname setting is changed; monitoring server addresses are preserved. Original launcher/configuration files are backed up under **C:\Thorough Check\Restore Points** before edits. A failed Zabbix activation attempts to restore the original configuration.

## Standalone maintenance tools

From the main menu, choose **Other Tools**, then **Kiosk Launcher Task Scheduler**,
**Zabbix Installer** or **Nmap Installer**. These tools run in elevated 64-bit
Windows PowerShell and do not run a full Audit/Apply. Results appear in the
terminal. Declining the Y/N prompt returns to Other Tools without changes;
completed/failed results remain visible until you press Enter.

| Tool | Behavior |
| --- | --- |
| Kiosk Launcher Task Scheduler | Selects an enabled existing local user with `Scripts\LaunchKiosk.ps1`; asks you to choose if multiple profiles match. Verifies the profile, launcher syntax and task. With confirmation, creates or repairs only the root `\Launch Kiosk` task for that user: interactive sign-in, Limited privileges, 5-second logon delay. Existing valid tasks are kept. Multiple/non-root tasks and tasks belonging to another account require manual review. |
| Zabbix Installer | Uses the current Windows DNS hostname and the existing Zabbix installation package. Installs only when the agent service is missing, then verifies Running / Automatic and the configured hostname. Existing unhealthy installations are preserved and referred to Thorough Check for repair. |
| Nmap Installer | Keeps an existing installation and verifies `nmap --version`; it does not run network scans. On Windows 11, uses the existing `Insecure.Nmap` winget route without upgrading an existing installation. Windows 10 uses a checksum-verified local setup wizard. |

Before repairing an existing owned kiosk task, the tool saves its original XML
under `C:\Thorough Check\Restore Points` and verifies the backup. Task changes
detected during confirmation or immediately before registration stop the repair.
The tool never starts the task or changes the launcher, Startup BAT, accounts or
Windows computer name. If task readback fails, the result remains failed and
identifies the backup for manual recovery; an unknown task state is preserved.

For Windows 10 Nmap installation, prepare `Packages\Nmap` with
`Save-NmapPackage.ps1`, then run the local project copy. The CDN bundle does not
contain the installer. The public setup wizard requires interaction; silent
`/S` belongs to the OEM installer. See [Nmap's Windows installation guide](https://nmap.org/book/inst-windows.html).
The winget path retains the project's existing flags; see [Microsoft's install command reference](https://learn.microsoft.com/windows/package-manager/winget/install).

For local standalone use:

```powershell
.\OtherTools\KioskMaintenance.ps1 -ToolId KioskLauncherTask
.\OtherTools\KioskMaintenance.ps1 -ToolId ZabbixInstaller
.\OtherTools\KioskMaintenance.ps1 -ToolId NmapInstaller
```

The tool loads an explicit allowlist of function definitions from the shared
engine, locally or from the verified memory bundle. It does not execute the
engine's top-level checks. Zabbix package trust limitations remain documented in
`KNOWN-ISSUES.md`; automated fixtures do not replace test-kiosk installation.

## 5. Find and use the report

Reports are saved in **C:\Thorough Check**. The exact report path is printed in the terminal.

The usual filename is:

```text
Thorough Check Reports - <Client> - <Hostname>.html
```

New filenames and report identity use the actual Windows computer name. An older launcher-named report is reused when its saved client and Windows computer identity match uniquely. Follow the printed path. Reports do not open automatically.

One HTML file contains all three views:

| Tab | What it shows |
| --- | --- |
| **Audit** | Component, Shortcut / Command, Setting, Required and Findings. |
| **Fix** | Component, Shortcut / Command, Setting, Findings and Applied. Findings preserves pre-fix values; Applied shows recorded post-fix values. Healthy, unchanged components are omitted. |
| **Final** | Component, Setting and Status. Status is each setting's latest recorded value, using Audit observations initially and verified readback after Apply; it is not a component Pass/Fail badge. |

Within an account component, Fix shows only accounts requiring attention or changed during that Apply run, with their corresponding commands. Healthy unchanged accounts are omitted; Audit and Final retain all accounts. Original account numbers are preserved, so a filtered Fix view may show Account 02 without Account 01.

Apply updates **Fix** and **Final** and preserves the saved Audit. There is no separate Final mode to run. If Apply is run before any Audit, the Audit tab remains **Not run**.

Fix Findings retain the saved Audit observations. When no Audit exists, Apply captures the current configuration read-only before repairs. Successful repairs and failed readbacks update Applied and Final; they do not replace the original problem in Findings.

Standard kiosk account repairs update **Password Never Expires** and **User Cannot Change Password** when needed, followed by readback. Administrative accounts keep non-expiring passwords and allow password changes under the existing policy. Existing account names, passwords, privilege and active/disabled status are preserved. Disabled accounts retain the existing manual-review behavior.

AppSettings is a read-only collection of values. Present values, including `False` and `0`, remain visible without green fill; unavailable values remain explicit. Fix shows **Not applied** in Applied, with the original manual-review details in the tooltip. Final Status contains the recorded property values. The JSON files are not edited.

Check each tab's **Generated Time** and source note. If a file already contains actual Fix/Final results, a later Audit preserves those earlier results while updating Audit. Do not assume every tab was generated together. The report file is updated across runs; copy it before another run if you need a historical record.

**Generated Time** uses **Bangladesh Standard Time (BST, UTC+06:00)**. Task **Trigger Time**, **Last Run** and **Next Run** use the device's local time zone.

### Reading colors and action notes

All tabs use the same thin borders, record bands and component hover highlight.
Setting has a light gray background; Required (Audit) or Findings (Fix) is light
blue; Findings (Audit), Applied (Fix) and Status (Final) are light cream.

| Value appearance | Meaning |
| --- | --- |
| Plain | A matched requirement, collected information or context. |
| Light red | A mismatch or missing information. |
| Amber (`#FFE3A0`) | Not verified; the actual warning text remains visible. |

**Applied** shows the recorded post-fix value of each setting. An unrun fix or
read-only field shows **Not applied**; missing, failed or ambiguous readback
shows **Not verified**. Original action details are available by hovering the
Applied value. If an older/partial run has no pre-fix baseline, Findings shows
**Not recorded** instead of guessing the old value.

**Final Status** shows values such as **Idle**, **Enabled**, paths, `False` or `0`.
A failed readback stays **Not verified**. These views do not rerun checks or
change repair rules. Collected AppSettings values do not certify that the
business configuration is correct.

## 6. Print the Final report

1. Open the HTML report and select **Final**.
2. Select **Print**.
3. Choose a printer, or choose your browser's PDF destination to save a PDF.

Printing includes the Final report only. Audit, Fix and the tab controls are excluded. You can also share the self-contained HTML file; no companion files are required.

## 7. Complete manual checks

Review all remaining failed, unverified or manually actionable findings. Relevant limits include:

- **Automatic sign-in:** Existing settings are inspected. Sign-in credentials are not configured, and existing passwords are not reset.
- **Launcher and Startup:** Missing or invalid launcher/Startup files and identifiers need manual setup. Apply may create a missing desktop shortcut when its existing targets can be verified. Existing browser-policy conflicts require manual review.
- **Touchscreen zoom:** Apply can add `--disable-pinch` to a supported existing Edge launcher. Restart Edge to load it, then test touchscreen pinch in and out. Keyboard, Ctrl + mouse wheel and other zoom controls are outside this change.
- **Payment Service restart task:** Reported only for **NETS/NEXIDE**. The script checks the existing task and schedule; it does not create, enable, edit or run the task. A configuration Pass does not prove the scheduled restart actually succeeded.
- **AppSettings:** Payment terminals, WebApp Printer (including BranchUUID from the KitchenTicketPrint schedule), matching Cron Job entries and service URLs are collected for review. JSON configuration is not changed. Provider-specific fields depend on the discovered Payment Service provider.
- **Nmap on Windows 10:** The current CDN release does not include the local installer. If Nmap is missing, arrange manual installation and verify it afterward.
- **Service checks:** A service Pass does not prove payment connectivity or complete monitoring connectivity. Zabbix Server/ServerActive settings and end-to-end monitoring require separate verification.

Apply can also change printer document retention, event logging, required account password properties, service startup/recovery, inbound firewall rules and performance counters. Its Windows Update requirement is **Stopped / Disabled** with recovery actions set to **Take No Action**. Review the Applied notes for the actual changes made.

After maintenance, restart the kiosk when appropriate and verify:

1. Automatic sign-in reaches the intended kiosk account.
2. The correct application opens full-screen for the intended branch and kiosk.
3. Touchscreen pinch cannot zoom in or out after Edge restarts.
4. Receipt printing works on the intended printer.
5. A payment test succeeds through the approved test procedure.
6. Monitoring and, where applicable, the scheduled Payment Service restart work as intended.

Run Audit again to check the current configuration after manual changes. Compare tab timestamps when reviewing an existing combined report.
