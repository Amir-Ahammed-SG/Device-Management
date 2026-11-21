# Local records and recovery

Old application backups, validation records, deployment receipts and the retired
Legacy Pester suite were consolidated into a verified ZIP under the repository's
local `Backups/Archive/` folder. The archive includes working sources from before
optimization, including uncommitted changes. Its archive-manifest.json records
original workspace-relative paths and SHA256 hashes. Every entry was read back
and verified before removing the original historical directories.

`Backups/CDN/` remains separate: it contains CDN snapshots and checksums needed
for deployment recovery. Archives and customer/device data are not tracked or
published. A fresh clone does not require these local archives to run or test.

To recover a file, inspect archive-manifest.json, extract the required entry into
a separate review folder, verify its SHA256 and compare it with the current file.
Do not overwrite current sources with old client-specific scripts or apply old
report-layout restore records to the shared engine. Git history remains available
for committed versions.

Builds and tests write only under `DeviceManagement/output/` and dedicated
fixture temporary directories. Remove generated output once its release or test
evidence is no longer needed. Preserve recovery archives and deployment snapshots.
Active tests use tracked fixtures and do not depend on local backup records or
previously generated HTML/function files.
