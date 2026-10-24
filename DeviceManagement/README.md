# SELISE Device Management architecture

This folder contains the client, device, operation, package-version and mode
navigation with validated operation routing.

Deferred production findings are tracked in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

Runtime code is in `Start-DeviceManagement.ps1`, `Core`, `Config`, `Checks` and `Installations`.
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
   run their reviewed installation handler directly.

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

SaaS and Subway KIOSK Installation are available directly from the operation menu. Each prompts
for an existing kiosk account, Restaurant ID, Kiosk ID and Hostname before running
the supplied setup actions. Account and hostname suggestions can be confirmed
with Enter or changed manually. Each uses its supplied client-specific setup body.
See the [SaaS](Installations/KIOSK/SaaS/README.md) and [Subway](Installations/KIOSK/Subway/README.md) setup guides.

SaaS and Subway KIOSK Thorough Check are Ready for Audit and Apply. Final is a report tab generated from their observations. The shared
KIOSK dispatcher selects the client-isolated source: `SaaSKioskThoroughCheckScript.ps1`
for SaaS and `SubwayKioskThoroughCheck.ps1` for Subway. Each source runs in a
child 64-bit Windows PowerShell process when run locally and returns a verified completion signal
and report path to the launcher.

The CDN entry embeds these same sources and runs the menu and checks in separate
in-memory PowerShell sessions. It writes no project ZIP, extracted project folder
or completion file, and returns the exact report path through a completion
result. Reports and explicitly selected software installers still write their
normal output. The repository's local file-based execution path is retained.

Thorough Check collects **Branch Name** when Audit is selected. Apply Fix
does not ask again: it reuses the selected client's input from the current
session, including when the Audit report was declined. A fresh Apply run can
reuse Branch from a validated saved Audit for the same client and Windows
computer in the existing report folder, including filenames based on the
launcher hostname. Conflicting saved Branch values are not guessed. Without
usable metadata it reports Not provided; explicit `-ClientLocation` values
remain supported. No separate metadata/cache file is created.

The responsive report frame has a maximum width of 1200px. Header, tabs and
report frame share the same alignment. The inner report/table content is centered
with a maximum width of 1000px and shrinks to fit smaller screens, with 24px
desktop padding and 12px padding on small screens.
The 1000px limit applies only to screen media. Printing retains its existing
A4 portrait size, 12mm page margins, fonts and table spacing.

Audit and Apply report modes highlight individual Findings values: light green
for a matched requirement or collected information, light red for a mismatch or
missing value, and light amber #FFF8E1 for unverified values or manual review.
AppSettings uses collected-value colors and remains read-only. A legend explains
the colors. Component statuses retain
the actual check results independently of these display styles.

Each client/computer now keeps one self-contained HTML file under Desktop →
Thorough Check: `Thorough Check Reports - <Client> - <Computer>.html`. The file
contains Audit, Fix and Final tabs and can be shared without
accompanying files. Each tab shows its own saved time and OMK report ID.

Audit records its actual findings when report generation is selected. It also
renders the unrun Fix and Final views from those same observations, retaining
the Audit report ID/time and identifying their Audit source. Fix Findings shows
only mismatched or unverified fields with the relevant identity and required
value; healthy values become No change needed. Its Applied column records Not
Applied for pending items and never claims an Audit performed a repair.
Fix omits components that are healthy and unchanged. Failed, skipped, unverified
or manually actionable components remain, as do repairs recorded during this
Apply run. Sections with no remaining components are omitted. If observed checks
need no fixes, the view says No fixes required. Missing observations instead ask
the operator to run Audit. Audit and Final retain complete configuration data.
Healthy collected-only AppSettings components are omitted from Fix. Missing,
empty or unverified configuration is amber and stays visible with
Expected values are not configured. Please check manually. in Applied.
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

Audit columns remain Component, Shortcut / Command, Required Configuration and
Findings. Fix columns are Component, Shortcut / Command, Findings and Applied;
Applied records actual action notes or No change needed. After Apply, Findings
preserves the saved Audit or pre-fix observations. Final columns are
Component, Final Configuration and Status. AppSettings only records values:
Fix shows manual review for missing values and Read Only for collected values;
Final omits Status. Final remains neutral with
no green, red or amber findings or status colors.

Final is available and printable after Audit, and Apply updates it from actual
post-fix readback. There is no separate Final option in the terminal menu.
Unverified/skipped observations remain Fail; generating a view does not perform
checks or repairs. The legacy explicit `-FinalReport` switch remains compatible
for existing callers but is not needed for this reporting flow.

Only the Final tab offers a Print button. Printing includes that report alone,
without the tab bar, Audit or Fix. Reports do not open automatically.
The previous report layout can be restored using the saved points described in
[Backups/ReportLayouts](Backups/ReportLayouts/README.md).

Security, Network & System Integrity is report section 4. AppSettings Check is
section 5 and appears last among the five configuration sections in all three modes.

