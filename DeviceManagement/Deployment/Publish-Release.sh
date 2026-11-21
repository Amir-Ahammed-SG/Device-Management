#!/usr/bin/env bash
# Publish one self-contained in-memory entry; no project archive is required.
set -euo pipefail
umask 077
action=${1:?activate or rollback}
release_id=${2:?release ID}
old_hash=${3:?current entry SHA256 or absent}
entry_hash=${4:?new entry SHA256}
[[ "$release_id" =~ ^[0-9]{8}-[A-Za-z0-9-]+$ ]]
[[ "$old_hash" = absent || "$old_hash" =~ ^[a-f0-9]{64}$ ]]
[[ "$entry_hash" =~ ^[a-f0-9]{64}$ ]]
test "$(id -u)" = 0
stage="/home/ito_kpi_admin/ito-cdn/.deployments/$release_id"
webroot=/home/ito_kpi_admin/ito-cdn/files/script
target="$webroot/DeviceManagement.ps1"
backup="$stage/DeviceManagement.previous.ps1"
hash_of() { sha256sum -- "$1" | cut -d ' ' -f 1; }
check_current() {
    if test "$1" = absent; then
        test ! -e "$target" && test ! -L "$target"
    else
        test -f "$target" && test ! -L "$target"
        test "$(readlink -f -- "$target")" = "$target"
        test "$(hash_of "$target")" = "$1"
    fi
}
test -d "$stage" && test ! -L "$stage"
test "$(readlink -f -- "$stage")" = "$stage"
test "$(readlink -f -- "$webroot")" = "$webroot"
case "$action" in
activate)
    candidate="$stage/Start-DeviceManagement.ps1"
    expected_current="$old_hash"
    expected_replacement="$entry_hash"
    test -f "$candidate" && test ! -L "$candidate"
    test "$(hash_of "$candidate")" = "$entry_hash"
    check_current "$old_hash"
    test ! -e "$backup" && test ! -L "$backup"
    if test "$old_hash" != absent; then
        cp --preserve=all -- "$target" "$backup"
        chmod 600 -- "$backup"
        test "$(hash_of "$backup")" = "$old_hash"
    fi
    ;;
rollback)
    check_current "$entry_hash"
    if test "$old_hash" = absent; then
        rm -- "$target"
        printf 'REMOVED_NEW_ENDPOINT %s\n' "$target"
        exit 0
    fi
    candidate="$backup"
    expected_current="$entry_hash"
    expected_replacement="$old_hash"
    test -f "$candidate" && test ! -L "$candidate"
    test "$(hash_of "$candidate")" = "$old_hash"
    ;;
*) printf 'Unknown action\n' >&2; exit 2 ;;
esac
temporary=$(mktemp "$webroot/.DeviceManagement.publish.XXXXXXXX")
cleanup() { test -z "${temporary:-}" || rm -f -- "$temporary"; }
trap cleanup EXIT
cat -- "$candidate" > "$temporary"
if test "$expected_current" = absent; then
    chown root:root -- "$temporary"
    chmod 644 -- "$temporary"
else
    chown --reference="$target" -- "$temporary"
    chmod --reference="$target" -- "$temporary"
fi
test "$(hash_of "$temporary")" = "$expected_replacement"
check_current "$expected_current"
mv -fT -- "$temporary" "$target"
temporary=
test "$(hash_of "$target")" = "$expected_replacement"
printf '%s %s\nSHA256 %s\n' "$action" "$target" "$expected_replacement"
if test "$old_hash" != absent; then printf 'ROLLBACK_COPY %s\n' "$backup"; fi
