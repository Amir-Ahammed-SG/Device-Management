# SELISE Device Management architecture

This folder contains the client, device, operation, package-version and mode
navigation with validated operation routing.

Deferred production findings are tracked in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

Runtime code is in `Start-DeviceManagement.ps1`, `Core`, `Config`, `Checks`, `Installations` and `OtherTools`.
Development tests are grouped under `Tests`; reference documents, validation
evidence and deployment records are under [Docs](Docs/README.md). Generated
`output` files are disposable test artifacts and are excluded from deployment.
The two client-specific Thorough Check sources currently live in the parent
`System Check` folder and must accompany any deployment of this launcher.

Run the project from the CDN with:

```powershell
irm 'https://cdn-ito.selisesme.com/script/DeviceManagement.ps1' -EA Stop | iex
```

This opens the full Device Management menu directly in memory, without saving or extracting a project ZIP. See [deployment instructions](Deployment/README.md) for building and
publishing a new version. It does not enable operations marked Pending.

## Selection hierarchy

1. Client: Subway, SaaS, or ViCafe.
2. Device: Subway/SaaS allow KIOSK, POS, and KDS; ViCafe allows POS only.
3. Operation: Thorough Check, Payment Service, or the installation matching the
   selected device.
4. Mode: Thorough Check displays Audit Report and Apply Fix. Payment Service
   displays each available version followed by Audit Report and Remove Payment Service;
   selecting a version starts its installation directly. Installation operations
   first ask for Microsoft Edge or Google Chrome for KIOSK, then run the selected setup.

Client/device compatibility and operation visibility come from the data files in
`Config`. They are validated again before dispatch, so a hidden or manually
constructed invalid selection cannot reach a handler.

Menus use a consistent header, breadcrumb, compact option list and navigation
footer. All menu input uses Select option. Audit Report and Apply Fix have no
description lines. Unimplemented options remain visible as Not available;
selecting one displays a notice and stays on the same menu. Back and Exit use
8 and 0, with 3 for Main Menu on completion screens. Completed check output is
preserved above the navigation footer.

## Current implementation

The main menu also offers **Other Tools > Payment Cron Job**. Selecting it
automatically reads the running Payment Service's `appsettings.json` and prints
Provider, Name, UID, CronExpression and IsEnabled for SIX, NETS and NEXIDE
schedules. Multiple running candidates require explicit selection. The configured
executable must match the actual running process, and hosted executables,
command-line configuration overrides and linked paths require manual review.

When exactly one SIX schedule has Boolean `IsEnabled: false`, the tool asks
**Enable SIX Cron? [Y/N]**. N returns directly to Other Tools. Y requires an
administrator, changes only that SIX Boolean to true, verifies the file and
keeps the result visible until Enter. Already enabled schedules need no configuration
fix prompt or write. SIX Name, UID and CronExpression must be readable. Another
enabled or unverified schedule with the same UID blocks Apply/restart, including
providers outside the displayed payment list: Hangfire uses UID as the recurring
job identifier, so a later enabled record can overwrite an earlier one.
Invalid JSON, duplicate properties, missing/ambiguous SIX schedules,
changed service identity, changed file content or an unavailable exclusive file
lock prevent writing. NETS, NEXIDE and every other setting remain unchanged.

The standalone script is `OtherTools/PaymentCronJob.ps1`. It preserves the
original file's bytes outside the Boolean token, including comments, spacing,
line endings and supported UTF-8/UTF-16/UTF-32 BOM/encoding. It writes the
existing file under an exclusive lock and verifies the exact resulting bytes.
The original bytes are retained only in memory for verification and restoration
after a caught write/readback failure. No configuration backup, temporary
configuration copy or HTML report
is created. A crash/power loss cannot be recovered from that memory snapshot.
After saving or finding SIX already enabled, a separate **Restart selected Payment
Service to load SIX Cron? [Y/N]** prompt explains that active payments may be
interrupted. N leaves service control untouched and reports runtime pending.
Y rechecks the selected service/process, configuration bytes and UID safety,
requests only that service's stop/start through WMI, and uses bounded state
polling. It never forces dependent services, changes recovery settings or kills
processes. Failed control responses trigger a selected-service recovery attempt
only when that service is confirmed stopped with the same executable command.

Reload verification requires a newer process creation time, the same executable path
and command, a stable Running state, and unchanged configuration. SIX registration
additionally requires fresh matching Name/UID and completed-registration messages
from `C:\Logs\Payment_Middleware_*.txt`, after the pre-restart file offsets and new
process start. The supported log format comes from Payment Middleware source
`a52d204e8e5d82b3ada0cb74b255d102018ae3c7`. Windows Restart Manager is queried
read-only to ensure the log has a single owner matching the selected PID and
process start time. The tool imports no Restart Manager shutdown/restart APIs.
Unreadable, ambiguous, stale, differently formatted or unowned logs remain
Not verified; observed startup errors fail verification. Pending verification
returns Skipped rather than Pass. No test payment/balance job is requested, and
job execution is not verified. No Payment Middleware source/binary is modified.
`Tests/Test-PaymentCronJob.ps1` covers byte-safe JSON changes; the separate
`Tests/Test-PaymentCronRuntime.ps1` uses synthetic service control and disposable
logs, plus a read-only native owner query on its own test process. In-memory menu
fixtures cover routing and terminal return behavior.

