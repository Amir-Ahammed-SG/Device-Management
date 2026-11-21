# Local verification - 14 November 2026

All five project optimizations are implemented in the working source:

- The maintained regression suite is discovered automatically and CI includes
  browser tests, pinned Node.js 24 setup, failure logs and release verification.
- One parameterized installation fixture exercises SaaS and Subway in separate
  processes; the two duplicate installation scripts are retired.
- Root/application READMEs are concise. Architecture, testing and recovery details
  are in separate guides. Broken references to retired client folders/records
  have been corrected.
- 750 working-source and historical-record files were archived and every entry
  verified against SHA256 before removing historical directories. The retired
  Legacy suite is preserved there. Active tests need no local records.
- 189 functions were extracted into five shared libraries. The engine is now
  1,075 lines instead of approximately 6,149. Comparison against the recovery
  snapshot confirmed unchanged orchestration tokens and 188 identical function
  bodies; the remaining function adds the explicit Zabbix service-assembly
  dependency needed by its child process.
- Maintenance tools load named definitions from the same shared libraries.
  Missing/invalid local libraries and missing embedded dependencies fail before
  device checks execute.

## Results

| Check | Result |
| --- | --- |
| Full Windows PowerShell 5.1 release gate | Passed |
| Maintained fixture scripts, including both browser suites | 65 passed, 0 failed, 0 skipped |
| Fake SSH/SCP/HTTPS deployment/rollback fixtures | 9 passed (Python 3.11 / Git Bash) |
| PowerShell source parsing | 105 files passed |
| PSScriptAnalyzer 1.25.0 | 33 files, 0 errors, 215 advisory warnings, 0 blocking findings |
| Source/runtime resource and bootstrap hashes | All 23 resources matched |
| Runtime sources rechecked after the full suite | Matched the verified manifest |
| Markdown local links and git diff --check | Passed |
| Regression release-ID generation and traversal rejection | Passed |

Release: `20261114-optimized-final-02`.
Bootstrap SHA256: `508b037bb23a3762d3a3127c2c8df093d56c7ad63cc4ce5727fd235f42834af0`.

Recovery snapshot: `Backups/Archive/before-optimization-20261114-b93d0853.zip`.
Snapshot SHA256: `f6c105abd9c1cdf90fae98e26c425fb0d1d16d6fb8253e9ac327436f7ab2b90f`.
Release bytes, manifest, final fixture logs/results, analyzer reports and synthetic
HTML previews are retained in the local verification archive under Backups/Archive.
Generated working output is removed afterward.

## Scope

Tests use synthetic data and controlled device-operation boundaries. Browser
clipboard calls are mocked; print/PDF checks create no printer jobs. Native
Restart Manager integration remains opt-in. No production Audit/Apply/installation
or CDN publication was executed. A controlled device run is still required to
validate real services, profiles, registry and installers.

## Repository layout verification

The application now lives directly under `DeviceManagement/`; the redundant
`Scripts/` parent was removed. README links, ignore rules and GitHub Actions
source/artifact paths were updated. Existing CDN endpoints and deployment
settings were preserved. No publication was performed.

Verification release: `20261114-root-layout-01`.

- All 105 PowerShell source files parsed; the release built successfully.
- All 23 source/runtime resource hashes match the previous verified release.
- The regression run recorded 63 passes and two browser timeouts inside the
  restricted sandbox. Both browser suites passed when rerun outside the sandbox;
  the original failed-run results remain intact. The release gate itself exited
  with failure because of those sandbox timeouts.
- All nine fake deployment/rollback tests passed from the new location.
- Static analysis: 33 files, zero errors, 215 advisory warnings, zero blocking
  findings. Local links in all 15 Markdown files and `git diff --check` passed.

These checks used fixtures; no production device operations were run.
