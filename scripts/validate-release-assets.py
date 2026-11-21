#!/usr/bin/env python3
"""Fail closed before creating a release from downloaded build artifacts."""
import hashlib
import re
import sys
from pathlib import Path

ARCHES = ('arm64', 'x86_64')


def validate(directory):
    expected_dmgs = {f'heliox-{arch}.dmg' for arch in ARCHES}
    expected_hashes = {f'{name}.sha256' for name in expected_dmgs}
    errors = []
    for pattern, expected in (('*.dmg', expected_dmgs), ('*.dmg.sha256', expected_hashes)):
        actual = {path.name for path in directory.glob(pattern)}
        for name in sorted(expected - actual):
            errors.append(f'missing {directory / name}')
        for name in sorted(actual - expected):
            errors.append(f'unexpected release file {directory / name}')

    for name in sorted(expected_dmgs):
        dmg, checksum = directory / name, directory / f'{name}.sha256'
        if not dmg.is_file() or not checksum.is_file():
            continue
        if dmg.stat().st_size == 0:
            errors.append(f'empty disk image {dmg}')
            continue
        try:
            content = checksum.read_text(encoding='utf-8').strip()
            match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)', content)
            if not match or match.group(2) != name:
                errors.append(f'invalid checksum file {checksum}: expected SHA-256 and filename {name}')
                continue
            digest = hashlib.sha256()
            with dmg.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            if digest.hexdigest() != match.group(1).lower():
                errors.append(f'SHA-256 mismatch for {dmg}')
        except (OSError, UnicodeError) as exc:
            errors.append(f'cannot verify {dmg}: {exc}')
    # A directory named like an expected file must not pass the presence check.
    for name in sorted(expected_dmgs | expected_hashes):
        path = directory / name
        if (path.exists() or path.is_symlink()) and not path.is_file():
            errors.append(f'not a regular file: {path}')
    return errors


def main():
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} DIST_DIRECTORY', file=sys.stderr)
        return 2
    errors = validate(Path(sys.argv[1]))
    if errors:
        for error in errors:
            print(f'::error::Release asset validation: {error}', file=sys.stderr)
        print('::error::Expected one DMG and its matching .sha256 for each of arm64 and x86_64; refusing to publish.', file=sys.stderr)
        return 1
    print('Validated both architecture DMGs and SHA-256 checksums.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
