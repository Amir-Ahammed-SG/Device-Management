# PowerShell static analysis

This is developer/CI tooling. It is not included in the kiosk release and does
not execute or automatically fix analyzed scripts. Windows PowerShell 5.1 x64
and PSScriptAnalyzer **1.25.0** are used locally and in CI.

From the `DeviceManagement` directory:

```powershell
.\Deployment\Install-ScriptAnalyzer.ps1
.\Deployment\Test-ScriptAnalysis.ps1
```

The installer uses the current-user module scope and the official PSGallery
repository. It does not change repository trust settings. The checker never
installs missing tooling or silently falls back to a different module version.

Reports are written under `output/script-analysis/`:

- `report.md`: summary by rule and every finding with its path and line.
- `report.json`: findings, counts, completeness, source hashes, policy/settings
  hashes, analyzer version and PowerShell version.

Use `-Mode ReportOnly` to collect findings without failing on policy violations.
Tool failures, invalid policy, missing inputs and empty coverage still fail.
`FindingsDetected` is retained when report-only mode encounters blocking findings.
An interrupted or unsuccessful setup/coverage run cannot leave an earlier Passed
report in place: the current report starts as `NotCompleted`, `Complete=false`.

## Scope and policy

`Policy.psd1` explicitly selects root runtime scripts and the Core, Config,
Checks, Installations, OtherTools, Packages, Handlers, Tools and Deployment
directories. Discovery skips reparse points and excludes output, backups,
documentation, Tests, dependency folders and local credential/configuration
directories. `Bootstrap.ps1.template` is excluded because it contains unresolved
build placeholders; the emitted bootstrap is parsed and fixture-tested by the
existing release gate. Test code has its separate functional-test jobs.

Default Error and Warning rules remain enabled. CI blocks on:

- Every analyzer Error and PowerShell parser error.
- `PSAvoidUsingPlainTextForPassword`, even though it is normally a Warning.
- `PSAvoidUsingConvertToSecureStringWithPlainText` (also covered by Error severity).
- Analyzer/tool failures, missing source files, unknown blocking rules, changed
  sources during analysis, missing pinned tooling, and empty coverage.

Other warnings remain visible and advisory. There is no blanket exclusion list,
warning baseline or new source-level suppression. Do not globally disable a rule
to make CI green. Any future exception needs a narrow scope, justification,
reviewer and tests for the intended behavior.

## CI

The `script-analysis` job installs the pinned version, runs 14 disposable gate
scenarios, analyzes the selected sources, writes the job summary and uploads
reports for 30 days, including when the analysis step fails. The existing build
job depends on this job; deployment remains dependent on the build and deployment
fixtures. This does not configure deployment credentials or publish a release.

## Warning review

The initial scan found no analyzer Errors. Review the full report before
addressing warnings:

1. Automatic-variable assignments (`$Matches`, `$PROFILE`, `$Event`) need a
   function-by-function review, particularly where regular expressions also use
   `$Matches`. Rename only with behavioral tests.
2. ShouldProcess findings need review of actual writes and existing caller-level
   approval/WhatIf boundaries. Several `New-*` helpers only construct objects or
   HTML; adding prompts to these helpers would change report behavior.
3. Unused parameters/variables may be compatibility interfaces or incomplete code.
4. Verb/noun naming and Write-Host are lower-priority review items. This is an
   interactive console application, so console output is intentional in many cases.

Warnings were not automatically fixed. A passing static gate does not replace
functional tests, security review, or a controlled SaaS/Subway kiosk test.

Official references:
- https://www.powershellgallery.com/packages/PSScriptAnalyzer/1.25.0
- https://learn.microsoft.com/powershell/module/psscriptanalyzer/invoke-scriptanalyzer
