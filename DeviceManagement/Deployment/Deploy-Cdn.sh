#!/usr/bin/env bash
# Run on the Linux deployment runner; only publish the canonical script endpoint.
set -Eeuo pipefail
umask 077

release_directory=${1:?release directory}
release_id=${2:?release ID}
[[ "$release_id" =~ ^[0-9]{8}-[A-Za-z0-9-]+$ ]] || exit 2
release_directory=$(cd -- "$release_directory" && pwd -P)
publisher=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/Publish-Release.sh
target=/home/ito_kpi_admin/ito-cdn/files/script/DeviceManagement.ps1
stage=/home/ito_kpi_admin/ito-cdn/.deployments/$release_id
public_url=https://cdn-ito.selisesme.com/script/DeviceManagement.ps1
activation_attempted=0
old_hash=
entry_hash=
temporary=

receipt() {
    python3 - "$release_directory/deployment-receipt.json" "$1" "$release_id" "$old_hash" "$entry_hash" "${GITHUB_SHA:-local-review}" <<'PY'
import datetime, json, pathlib, sys
path, status, release_id, previous, current, commit = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps(dict(status=status, release_id=release_id,
    previous_sha256=previous, candidate_sha256=current, commit=commit,
    recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat()), indent=2) + '\n', encoding='utf-8')
PY
}
cleanup() {
    if [[ -n "$temporary" ]]; then rm -f -- "$temporary/key" "$temporary/known_hosts" "$temporary/public.ps1"; rmdir -- "$temporary"; fi
}
trap cleanup EXIT

# Validate bytes and manifest before creating a connection or reading a secret.
entry_hash=$(python3 - "$release_directory" "$release_id" <<'PY'
import hashlib, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'release.json').read_text(encoding='utf-8'))
data = (root / 'Start-DeviceManagement.ps1').read_bytes()
assert 0 < len(data) <= 10 * 1024 * 1024, 'Unexpected release size'
assert not data.startswith(b'\xef\xbb\xbf'), 'BOM is not supported'
data.decode('utf-8', errors='strict')
expected = manifest['BootstrapSHA256']
assert re.fullmatch('[a-f0-9]{64}', expected), 'Invalid SHA256'
assert manifest['ReleaseId'] == sys.argv[2] and manifest['Delivery'] == 'InMemory', 'Release identity mismatch'
assert len(manifest['Files']) == 19, 'Unexpected runtime resource inventory'
assert hashlib.sha256(data).hexdigest() == expected, 'Candidate checksum mismatch'
print(expected)
PY
)
bash -n "$publisher"
publisher_hash=$(sha256sum -- "$publisher" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum -- "$release_directory/release.json" | cut -d ' ' -f 1)
: "${CDN_SSH_HOST:?Set the CDN_SSH_HOST repository variable}"
: "${CDN_SSH_USER:?Set the CDN_SSH_USER repository variable}"
: "${CDN_SSH_KEY:?Set the CDN_SSH_KEY Actions secret}"
: "${CDN_SSH_KNOWN_HOSTS:?Set the verified CDN_SSH_KNOWN_HOSTS Actions secret}"
port=${CDN_SSH_PORT:-22}
[[ "$CDN_SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]
[[ "$CDN_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
[[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
temporary=$(mktemp -d)
printf '%s\n' "$CDN_SSH_KEY" > "$temporary/key"
printf '%s\n' "$CDN_SSH_KNOWN_HOSTS" > "$temporary/known_hosts"
unset CDN_SSH_KEY CDN_SSH_KNOWN_HOSTS
chmod 600 "$temporary/key" "$temporary/known_hosts"
connection=(-i "$temporary/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$temporary/known_hosts" -o ConnectTimeout=15)
ssh_command=(ssh "${connection[@]}" -p "$port")
destination=$CDN_SSH_USER@$CDN_SSH_HOST
remote_status() {
    local value
    value=$("${ssh_command[@]}" "$destination" "sha256sum -- $target") || return 1
    value=${value%% *}
    [[ "$value" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$value"
}
publish() {
    # Both hashes and the release ID have already passed strict validation.
    "${ssh_command[@]}" "$destination" "flock -w 120 /home/ito_kpi_admin/ito-cdn/.deployments/device-management.lock sudo -n bash $stage/Publish-Release.sh $1 $release_id $old_hash $entry_hash"
}
verify_public() {
    local expected=$1 attempt
    for attempt in 1 2 3 4 5; do
        if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \
            --output "$temporary/public.ps1" "$public_url?release=$release_id&verify=$attempt"; then
            if [[ "$(sha256sum -- "$temporary/public.ps1" | cut -d ' ' -f 1)" == "$expected" ]]; then return 0; fi
        fi
        if (( attempt < 5 )); then sleep 2; fi
    done
    return 1
}
failure() {
    local exit_code=$? current= rollback_status=failed
    trap - ERR
    set +e
    if (( activation_attempted )); then
        current=$(remote_status)
        if [[ "$current" == "$entry_hash" ]]; then
            printf 'Verification failed; attempting checksum-guarded rollback.\n' >&2
            if publish rollback && [[ "$(remote_status)" == "$old_hash" ]] && verify_public "$old_hash"; then
                rollback_status=failed-rolled-back
            else
                rollback_status=failed-rollback-unverified
                printf 'Rollback could not be verified; inspect this release stage on the server.\n' >&2
            fi
        elif [[ "$current" != "$old_hash" ]]; then
            rollback_status=failed-current-state-unverified
            printf 'Endpoint state is unverified; guarded rollback was not forced.\n' >&2
        fi
    fi
    receipt "$rollback_status"
    exit "$exit_code"
}
trap failure ERR

old_hash=$(remote_status)
if [[ "$old_hash" == "$entry_hash" ]]; then
    verify_public "$entry_hash"
    receipt already-current
    printf 'Public endpoint already matches the verified release.\n'
    exit 0
fi
receipt staging
"${ssh_command[@]}" "$destination" "bash -s -- $release_id" <<'REMOTE'
set -euo pipefail
umask 077
release_id=$1
[[ "$release_id" =~ ^[0-9]{8}-[A-Za-z0-9-]+$ ]]
root=/home/ito_kpi_admin/ito-cdn
for directory in "$root" "$root/.deployments" "$root/files/script"; do
    test -d "$directory" && test ! -L "$directory"
    test "$(readlink -f -- "$directory")" = "$directory"
done
# Refuse to overwrite an earlier stage, including its rollback copy.
mkdir -m 700 -- "$root/.deployments/$release_id"
REMOTE
scp "${connection[@]}" -P "$port" -- "$release_directory/Start-DeviceManagement.ps1" "$release_directory/release.json" "$publisher" "$destination:$stage/"
"${ssh_command[@]}" "$destination" "cd $stage && sha256sum -c - && bash -n Publish-Release.sh" <<CHECKSUMS
$entry_hash  Start-DeviceManagement.ps1
$manifest_hash  release.json
$publisher_hash  Publish-Release.sh
CHECKSUMS
activation_attempted=1
publish activate
[[ "$(remote_status)" == "$entry_hash" ]]
verify_public "$entry_hash"
receipt published
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Published release `%s` to [DeviceManagement.ps1](%s).\n\nSHA256: `%s`\n' "$release_id" "$public_url" "$entry_hash" >> "$GITHUB_STEP_SUMMARY"
fi
printf 'Published %s\nSHA256 %s\n' "$release_id" "$entry_hash"