Thorough Check reports now use `C:\Thorough Check\` for both clients and all
execution paths. Existing restore-point behavior uses
`C:\Thorough Check\Restore Points\`. Audit creates the report directory only
when HTML output is requested. Existing Desktop reports and restore points are
left in place; this location change does not migrate or delete old files.

SaaS and Subway KIOSK Installation offer Microsoft Edge from the browser menu.
Google Chrome is temporarily marked **Not available**; selecting it keeps the
operator on the browser menu without starting setup. Chrome setup sources are
retained for future use. Each setup script prompts
for an existing kiosk account, Restaurant ID, Kiosk ID and Hostname before running
the supplied setup actions. Account and hostname suggestions can be confirmed
with Enter or changed manually. When a detected value is available, a separate gray hint appears above the input prompt; the bracketed value is the default and is not prefilled input. Hostname suggestions use the full Windows DNS hostname, preserving names longer than 15 characters; unavailable detection requires manual entry. Both browser setups are included in the release bundle.
See the [SaaS](Installations/KIOSK/SaaS/README.md) and [Subway](Installations/KIOSK/Subway/README.md) setup guides.

Kiosk ID input follows the same rules in all four SaaS/Subway Edge/Chrome
installation scripts: it is required and accepts only ASCII letters (`A-Z`,
`a-z`), numbers (`0-9`), dots (`.`), underscores (`_`), tildes (`~`) and
hyphens (`-`), matching `^[A-Za-z0-9._~-]+$`. Leading and trailing whitespace
is trimmed. Internal spaces, Bengali letters and other special characters
such as `&`, `/` or `#` are rejected. There is no explicit maximum length or
numeric range restriction. Examples accepted by input validation include `1`,
`01`, `Kiosk-1` and `KIOSK_02`.

Thorough Check reads the existing launcher's URL `kioskId` value without
enforcing the installation input character pattern. Missing, empty or duplicate
`kioskId` parameters are reported as issues. CLIENT DETAILS combines the device
type and identifier into **Device**: `1`, `01` and `Kiosk-1` all display as
`Kiosk-1`. This formatting does not change the configured ID. The launcher ID
takes precedence over a supplied `-KioskId`; if neither is available, Device
displays `Kiosk (number not verified)`. Non-numeric IDs retain their text.

SaaS and Subway KIOSK Thorough Check are Ready for Audit and Apply. Hostname display and launcher/monitoring comparisons use the full Windows DNS hostname; unavailable detection remains unverified. Final is a report tab generated from their observations. The shared
KIOSK dispatcher selects the client-isolated source: `SaaSKioskThoroughCheckScript.ps1`
for SaaS and `SubwayKioskThoroughCheck.ps1` for Subway. Each source runs in a
child 64-bit Windows PowerShell process when run locally and returns a verified completion signal
and report path to the launcher.

The CDN entry embeds these same sources and runs the menu and checks in separate
in-memory PowerShell sessions. It writes no project ZIP, extracted project folder
or completion file, and returns the exact report path through a completion
result. Reports and explicitly selected software installers still write their
normal output. The repository's local file-based execution path is retained.

Thorough Check collects mandatory **Agent Name**, then **Branch Name**, when
Audit is selected. Every newly generated report view shows **Prepared by: <Agent Name>**
at the bottom right, including the printed Final report. Apply Fix
does not ask again: it reuses the selected client's input from the current
session, including when the Audit report was declined. A fresh Apply run can
reuse Branch from a validated saved Audit for the same client and Windows
computer in the existing report folder, including filenames based on the
launcher hostname. Conflicting saved Branch values are not guessed. Without
usable metadata it reports Not provided; explicit `-ClientLocation` values
remain supported. No separate metadata/cache file is created.
Agent Name follows the same session reuse and is recovered from a uniquely
identified saved Audit in a fresh Apply run. Older reports without an agent
remain readable; newly generated views show **Prepared by: Not provided** until
Audit collects a name. Names are HTML-encoded before appearing in the footer.

The responsive report frame has a maximum width of 1200px. Header, tabs and
report frame share the same alignment. The inner report/table content is centered
with a maximum width of 1000px and shrinks to fit smaller screens, with 24px
desktop padding and 12px padding on small screens.
The 1000px limit applies only to screen media. Printing retains its existing
A4 portrait size, 12mm page margins, fonts and table spacing.

Audit uses five columns: **Component**, **Shortcut / Command**, **Setting**,
**Required** and **Findings**. Setting has a light gray background, Required
light blue and Findings light cream, with vertical separators. Record titles
are bold on a separate band; field labels use a lighter weight. Component and
copy commands span their setting rows, preserving the existing shared-command
deduplication and multiple-printer/account/service/terminal grouping.
Borders remain thin and plain. Hovering or focusing a copy command highlights
the entire component across all five columns and all of its record rows.
Moving away restores the column colors. Hover styles do not affect printing,
and reduced-motion preferences disable the transition.