All applicable inbound firewall ports share one **Firewall Inbound Port** report
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
details and per-check findings. Titles are Thorough Check Audit Report and
Thorough Check Report for the respective modes, shared with console
headers. HTML uses Report Details above metadata and Configuration Check
above component tables. The report title sits above a divider; the HTML header
omits SELISE and IT OPERATIONS branding. Audit columns are Component, Shortcut /
Command, Required Configuration and Findings. Apply Fix adds Status, containing
Pass or Fail, to verification sections. AppSettings Check retains the same four
columns as Audit because it records values. Collection failures remain visible
in Findings and retain their internal outcome. Skipped/unverified checks map to Fail; verified
expected stopped legacy services map to Pass. The original recorded status is
retained in the status tooltip. Component contains only the check name.
Shortcut / Command contains one clickable box per command. Clicking a box or
pressing Enter/Space when it is focused copies the exact command and shows Copied.
The report includes a clipboard fallback for local HTML and shows a failure
message if the browser blocks both methods. No command is executed. Reference,
Applied and Result columns are omitted. Print output retains command text and
hides copy feedback. `Tests/Test-ReportClipboard.ps1` tests browser interactions for all
four client/mode combinations using clipboard doubles; the OS clipboard is untouched.
Accounts are grouped
into KIOSK and administrative results, retaining each account's properties. When
no existing kiosk account can be identified, launcher, startup, auto-login and
browser-policy checks are omitted. Discovery accepts SELISE/SELISE-KIOSK, an
existing local user's registered launcher profile, or a configured local
auto-login user. Ambiguous launcher profiles require manual review. Missing
accounts are reported and never created. Kiosk account checks inspect Password
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
Required Configuration appears once for all printers, without numbered headings.
For multiple printers, Findings uses [Printer 1], [Printer 2], etc. blocks.
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
WebApp/Shop Print), Payout Scheduler for the selected SIX/NETS/NEXIDE provider,
Print and the three service URLs. Payout Scheduler collects only Provider and
IsEnabled from matching schedule entries; both True and False are valid recorded
values. PRINT omits Payout Scheduler as well as payment terminals, while
WebApp/Shop Print remains visible. Missing matching schedules/values are reported
as not configured. Multiple matches retain separate numbered Findings blocks.
AppSettings remains read-only in both modes. These groups show actual file
values. Expected uses labelled lines;
terminal collection headings use [SixTerminals] / [NetsTerminals], and numbered
terminal/account headings use [Terminal 1], [Account 1], [Account 2], etc.
Audit Findings contains observed state only. Reports omit overall-result summaries,
sign-off records and Exceptions / Corrective Actions. AppSettings Expected retains
the field labels without placeholder values.
KIOSK Required Configuration contains the detected account name (or SELISE or
SELISE-KIOSK when missing), Local user as the reference privilege, Account Status
Active / Disabled,
Password Never Expires Enabled and User Cannot Change Password Enabled.
For both KIOSK/local and administrative accounts, Required Configuration appears
once per component and lists the discovered account names together. Numbered
[Account 1], [Account 2], etc. blocks appear only in multiple-account Findings.
Available KIOSK Findings records each account's name, actual privilege, Active/Disabled status
and both password property values. Privilege
is observed without enforcing a group change or affecting kiosk Pass status.
Missing-account Findings reads `Account Missing. Please create manually.` Administrative Findings includes
each account's name, privilege, Active/Disabled status and the two password-property values.
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
Password Never Expires and User Cannot Change Password settings when needed,
then verifies readback. It also verifies the required Local Administrator
privilege; a mismatch remains Fail for manual action. Both account components
display Standard or Administrator as the privilege reference, with the actual
observed privilege labelled Standard or Administrator in Findings. Unknown
privileges remain unverified. These report labels do not change account discovery,
membership, the underlying privilege checks or recorded results.
An account's enabled state is not part of these administrative requirements.
Kiosk account checks enable the same two required properties in Apply and verify
readback, while treating privilege as observation only. Account availability and
actual identity/privilege are recorded; enabled state, passwords and group
membership are preserved. No missing account is created.
`Tests/Test-KioskAccountProperties.ps1` checks all combinations of both flags across
clients/modes, aliases/custom users, observed privileges, disabled accounts,
missing accounts, failed reads/writes/readback and repeated Apply with isolated
in-memory accounts. It verifies only disabled properties are supplied to a write.
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
including Payment Gateway, Zabbix Agent, WebApp/Shop Print and Performance Counter.
Firewall rows use Firewall Inbound Port while Required Configuration retains each
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
unknown-number handling and kiosk ID capture independent of hostname discovery.

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

Thorough Check for POS/KDS, Payment Service and other client/device installations remain Pending. Selecting
a Pending operation returns Unavailable and makes no system changes.

## Local preview

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-DeviceManagement.ps1
```

The local launcher imports modules using `$PSScriptRoot`. The CDN build embeds its runtime dependencies in a single in-memory entry; see `Deployment/README.md`.
