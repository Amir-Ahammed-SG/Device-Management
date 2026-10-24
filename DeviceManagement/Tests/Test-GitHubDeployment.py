"""Exercise publication failure boundaries with fake SSH/SCP/HTTPS commands."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fake_command():
    root = Path(os.environ['DEPLOY_FIXTURE_ROOT'])
    command, *args = sys.argv[2:]
    mode = os.environ['DEPLOY_FIXTURE_MODE']
    current = root / 'current.ps1'
    stage = root / 'stage'
    with (root / 'events.txt').open('a', encoding='utf-8') as log:
        log.write(command + ' ' + (' '.join(args) if command == 'ssh' else '') + '\n')
    if command == 'sleep':
        return 0
    if command == 'scp':
        files = args[args.index('--') + 1:-1]
        for source in files:
            shutil.copyfile(source, stage / Path(source).name)
        return 0
    if command == 'curl':
        output = Path(args[args.index('--output') + 1])
        source = root / 'previous.ps1' if mode in ('public-mismatch', 'rollback-failure') else current
        shutil.copyfile(source, output)
        return 0
    if command != 'ssh':
        raise AssertionError(command)
    if mode == 'host-key-failure':
        return 255
    remote = args[-1]
    if remote.startswith('sha256sum -- '):
        print(sha(current) + '  /home/ito_kpi_admin/ito-cdn/files/script/DeviceManagement.ps1')
        return 0
    if remote.startswith('bash -s -- '):
        sys.stdin.read()
        stage.mkdir()
        return 0
    if 'sha256sum -c -' in remote:
        for line in sys.stdin.read().splitlines():
            checksum, filename = line.split('  ', 1)
            if sha(stage / filename) != checksum:
                return 1
        return 0
    fields = remote.split()
    if 'activate' in fields:
        position = fields.index('activate')
        _, previous, candidate = fields[position + 1:]
        if sha(current) != previous or sha(stage / 'Start-DeviceManagement.ps1') != candidate:
            return 4
        if mode == 'activation-before-write':
            return 9
        shutil.copyfile(current, stage / 'DeviceManagement.previous.ps1')
        shutil.copyfile(stage / 'Start-DeviceManagement.ps1', current)
        return 10 if mode == 'activation-after-write' else 0
    if 'rollback' in fields:
        if mode == 'rollback-failure':
            return 11
        position = fields.index('rollback')
        _, previous, candidate = fields[position + 1:]
        if sha(current) != candidate or sha(stage / 'DeviceManagement.previous.ps1') != previous:
            return 5
        shutil.copyfile(stage / 'DeviceManagement.previous.ps1', current)
        return 0
    raise AssertionError(remote)


def bash_path(path):
    value = str(path).replace('\\', '/')
    return '/' + value[0].lower() + value[2:] if os.name == 'nt' and value[1:2] == ':' else value


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='device-management-deploy-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.release = self.root / 'release'
        self.release.mkdir()
        self.binary = self.root / 'bin'
        self.binary.mkdir()
        self.candidate = self.release / 'Start-DeviceManagement.ps1'
        self.candidate.write_bytes(b"# fixture candidate\nWrite-Output 'new'\n")
        (self.root / 'current.ps1').write_bytes(b"# fixture previous\nWrite-Output 'old'\n")
        shutil.copyfile(self.root / 'current.ps1', self.root / 'previous.ps1')
        self.release_id = '20261024-actions-fixture-01'
        manifest = dict(ReleaseId=self.release_id, Delivery='InMemory', BootstrapSHA256=sha(self.candidate), Files=[{}] * 17)
        (self.release / 'release.json').write_text(json.dumps(manifest), encoding='utf-8')
        for name in ('ssh', 'scp', 'curl', 'sleep', 'python3'):
            script = '#!/usr/bin/env bash\n'
            if name == 'python3':
                script += 'exec "$DEPLOY_FIXTURE_PYTHON" "$@"\n'
            else:
                script += 'exec "$DEPLOY_FIXTURE_PYTHON" "$DEPLOY_FIXTURE_RUNNER" --fake "${0##*/}" "$@"\n'
            path = self.binary / name
            path.write_text(script, encoding='utf-8', newline='\n')
            path.chmod(0o700)
        self.env = os.environ.copy()
        self.env.update(DEPLOY_FIXTURE_ROOT=str(self.root), DEPLOY_FIXTURE_PYTHON=sys.executable,
                        DEPLOY_FIXTURE_RUNNER=str(Path(__file__).resolve()),
                        DEPLOY_FIXTURE_BIN=bash_path(self.binary),
                        CDN_SSH_HOST='fixture.example', CDN_SSH_USER='fixture', CDN_SSH_PORT='22',
                        CDN_SSH_KEY='fixture-key-only', CDN_SSH_KNOWN_HOSTS='fixture-host-key-only')
        for name in ('GITHUB_STEP_SUMMARY', 'GITHUB_SHA'):
            self.env.pop(name, None)

    def run_deploy(self, mode='success'):
        self.env['DEPLOY_FIXTURE_MODE'] = mode
        shell = shutil.which('bash')
        if os.name == 'nt':
            shell = r'C:\Program Files\Git\bin\bash.exe'
        self.assertTrue(shell, 'Bash is required')
        deploy = Path(__file__).resolve().parents[1] / 'Deployment' / 'Deploy-Cdn.sh'
        result = subprocess.run([shell, '-c', 'export PATH="$DEPLOY_FIXTURE_BIN:$PATH"; exec bash "$1" "$2" "$3"',
                                 'fixture', bash_path(deploy), bash_path(self.release), self.release_id],
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.events = (self.root / 'events.txt').read_text() if (self.root / 'events.txt').exists() else ''
        receipt = self.release / 'deployment-receipt.json'
        self.receipt = json.loads(receipt.read_text()) if receipt.exists() else {}
        return result

    def test_success(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt['status'], 'published')
        self.assertEqual(sha(self.root / 'current.ps1'), sha(self.candidate))
        self.assertEqual(sha(self.root / 'stage/DeviceManagement.previous.ps1'), sha(self.root / 'previous.ps1'))
        self.assertNotIn(' rollback ', self.events)

    def test_public_failure_restores_previous(self):
        result = self.run_deploy('public-mismatch')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt['status'], 'failed-rolled-back', result.stderr)
        self.assertEqual(sha(self.root / 'current.ps1'), sha(self.root / 'previous.ps1'))

    def test_failed_activation_before_write_keeps_previous(self):
        self.assertNotEqual(self.run_deploy('activation-before-write').returncode, 0)
        self.assertNotIn(' rollback ', self.events)
        self.assertEqual(sha(self.root / 'current.ps1'), sha(self.root / 'previous.ps1'))

    def test_failed_activation_after_write_rolls_back(self):
        result = self.run_deploy('activation-after-write')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt['status'], 'failed-rolled-back', result.stderr)

    def test_rollback_failure_is_unverified(self):
        result = self.run_deploy('rollback-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt['status'], 'failed-rollback-unverified', result.stderr)

    def test_bad_artifact_never_connects(self):
        self.candidate.write_bytes(b'corrupted')
        self.assertNotEqual(self.run_deploy().returncode, 0)
        self.assertNotIn('ssh ', self.events)

    def test_missing_key_never_connects(self):
        self.env.pop('CDN_SSH_KEY')
        self.assertNotEqual(self.run_deploy().returncode, 0)
        self.assertNotIn('ssh ', self.events)

    def test_host_key_failure_never_activates(self):
        self.assertNotEqual(self.run_deploy('host-key-failure').returncode, 0)
        self.assertNotIn(' activate ', self.events)
        self.assertEqual(sha(self.root / 'current.ps1'), sha(self.root / 'previous.ps1'))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fake':
        raise SystemExit(fake_command())
    unittest.main()
