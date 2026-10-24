# GitHub Actions deployment

Repository: https://github.com/Amir-Ahammed/Device-Management-Script
Branch: `main`
Public entry: https://cdn-ito.selisesme.com/script/DeviceManagement.ps1

Configured and verified on 24 Oct 2026 using a dedicated deployment key and the
server's already-trusted SSH host keys. Automatic deployment is enabled.
The [first publication](https://github.com/Amir-Ahammed/Device-Management-Script/actions/runs/40073441632)
passed both fixture jobs, atomic activation and public checksum verification.

## One-time setup

In repository Settings, open **Secrets and variables > Actions**. Create:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `CDN_SSH_HOST` | `4.145.113.185` |
| Variable | `CDN_SSH_USER` | `ito_kpi_admin` |
| Variable | `CDN_SSH_PORT` | `22` |
| Secret | `CDN_SSH_KEY` | Private SSH key authorized for this deployment account |
| Secret | `CDN_SSH_KNOWN_HOSTS` | Verified OpenSSH known_hosts entry for the server |
| Variable | `CDN_DEPLOY_ENABLED` | Set to `true` after access and the workflow are configured |

Use a separate key for this repository. Never commit the key, private customer
reports, local credentials, or an `.env` file. Check the host key against the
existing trusted connection; the workflow deliberately rejects unknown hosts.
The account currently uses the existing sudo publisher access. The private key
therefore grants administrative deployment access and belongs only in Actions
secrets for trusted maintainers. Do not expose deployment secrets to pull requests.

The existing server directories must exist and be real directories:

```text
/home/ito_kpi_admin/ito-cdn/.deployments
/home/ito_kpi_admin/ito-cdn/files/script
```

The account needs private-stage write access and noninteractive sudo permission
to execute the reviewed publisher. The workflow changes only the canonical
script entry and its private release stage. It does not restart containers.
Keep the current SSH access and previous deployment records for recovery.

## Daily use

Edit the source files in this repository and push a branch. Open a pull request
to `main` and check the Windows build result. Merge or push to `main` to publish.
The first push can build safely while `CDN_DEPLOY_ENABLED` is absent or false.
After enabling it, use **Actions > Device Management > Run workflow > main**
to deploy the current commit without making an empty commit.

Only `main` deploys, including manual runs. Pull requests never receive SSH
secrets. Deploy jobs run serially and do not cancel an active publication.
Actions are pinned to reviewed commit SHAs. Checkout credentials are not retained.

`Test-GitHubRelease.ps1` runs ten independent setup/client/report fixtures and the
existing 54-case Thorough Check delivery suite plus both clients' installation completion/menu cases. Account, installer and launcher writes
use fixtures. A separate Linux job verifies eight publication and rollback
scenarios using fake SSH, SCP and HTTPS commands. The full older Pester suite is not a passing deployment gate:
the current recorded baseline is 88 passed and 36 existing failures. Those
failures need separate maintenance; a fixture pass is not a controlled device run.

One account-renderer test reads a small checked-in historical renderer fixture,
comparing all output outside the approved agent footer markup/styles, instead
of a workstation's private backup. Agent fixtures cover mandatory input order,
escaped attribution and saved Audit reuse. Generated HTML, browser
screenshots and local backup directories are not required for the CI gate.
Other legacy tests may still require their documented local preview artifacts.

## Verification and rollback

The deployment job validates the downloaded manifest and bundle bytes before
connecting. It creates a new private stage, verifies all three uploaded file
hashes, and activates the existing `Publish-Release.sh` under a server lock.
The publisher saves the previous script privately and atomically replaces the
entry after checking its old and new hashes. The runner checks both the server
file and public HTTPS response against the new hash.

If activation or public verification fails after replacement, the runner attempts
guarded rollback and verifies the restored server/public hashes. A failed or
unverified rollback remains a failed Actions run and requires inspection.
Network loss or forced termination can prevent automatic recovery. Retain the
deployment receipt and server stage; do not force overwrite a changed endpoint.

For manual rollback, use the exact release ID and hashes from the receipt:

```bash
sudo -n bash /home/ito_kpi_admin/ito-cdn/.deployments/RELEASE_ID/Publish-Release.sh rollback RELEASE_ID PREVIOUS_SHA256 CANDIDATE_SHA256
```

This succeeds only while the current endpoint still matches that candidate.
Verify the restored public checksum afterwards. Historical URL endpoints such
as `/kiosk/Start-DeviceManagement.ps1` are not changed by this workflow.

## Local verification

From the repository root, in 64-bit Windows PowerShell 5.1:

```powershell
.\DeviceManagement\Deployment\Test-GitHubRelease.ps1 -ReleaseId 20261024-local-check-01
```

Use a new release ID for every build. To stop future automatic deployments,
set `CDN_DEPLOY_ENABLED` to `false`; this does not cancel a deployment already
in progress.

References: [GitHub workflow deployment controls](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments),
[Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).
