import hashlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK_PHASE = ROOT / 'scripts/check-phase-status.sh'
CHECK_ASSETS = ROOT / 'scripts/validate-release-assets.py'


class PhaseStatusTests(unittest.TestCase):
    def check(self, status, packaged, last):
        return subprocess.run(['bash', str(CHECK_PHASE), status, packaged, last, 'arm64'],
                              text=True, capture_output=True)

    def test_valid_outcomes(self):
        for args in [('running', 'false', 'false'), ('finished', 'true', 'false'),
                     ('finished', 'true', 'true')]:
            with self.subTest(args=args):
                self.assertEqual(self.check(*args).returncode, 0)

    def test_final_running_fails_with_context(self):
        result = self.check('running', 'false', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('arm64', result.stderr)
        self.assertIn('last allowed phase', result.stderr)

    def test_missing_or_inconsistent_status_fails(self):
        for args in [('', 'false', 'false'), ('finished', 'false', 'false'),
                     ('running', 'true', 'false'), ('error', 'false', 'false'),
                     ('finished', 'true', '')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.check(*args).returncode, 0)

    def test_workflow_is_bounded_and_uses_the_guard(self):
        workflow = (ROOT / '.github/workflows/build-arch.yml').read_text()
        phases = re.findall(r'^  phase_(\d+):\n(.*?)(?=\n  (?:phase_\d+:|#)|\Z)',
                            workflow, re.M | re.S)
        self.assertEqual([int(n) for n, _ in phases], list(range(1, 11)))
        for index, (_, body) in enumerate(phases):
            if index:
                previous = f'phase_{index:02}'
                self.assertIn(f'needs: {previous}', body)
                self.assertIn(f"needs.{previous}.outputs.status == 'running'", body)
                self.assertIn('resume: true', body)
            self.assertEqual('last_phase: true' in body, index == len(phases) - 1)
        phase = (ROOT / '.github/workflows/build-phase.yml').read_text()
        self.assertIn('status: ${{ steps.build.outputs.status }}', phase)
        self.assertIn('PACKAGED: ${{ steps.package.outputs.packaged }}', phase)
        self.assertIn('LAST_PHASE: ${{ inputs.last_phase }}', phase)
        self.assertLess(phase.index('name: Upload unfinished build'), phase.index('name: Validate phase outcome'))
        self.assertIn('scripts/check-phase-status.sh', phase)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        (self.workspace / 'build/src').mkdir(parents=True)
        (self.workspace / 'build/src/data').write_text('checkpoint data')
        (self.workspace / 'build.log').write_text('log')
        self.bin = self.workspace / 'bin'
        self.bin.mkdir()
        self.stub('gsync', 'exit 0')
        self.stub('xattr', 'exit 0')
        self.stub('zstd', 'cat > build_src.tar.zst')
        self.output = self.workspace / 'output'

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\n{body}\n')
        path.chmod(0o755)

    def package(self):
        env = os.environ.copy()
        env['PATH'] = f"{self.bin}:{env['PATH']}"
        env['GITHUB_OUTPUT'] = str(self.output)
        return subprocess.run(['bash', str(ROOT / 'scripts/package.sh'), 'arm64'],
                              cwd=self.workspace, env=env, text=True, capture_output=True)

    def test_unfinished_build_is_checkpointed_not_packaged(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('packaged=false', self.output.read_text())
        self.assertTrue((self.workspace / 'upload_part_build/build_src.tar.zst').is_file())
        self.assertTrue((self.workspace / 'upload_part_build/sums.txt').is_file())
        self.assertFalse((self.workspace / 'release_asset').exists())

    def test_finished_build_requires_nonempty_dmg(self):
        (self.workspace / 'build_finished_arm64.log').write_text('finished')
        packager = self.workspace / 'sign_and_package_app.sh'
        packager.write_text('#!/bin/sh\nprintf image > "$OUT_DMG_PATH"\n')
        packager.chmod(0o755)
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('packaged=true', self.output.read_text())
        self.assertTrue((self.workspace / 'release_asset/heliox-arm64.dmg.sha256').is_file())
        self.output.unlink()
        packager.write_text('#!/bin/sh\n: > "$OUT_DMG_PATH"\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('non-empty disk image', result.stderr)
        self.assertFalse(self.output.exists())


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dist = Path(self.temp.name) / 'dist'
        self.dist.mkdir()

    def add_arch(self, arch):
        name = f'heliox-{arch}.dmg'
        data = f'image for {arch}'.encode()
        (self.dist / name).write_bytes(data)
        (self.dist / f'{name}.sha256').write_text(f'{hashlib.sha256(data).hexdigest()}  {name}\n')

    def validate(self):
        return subprocess.run([sys.executable, str(CHECK_ASSETS), str(self.dist)],
                              text=True, capture_output=True)

    def test_empty_and_partial_dist_fail(self):
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('heliox-arm64.dmg', result.stderr)
        self.assertIn('heliox-x86_64.dmg.sha256', result.stderr)
        self.add_arch('arm64')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_two_valid_architectures_pass(self):
        self.add_arch('arm64')
        self.add_arch('x86_64')
        self.assertEqual(self.validate().returncode, 0)

    def test_extra_missing_empty_or_corrupt_fails(self):
        self.add_arch('arm64')
        self.add_arch('x86_64')
        extra = self.dist / 'other.dmg'
        extra.write_bytes(b'extra')
        self.assertNotEqual(self.validate().returncode, 0)
        extra.unlink()
        checksum = self.dist / 'heliox-arm64.dmg.sha256'
        original = checksum.read_text()
        checksum.unlink()
        self.assertNotEqual(self.validate().returncode, 0)
        checksum.write_text(original.replace('heliox-arm64', 'heliox-x86_64'))
        self.assertNotEqual(self.validate().returncode, 0)
        checksum.write_text(original)
        dmg = self.dist / 'heliox-arm64.dmg'
        dmg.write_bytes(b'wrong')
        self.assertNotEqual(self.validate().returncode, 0)
        dmg.write_bytes(b'')
        self.assertNotEqual(self.validate().returncode, 0)

    def test_release_invokes_validator_before_explicit_assets(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertLess(workflow.index('scripts/validate-release-assets.py dist'),
                        workflow.index('gh release create'))
        self.assertNotIn('dist/heliox-*.dmg', workflow)
        for arch in ('arm64', 'x86_64'):
            for suffix in ('.dmg', '.dmg.sha256'):
                self.assertIn(f'dist/heliox-{arch}{suffix}', workflow)


if __name__ == '__main__':
    unittest.main()