Audit shows only the actual finding text: no extra Mismatch or Not verified
badge is appended. Values that meet requirements or record information remain
plain. Mismatches retain light red highlighting; unverified values use a clearer
amber background (#FFE3A0), dark text and a thin amber border. A real finding
of Not detected remains Not detected; a real Not verified value remains Not
verified. Existing comparisons and recorded outcomes are unchanged.
AppSettings remains a read-only configuration record, including False, zero
and empty values. Required fields without a corresponding observation use a
neutral dash rather than an invented finding. Opaque notes remain visible.

Fix uses **Component**, **Shortcut / Command**, **Setting**, **Findings** and
**Applied**. Final uses **Component**, **Setting** and **Status** in every section,
including AppSettings. Both share Audit's thin borders, record bands, column
colors and whole-component hover/focus highlight. In Fix the Findings column is
light blue and Applied light cream; Final Status is light cream.
Rendering any view never reruns device checks or applies configuration changes.
The preview appearance controls are not part of production reports.
`Tests/Test-AuditColumnLayout.ps1` covers the real renderer for both clients,
including grouping, aliases, escaping, commands, account-role requirements,
observation preservation and saved-report round-trips.
`Tests/Test-FixFinalSettingLayout.ps1` verifies actual new HTML, identity-based
before/after values, failed readback, missing/ambiguous records and historical
selection parity. Legacy business-rule fixtures execute both renderers and compare
current component/property/command selection before asserting the captured older
presentation; they do not substitute for the direct new-layout checks.

Each client/computer now keeps one self-contained HTML file under
`C:\Thorough Check\`: `Thorough Check Reports - <Client> - <Computer>.html`. The file
contains Audit, Fix and Final tabs and can be shared without
accompanying files. Each tab shows its own saved time and OMK report ID.

Audit records its actual findings when report generation is selected. It also
renders the unrun Fix and Final views from those same observations, retaining
the Audit report ID/time and identifying their Audit source. Fix Findings shows
only mismatched or unverified fields with the relevant identity and required
value (available in the finding tooltip); healthy values are omitted or retain
their existing context note. Its Applied column records Not applied for pending
items and never claims an Audit performed a repair.
Fix omits components that are healthy and unchanged. Failed, skipped, unverified
or manually actionable components remain, as do repairs recorded during this
Apply run. Sections with no remaining components are omitted. If observed checks
need no fixes, the view says No fixes required. Missing observations instead ask
the operator to run Audit. Audit and Final retain complete configuration data.
Healthy collected-only AppSettings components are omitted from Fix. Missing,
empty or unverified configuration is amber and stays visible with
Not applied in Applied; the original manual-review instructions remain in its tooltip.
Within account components, Fix also omits individual healthy unchanged accounts
and their commands. Unresolved accounts and accounts changed during that Apply
run retain their original account numbers and matching Findings/Applied blocks.
Account-specific check results are retained as report metadata; missing or
ambiguous repair history remains unverified. Audit and Final keep all accounts.

Apply Fix
preserves that Audit snapshot and saves both Fix and a Final view of the actual
post-fix readback, without rerunning checks. Apply-first still leaves Audit as
Not run because no Audit observations exist.
Fix Findings preserve the saved Audit observations; without Audit, a read-only
inspection captures the pre-fix state. Applied and Final use the current run's
actual outcomes. Only rendered fields are retained as observation metadata;
full appsettings documents and arbitrary account/configuration objects are excluded.

Hostname input appears only during Apply Fix and suggests the Windows computer
name. Apply can change only the existing launcher host parameter. Zabbix compares
and, when its explicit configuration is unambiguous, uses the actual Windows name.
Hostname mismatches are amber. Zabbix names are case-sensitive. Hostname file
edits are backed up and verified; failed Zabbix activation attempts restoration.
Windows computer names are not changed.

Account repair uses the WinNT UserFlags property to enable only the two requested
password flags while preserving other flags. It verifies readback, keeps existing
account eligibility, and makes no account, password, enabled-state or group changes.
Running Audit again refreshes the Audit-derived views until real Fix results
exist. Saved actual Fix/Final observations retain precedence over an Audit-derived
view. Existing separate report files are preserved.

Audit columns are Component, Shortcut / Command, Setting, Required and
Findings. Fix adds Setting between Shortcut / Command and Findings. Findings
preserves the selected pre-fix observations. Applied shows the corresponding
recorded post-fix value per setting, with original action notes in its tooltip.
An unrun Fix or read-only AppSettings field shows Not applied; an unavailable,
ambiguous or failed readback shows Not verified. No before-state is invented when
an older or partial run has no baseline: Findings then shows Not recorded.
Matching uses record identity and property name, rather than sibling positions.

Final columns are Component, Setting and Status. Status contains the latest
recorded value of that property, such as Idle, Enabled, a path, zero or False.
It does not display a component Pass/Fail badge. Audit-derived Final shows the
Audit observations; Apply updates it from the actual recorded readback.
Unverified and Not detected values remain explicit. Existing internal check
outcomes, account policies, repair eligibility and Fix filters are unchanged.

Final is available and printable after Audit, and Apply updates it from actual
post-fix readback. There is no separate Final option in the terminal menu.
Unverified/skipped internal outcomes remain unchanged; generating a view does not perform
checks or repairs. The legacy explicit `-FinalReport` switch remains compatible
for existing callers but is not needed for this reporting flow.

Only the Final tab offers a Print button. Printing includes that report alone,
without the tab bar, Audit or Fix. Reports do not open automatically.
The previous report layout can be restored using the saved points described in
[Backups/ReportLayouts](Backups/ReportLayouts/README.md).

Security, Network & System Integrity is report section 4. AppSettings Check is
section 5 and appears last among the five configuration sections in all three modes.

All applicable inbound firewall ports share one **Firewall** report
component and one `wf.msc` command. Required Configuration lists Inbound, TCP,
5009 plus 4100-4103 for NETS/NEXIDE, Enabled Yes and Action Allow. Findings show
actual rule Direction, Protocol, Ports, Enabled and Action; actual ranges or Any
are retained. Missing required allow rules and unreadable ports are identified
separately, and any failed/unverified required port keeps the group Fail. Values
are never filled from requirements when rule observations are unavailable.
Per-port checks and the agreed Apply repairs remain unchanged.

The Subway source is based on the current approved Thorough Check implementation.
For NETS or NEXIDE selected in the discovered Payment Service's appsettings.json,
Core Background Services includes **Payment Service Restart Task**. In all three
modes this check only reads existing Task Scheduler definitions and run history.
It verifies the selected service is the restart target, the task is enabled and
at least one enabled, unexpired trigger is configured. Task names and schedules
are collected rather than compared with an invented name or time. Common static
PowerShell restart actions and ordered stop/start batch actions are inspected
without executing their commands or scripts. Conditional, dynamic, unreadable
or unsupported actions require manual verification. Missing/disabled/unverified
tasks fail; multiple related task records remain visible. Run history is
informational, and a configuration Pass does not prove the restart actually ran.
The check never creates, enables, edits or runs a task, including in Apply Fix.
Other payment providers omit this component and do not query Task Scheduler.

Its client-specific controls require the `https://kiosk.subway.ch` launcher
origin and Edge local-network allowlist. Payment Service discovery prefers a
running `SubwayLocal` or `AspPaymentSubwayProd` service, falls back to a running
service that identifies as payment middleware, and finally retains an installed
but stopped expected service for Apply-mode recovery. The generated HTML report
uses the professional client-labelled layout and consolidated account results.

Both SaaS and Subway Thorough Check HTML reports use a plain device configuration
verification layout in Audit and Apply Fix modes. Reports contain device/run
details and per-check findings. Titles are Thorough Check Audit Report,
Thorough Check Fix Report and Thorough Check Report for Audit, Fix and Final,
respectively, shared with console
headers. HTML uses Client Details above metadata and Configuration Check
above component tables. The report title sits above a divider; the HTML header
omits SELISE and IT OPERATIONS branding. Audit columns are Component, Shortcut /
Command, Setting, Required and Findings. Fix uses Component, Shortcut / Command,
Setting, Findings and Applied. Final uses Component, Setting and Status for
all sections. Collection failures remain visible
in Findings and retain their internal outcome. Skipped/unverified checks map to Fail; verified
expected stopped legacy services map to Pass. The original recorded status is
retained in the status tooltip. Component contains only the check name.
Shortcut / Command contains one clickable box per command. Clicking a box or
pressing Enter/Space when it is focused copies the exact command and shows Copied.
The report includes a clipboard fallback for local HTML and shows a failure
message if the browser blocks both methods. No command is executed. Audit omits
Applied and Result columns. Print output retains command text and
hides copy feedback. `Tests/Test-ReportClipboard.ps1` tests browser interactions for all
four client/mode combinations using clipboard doubles; the OS clipboard is untouched.
Accounts are grouped
into KIOSK and administrative results, retaining each account's properties. When
no existing kiosk account can be identified, launcher, startup, auto-login and
browser-policy checks are omitted. Discovery accepts SELISE/SELISE-KIOSK, an
existing local user's registered launcher profile, or a configured local
auto-login user. Ambiguous launcher profiles require manual review. Missing
accounts are reported and never created. Standard kiosk account checks inspect Password
Never Expires and User Cannot Change Password. Apply enables each setting only
when disabled and verifies readback; Audit never changes them. Privilege is
recorded only, and passwords and account enabled/disabled state are preserved.
Hardware & Peripherals groups detected printers under a single Printer component,
plus the separate PrintService Log check. Apply enables
document retention only when disabled and enables the Operational log only when
disabled, with readback. It does not resume printer queues. Required Configuration
shows Printer Name: BIXOLON or EPSON, Printer status: Active / Idle / Error,
and Keep printed documents: Enabled.
Findings shows Printer Name, the observed status and Enabled/Disabled retention.
Audit aligns Required and Findings per setting within each printer record;
multiple printers retain numbered record headings. Other report modes retain
their existing grouped presentation.
Actual names remain in Findings under Printer Name. Shared copy commands appear once and each printer's own
command is retained. The grouped Apply result passes only if every printer is
verified Pass; partial discovery and unknown results remain Fail. Unhealthy
statuses, including paused/offline, display Error and remain Fail. Unavailable
printer data displays Not verified. Please check manually. The removed
Queue paused and Queue settings readable requirements are not shown in reports.
`Tests/Test-HardwareRequirements.ps1` exercises both clients/modes using fake printers
and event logs, including missing/unreadable detection and failed readback.
`Tests/Test-PrinterReportGroups.ps1` checks grouping, encoded names, exact copy
commands, mixed results and actual Audit/Apply report rendering for both clients.

Both clients include **Kiosk Launch Task** under Kiosk Application & Policies.
Audit reads existing `Launch Kiosk` tasks across Task Scheduler folders and
records their actual principal, logon trigger/user/delay, action, script path,
enabled state, execution limit and battery settings. The report also records
launcher-file availability and whether an existing Startup BAT is also present.
Missing tasks are reported as missing; unavailable inspection stays unverified.

Apply creates `\Launch Kiosk` only when no task with that name exists and the
selected local kiosk account, SID, enabled state, existing profile, launcher and
Windows PowerShell paths have been verified. It uses that account's existing
`Scripts\LaunchKiosk.ps1`, rather than assuming the username is SELISE-KIOSK.
The new task runs Windows PowerShell hidden at that user's logon after a
five-second delay, with `-NoProfile -ExecutionPolicy Bypass`, an interactive
token and limited privileges. It has no execution time limit, permits battery
operation, enables StartWhenAvailable and ignores concurrent instances.
StartWhenAvailable does not guarantee replay of a missed logon event.

Registration is create-only and stores no password. Existing tasks, including
disabled, incorrectly configured, differently located or ambiguous matches,
are preserved for manual review. Query failures never authorize creation.
Apply reads the definition back before reporting remediation; failed or
unavailable readback remains a failure. Audit, Fix and Final retain the agreed
setting columns, with actual before/after values in Fix and current recorded
values in Final. A verified definition does not prove the kiosk opened.
The check does not start the task, sign the user in, or change auto-login,
launcher content or Startup BATs. If the Startup BAT also exists, the report
warns that both logon launch paths remain configured; neither is removed.
This missing-only repair is separate from the read-only Payment Service
Restart Task check described above.
`Tests/Test-KioskLaunchTask.ps1` covers both clients using mocked registration
and native in-memory definitions, without registering or running a real task.

Audit inspects the launcher, profile and Startup without changes or prompts.
Within Kiosk Application & Policies, Apply may enable the two required kiosk
account properties, add missing browser-policy values and create a missing desktop
shortcut. The only authorized launcher-content repair is adding `--disable-pinch`
to a verified literal Edge argument string when it is missing. Audit remains
read-only. Other launcher content remains read-only in both modes, including
when required identifiers are missing or parameters are supplied.
It never creates a profile or launcher, normalizes existing
URL values, changes Startup files, or rewrites an existing desktop shortcut. It may create a missing
`Launch Kiosk.lnk` on an existing desktop after verifying the existing launcher.
The shortcut uses an existing verified Startup BAT. When the BAT is absent,
no shortcut is created and Findings reports "Missing. Manual action required."
Missing/invalid launchers and unverified existing BAT targets
are reported for manual review; they are not used to create a shortcut. A new
shortcut is read back; a failed readback removes only that newly created shortcut.
Existing launcher IDs, hostname, syntax and static URL are inspected only.
The Kiosk Launch Script row has five fields in Required Configuration
and Findings: Launch Script (Launcher Path in Findings), Restaurant ID, Kiosk ID,
Host name and URL origin. Findings shows the script path, collected identifiers and the URL origin without
its route or query. Shortcut and Startup BAT evidence remains internal to the
existing checks, with Startup Folder retaining its separate report row.
The complete URL remains available internally for verification and collecting
restaurant, kiosk and hostname values.
Missing restaurantId, kioskId or host values are reported for manual action;
no values are requested, filled or changed. Duplicate, conflicting, unsupported
or invalid URLs also require manual review. No launcher backup or temporary
files are created, and the launcher is never executed by the check.
System & Browser Policies includes `Pinch-to-Zoom: Disabled`. Its check inspects
one unconditional literal `Start-Process` call to Edge with a valid client kiosk
URL. Apply adds only the missing argument after verifying the existing Startup
BAT target, preserves encoding/BOM and all other content, takes an exclusive file
lock, detects concurrent changes, and verifies exact content readback. A failed
write/readback attempts restoration from the original bytes held in memory.
Dynamic, ambiguous or unsupported launch commands require manual action. Signed
launchers are never modified; missing protection in those requires manual action.
The argument applies on the next Edge launch; the check does not restart Edge.
Touchscreen pinch in/out must be tested manually afterward. This change does not
block keyboard, Ctrl+mouse-wheel, touchpad or browser-menu zoom.
`Tests/Test-PinchZoom.ps1` exercises isolated files and fake registry values.
Auto-login is inspected without reading passwords or requiring a DefaultPassword
registry value. Actual sign-in must be checked manually. Other sections retain
their previously approved repairs, including the separate Administrative
Accounts policy. `Tests/Test-KioskVerification.ps1` checks custom usernames, password
independence, missing-value reporting without prompts, encodings and file preservation.

Browser policies add missing required values only in Apply. Existing values,
value types and allowlist entries are preserved, even when they differ from the
reference. Such differences remain Fail for manual review. Existing correct
settings cause no registry writes. `Tests/Test-LauncherInspection.ps1` verifies both
clients/modes using isolated profiles, fake shortcuts and an in-memory registry.

The Zabbix install step downloads the SELISE CDN ZIP only when the Agent 2 service
is missing; it is not a bundled offline installer. The package's PowerShell
installer receives the hostname collected from the kiosk launcher through its
Hostname parameter in a non-interactive child process. The BAT wrapper is not
used. Apply first reuses the collected launcher hostname. Only when installing
a missing agent and that value is missing/unverified/unusable does it ask
`Zabbix Hostname`. The answer is validated before installation and report use;
blank/invalid input leaves installation skipped with Fail/manual action. The
fallback does not change the launcher or its report header hostname. Audit and
existing-agent checks never ask this question. There is no computer-name fallback.
The same
package defaults for Server/ServerActive and monitoring include file are retained.
A newly installed agent is started/restarted to load that include file, and its
service and configured hostname are checked afterward. Installation uses a unique
temporary staging folder; archive paths are checked before extraction, success
cleans only that verified folder, and failures retain files/logs for investigation.
For existing agents, Apply repairs service state, startup type and recovery
actions without editing configuration files or reinstalling. Missing, unreadable,
dynamic/unverified or launcher-mismatched hostnames result in Fail/manual review.
Server and ServerActive are not currently validated or repaired by Thorough Check.

AppSettings follows point 7 of the requirements document: PaymentService,
PaymentConfiguration (SixTerminals for SIX; NetsTerminals for NETS/NEXIDE; omitted
for PRINT), ScheduleConfiguration for KitchenTicketPrint (displayed as
WebApp Printer), Cron Job for the selected SIX/NETS/NEXIDE provider,
Print and the three service URLs. Cron Job collects only Provider and
IsEnabled from matching schedule entries; both True and False are valid recorded
values. PRINT omits Cron Job as well as payment terminals, while
WebApp Printer remains visible. WebApp Printer collects Provider, BranchUUID,
IsKioskPrintingEnabled and IsEnabled from each KitchenTicketPrint schedule.
BranchUUID comes only from ScheduleConfiguration.Schedules[].BranchUUID (or
the same kitchen record in a supported direct/array ScheduleConfiguration shape).
Root, Print and payment-schedule BranchUUID values are not substituted. Missing
or empty BranchUUID remains explicit and read-only. Missing matching schedules/values are reported
as not configured. Cron Job always labels each matching record NETS Terminal for
NETS/NEXIDE or SIX Terminal for SIX, including a missing-record placeholder.
The title follows the provider family rather than a schedule index. Multiple
matching records remain separate and keep their recorded Provider/IsEnabled values.
Print.PrinterName is labelled Kitchen Printer and Print.KioskPrinterName is
labelled Kiosk/POS Printer; the original JSON keys and values are unchanged.
AppSettings remains read-only in both modes. These groups show actual file
values. Expected uses labelled lines;
terminal collection headings use [SixTerminals] / [NetsTerminals], and numbered
terminal/account headings use [Terminal 1], [Account 1], [Account 2], etc.
Audit Findings contains observed state only. Reports omit overall-result summaries,
sign-off records and Exceptions / Corrective Actions. AppSettings Expected retains
the field labels without placeholder values.
Standard KIOSK Required Configuration contains the detected account name (or SELISE or
SELISE-KIOSK when missing), Local user as the reference privilege, Account Status
Active / Disabled,
Password Never Expires Enabled and User Cannot Change Password Enabled.
For KIOSK/local and administrative accounts, the name reference lists the
discovered names or the administrative reference as appropriate. Audit aligns
requirements per setting inside numbered account records. Administrative
records omit User Cannot Change Password even when grouped with standard
kiosk accounts. Fix and Final retain their existing account presentation.
Available KIOSK Findings records each account's name, actual privilege, Active/Disabled status
and both password property values. Privilege is observed without changing group membership; administrative accounts use the administrative password policy.
Missing-account Findings reads `Account Missing. Please create manually.` Administrative Findings includes
each account's name, privilege, Active/Disabled status and Password Never Expires. User Cannot Change Password is not an administrative requirement or reported field.
The administrative-account name reference is always Admin, Administrator,
independent of discovered account names. Findings and commands use the actual accounts.
An unreadable activation status is reported as Not verified.
Active means the Windows account is enabled, rather than currently signed in.
Administrative accounts are ordered with Admin first and Administrator second,
followed by other discovered local administrators. An active local administrator
with a launcher profile can also be a KIOSK account; neither role removes the
other. Password-property read failures retain the known account name, privilege
and activation status, while the unreadable properties remain Not verified.
Both account sections prefer active accounts and omit disabled alternatives
when an active candidate exists. Administrative discovery also accepts active
local administrator-group members under other names; if none are active, found
disabled Admin/Administrator accounts remain visible. KIOSK discovery likewise
retains found disabled kiosk candidates only when no active candidate exists.
Disabled accounts' password properties are read only, including in Apply Fix.
Account activation and privilege membership are never changed.
Account command boxes use actual detected usernames, preserving their spelling
and quoting. Grouped accounts receive one net user command per detected account.
Missing accounts show only lusrmgr.msc; expected aliases are not used as usernames
in commands. `Tests/Test-AccountReportCommands.ps1` covers missing, single, grouped,
administrative and unreadable-property accounts in both modes without live changes.
`Tests/Test-SharedAccountRequirements.ps1` renders both clients/modes with single,
multiple, missing, unreadable and partially readable account fixtures; it verifies
shared requirements, individual observations and preserved statuses.
TCP ports 4100-4103 are checked and reported only for NETS or NEXIDE; other providers
produce no placeholder row. TCP 5009 remains applicable to every provider.
The header displays a Report ID formatted OMK-000000 (six digits after OMK-), Generated time, Client,
Branch, Device type with its configured number (for example KIOSK-01), and Launcher
Hostname. Report mode and Computer name are omitted. Missing device numbers are
labelled unverified. Internal timestamp/GUID run IDs remain in report filenames.
Core service reports list first, second and subsequent recovery actions
individually. Payment middleware Expected contains client-specific names and
version 0.0.0.0 as a reference placeholder; Findings contains the detected service
name and actual installed version. There is no fixed version target. Missing or
unreadable versions remain unverified rather than being replaced by the placeholder.
Thorough Check checks and repairs only recovery action types. Payment/Zabbix
requires Restart for first/second failures and Take No Action for subsequent
failures. Existing restart delays and failure reset periods are preserved;
there is no required timing value and timing differences do not cause Fail.
Native recovery updates copy current timing, change only action types, and verify
both the actions and preserved timing afterward. When an action array needs more
entries, Windows' existing repeated-last-entry delay is retained; an absent array
has no configured delay and retains the zero/no-delay baseline. No fixed 60-second
or reset-0 policy is applied. Windows Update and older payment-service No Action
repairs likewise preserve timing and unrelated recovery settings. The separate
Zabbix installer is invoked only for a missing agent. Older
discovered payment services require Stopped / Manual and Take No Action for first,
second and subsequent failures. Apply verifies the final primary result and
rechecks its live service settings before changing an older service. It disables
older-service restart recovery before stopping it and reads back actual state
and recovery actions; Audit records these fields without changing them.

The separate Administrative Accounts check enables only the required
Password Never Expires setting when needed, then verifies readback. Apply also clears the existing password-change restriction and verifies that password changes are allowed. Both account components
display Standard or Administrator as the privilege reference, with the actual
observed privilege labelled Standard or Administrator in Findings. Unknown
privileges remain unverified. These report labels do not change account discovery,
membership, the underlying privilege checks or recorded results.
An account's enabled state is not part of these administrative requirements.
Standard kiosk account checks enable Password Never Expires and User Cannot Change Password in Apply and verify
readback, with the administrative policy taking priority for any account also serving as an administrator. Account availability and
actual identity/privilege are recorded; enabled state, passwords and group
membership are preserved. No missing account is created.
`Tests/Test-KioskAccountProperties.ps1` checks all combinations of both flags across
clients/modes, aliases/custom users, observed privileges, disabled accounts,
missing accounts, failed reads/writes/readback and repeated Apply with isolated
in-memory accounts. It verifies that only missing password settings or an existing administrative restriction are supplied to a write.
`Tests/Test-ApplyRequirements.ps1` verifies administrative and service boundaries,
legacy service recovery, primary protection and recovery action selection with
in-memory fixtures. Version 0.0.0.0 remains an example in both modes; Findings
retains the actual detected version. AppSettings is read-only in both modes.

Firewall creation/update runs only when no enabled inbound TCP Allow rule is
found for the required port. A matching rule is retained without widening its
profiles. Newly created or repaired managed rules use Profile Any. This is a rule
presence check, not proof of connectivity or coverage of every firewall profile.
Zabbix Required Configuration uses the collected launcher hostname, or the
validated fallback entered for missing-agent installation, and Findings shows
the configured monitoring hostname. Windows Update now requires Stopped /
Disabled and first, second and subsequent failures set to Take No Action.
Apply corrects only mismatches and verifies actual state/startup/recovery; Audit
only records actual values. This replaces the earlier startup-preserved behavior.
Disabled prevents starts while it remains configured; this check does not prevent
a later administrator, management policy or system repair from changing it.
Test-CoreServiceChanges checks hostname transport/matches/installation guards and
the Windows Update state/startup/recovery matrix, failure readback and repeat
safety. Test-ZabbixInstallerCommand executes generated child commands with tiny
fixture ZIPs and fake network/service APIs; no actual MSI or Windows service runs.
Test-RecoveryTimingPreservation compiles the native helper and exercises managed
action planning/fixture policies with different existing reset periods/delays,
including INFINITE, repeated action entries, empty policies, no-op repeats and
Audit/failure guards. The test never calls native service APIs.
Report component and AppSettings labels use the requested short display names,
including Payment Gateway, Zabbix Agent, WebApp Printer and Performance Counter.
Firewall rows use Firewall while Required Configuration retains each
port number. Original internal titles, service names, JSON keys and copy commands
are preserved for checks and configuration handling.

`Tests/Test-ReportLayout.ps1` renders synthetic reports for both clients and modes
without running device checks. Generated preview reports and test fixtures are stored in
`output/report-layout` and contain sample data.
`Tests/Test-ThoroughRequirements.ps1` checks grouped accounts, missing-user guards,
Audit/Apply account behavior and provider-specific AppSettings using mocked data.
`Tests/Test-PayoutScheduler.ps1` checks matching payout providers, PRINT omission,
schedule shapes, true/false values, missing fields, read-only JSON preservation
and real report rendering across both clients and modes.
`Tests/Test-CoreServiceReports.ps1` checks service-field order, recovery action decoding,
hostname configuration sources, read-only Audit and verified Apply outcomes using
in-memory service fixtures.
`Tests/Test-ReportMetadata.ps1` checks display ID length, device-number formatting,
unknown-number handling, launcher Restaurant ID capture, safe metadata rendering,
snapshot round-trips and inconsistent saved metadata rejection.

CLIENT DETAILS retains its original bordered table with three rows:
Client Type / Branch, Restaurant ID / Hostname, and Device / Prepared by.
Device combines the type and identifier (for example, Kiosk-1); there is no
separate Device Number field. Prepared by uses the same Agent Name as the
report footer. Restaurant ID comes
from the kiosk launcher's URL restaurantId parameter, or Not detected when
unavailable. The internal report identity remains
available for saved-report validation; older reports with a visible Report ID
remain readable. Generated Time appears in the report footer alongside
Prepared by, using dd MMM yyyy, h:mm tt BST in Bangladesh time (UTC+06:00).
It no longer occupies a header field. Older boxed metadata reports remain
readable, including recovery of their saved Branch values. Branch Name rejects empty/whitespace-only input but has no
additional character or length restriction; it is HTML-encoded for display.
The header Hostname always records the detected Windows DNS hostname. During
Apply Fix, a valid operator-entered hostname takes precedence for the launcher
host parameter. Zabbix uses the detected Windows hostname. Neither input nor the launcher update renames Windows.

Both clients use the same compact progress log for Audit and Apply Fix: one
client/device/mode header, numbered aligned status lines and short explanations
for checks needing attention. Floating progress bars, per-step timestamps and
routine service-read messages are hidden by default; diagnostics use Verbose.
The log retains STOPPED for expected inactive legacy services, SKIP for skipped
checks and UNKNOWN for unverified statuses. Payment and Zabbix lines wait for
their version and hostname verification before printing the final status.
Detailed requirements, findings and actions remain in HTML. Audit ends with the
optional Generate HTML report? [Y/N] prompt; declining creates no report files.
Apply saves its report before announcing completion. The launcher preserves the
completed log for either mode and still displays startup errors.
`Tests/Test-ConsoleProgress.ps1` exercises both clients/modes with synthetic rows and
isolated finalizers; sample logs are in `output/console-progress`.

For both clients, Windows 10 Thorough Check Apply uses a prepared local Nmap
installer from `Packages/Nmap` when Nmap is missing. It checks SHA256, opens the
standard setup wizard, waits for it, and verifies `nmap --version` before Pass.
Audit remains read-only; existing installations are retained. Prepare the folder
with [Save-NmapPackage.ps1](Packages/Nmap/Save-NmapPackage.ps1) before copying the
scripts to a device; see [package instructions](Packages/Nmap/README.md).
`Tests/Test-NmapLocalPackage.ps1` covers both clients using fake installer bytes and
mocked process calls. The actual installer is not yet included: the official
download failed HTTPS certificate validation during this change. No installer
was executed. Package preparation must succeed before the Windows 10 fallback
can install Nmap.

Audit reports for both clients include **Additional** below the configuration
checks. Nmap has one copy button for the complete three-line PowerShell script
that downloads `nmap-7.95-setup.exe` to TEMP and opens its manual installation
wizard. Printer Utility links to the supplied Epson TM-m30III download page in
a new tab. These are manual operator references: rendering or opening the Audit
does not download or execute an installer. Fix and Final omit this section.
Existing Nmap checks and Apply installation rules remain unchanged.

Thorough Check for POS/KDS, Payment Service and other client/device installations remain Pending. Selecting
a Pending operation returns Unavailable and makes no system changes.

## Local preview

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-DeviceManagement.ps1
```

The local launcher imports modules using `$PSScriptRoot`. The CDN build embeds its runtime dependencies in a single in-memory entry; see `Deployment/README.md`.

`Tests/Test-AdministrativeAccountPolicy.ps1` verifies the Administrator-only password requirement across Audit/Apply, enabled/disabled accounts, readback failures, repeated runs, and all report modes. Apply clears existing administrative password-change restrictions. Standard kiosk accounts retain both password flags; a shared administrator/kiosk account follows the administrative policy, preventing repeated checks from reversing the permission change.
