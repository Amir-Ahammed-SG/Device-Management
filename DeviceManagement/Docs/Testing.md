# Tests and CI

Use 64-bit Windows PowerShell 5.1. Tests load real function definitions, inspect
AST-selected guarded blocks and execute synthetic child/runspace fixtures. They
never execute the full production check engine, install software or mutate a
real account, service, task, registry setting or clipboard.

## Run all maintained fixtures

```powershell
.\Tests\Run-Regression.ps1
```

The runner creates a unique release, discovers every `Tests/Test-*.ps1` script,
runs each in a fresh process and writes logs and `results.json` under
`output/regression/<release-id>/`. Any failed test makes the runner exit 1.
Browser tests are explicitly recorded as skipped by the default deterministic run.

For complete browser coverage, install Edge and Node.js 24, then run:

```powershell
.\Tests\Run-Regression.ps1 -IncludeBrowser
```

Browser tests create their own synthetic snapshots, use a dedicated hidden Edge
profile, and mock clipboard APIs. They cover safe command copying, keyboard input,
modern/fallback/error feedback, combined modes, missing modes, mobile layout and
Final-only print/PDF. They require permission to start browser child processes;
a restricted process sandbox can prevent Edge from starting. Such a failure is
not a passing browser test.

## Optional native Windows integration

The normal Payment Cron runtime fixture tests ownership/PID/time checks through
controlled boundaries, including denied and ambiguous ownership. Windows Restart
Manager itself can be checked on a controlled host by setting
`DEVICE_MANAGEMENT_NATIVE_TESTS=1` before running Test-PaymentCronRuntime.ps1.
An unavailable native API fails that opt-in check; it is not silently accepted.
No production service is controlled in either mode.

## Coverage and release gate

- Shared module loading: actual local/embedded libraries, client isolation and
  missing-module preflight rejection.
- Shared installation: one parameterized fixture body, separate SaaS/Subway
  processes; account/hostname inputs, prerequisites, readback and repeat behavior.
- Accounts, services, launcher and payment: read-only Audit, narrow Apply writes,
  failed readback, rollback, unknown state and idempotence.
- Reports: current per-setting schema, immutable observations, client identity,
  filtering, encoded values and one-file snapshot preservation. Tests no longer
  require old generated HTML/function files or local backups.
- Static analysis: pinned analyzer and failure/coverage-policy fixtures.

GitHub Actions pins the official setup-node action, selects Node.js 24, runs analysis first, then Test-GitHubRelease with browser tests.
That release gate validates source/runtime hashes and invokes this same discovered
suite. Regression logs and results are retained as CI artifacts even on failure. The Linux deployment fixture job runs Test-GitHubDeployment.py against fake
SSH/SCP/HTTPS boundaries, including rollback. Publishing remains gated by the
existing deployment variables and main-branch restrictions.

The earlier Legacy Pester suite referenced retired modules and old requirements.
It is preserved in the verified local recovery archive; it is not part of the
maintained test inventory. Current equivalents cover shared dispatch/navigation,
account/service safety and current report behavior. Historical renderer fixtures
that still test compatibility are retained under `Tests/Fixtures`.
