#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'build' / 'verify'
CHROMIUM = 'https://github.com/chromium/chromium.git'
HELIUM_MACOS = 'https://github.com/imputnet/helium-macos.git'


def run(*command, cwd=None, check=True, quiet=False):
    return subprocess.run(command,
                          cwd=cwd,
                          check=check,
                          stdout=subprocess.PIPE if quiet else None,
                          stderr=subprocess.STDOUT if quiet else None,
                          text=True)


def read_series(directory):
    series = []
    for line in (directory / 'series').read_text(encoding='utf-8').splitlines():
        line = line.split('#')[0].strip()
        if line:
            series.append(directory / line)
    return series


def touched_files(patches):
    modified = set()
    created = set()
    for patch in patches:
        previous = None
        for line in patch.read_text(encoding='utf-8', errors='replace').splitlines():
            if line.startswith('--- '):
                previous = line[4:].split('\t')[0].strip()
            elif line.startswith('+++ ') and previous is not None:
                current = line[4:].split('\t')[0].strip()
                if previous == '/dev/null':
                    created.add(current.split('/', 1)[1])
                else:
                    modified.add(previous.split('/', 1)[1])
                previous = None
    return sorted(modified - created)


def checkout_helium(version):
    target = WORK / 'helium-macos'
    if not target.exists():
        run('git', 'clone', '--quiet', '--branch', version, '--depth', '1', '--recurse-submodules',
            '--shallow-submodules', HELIUM_MACOS, str(target))
    run('git', 'checkout', '--quiet', '--', 'patches/series', cwd=target)
    run('git', 'checkout', '--quiet', '--', 'i18n', cwd=target / 'helium-chromium')
    run(sys.executable, str(ROOT / 'scripts' / 'overlay.py'), str(target))
    return target


def checkout_chromium(version, files):
    mirror = WORK / 'chromium'
    if not mirror.exists():
        run('git', 'clone', '--quiet', '--filter=blob:none', '--no-checkout', '--depth', '1', '--branch',
            version, CHROMIUM, str(mirror))
    listing = run('git', 'ls-tree', '-r', '--name-only', 'HEAD', cwd=mirror, quiet=True).stdout
    available = set(listing.splitlines())
    wanted = [path for path in files if path in available]
    run('git', 'sparse-checkout', 'init', '--no-cone', cwd=mirror, quiet=True)
    (mirror / '.git' / 'info' / 'sparse-checkout').write_text(
        ''.join(f'/{path}\n' for path in wanted), encoding='utf-8')
    run('git', 'checkout', '--quiet', '--force', 'HEAD', cwd=mirror)
    run('git', 'clean', '-fdq', cwd=mirror)
    return mirror


def apply(tree, patch):
    return run('patch', '-p1', '--ignore-whitespace', '--no-backup-if-mismatch', '--forward', '-f', '-i',
               str(patch), cwd=tree, check=False, quiet=True)


def main():
    version = (ROOT / 'helium-version.txt').read_text(encoding='utf-8').strip()
    WORK.mkdir(parents=True, exist_ok=True)

    helium = checkout_helium(version)
    base = read_series(helium / 'helium-chromium' / 'patches')
    platform = read_series(helium / 'patches')
    patches = base + platform
    heliox = [patch for patch in platform if patch.parent.name == 'heliox']
    if not heliox:
        print('no Heliox patches found in series', file=sys.stderr)
        return 1

    chromium_version = (helium / 'helium-chromium' / 'chromium_version.txt').read_text(encoding='utf-8').strip()
    tree = checkout_chromium(chromium_version, touched_files(patches))

    failed = False
    for patch in patches:
        result = apply(tree, patch)
        if patch in heliox:
            status = 'ok' if result.returncode == 0 else 'FAILED'
            print(f'{status}  {patch.parent.name}/{patch.name}')
            if result.returncode != 0:
                print(result.stdout)
                failed = True

    rejects = [path for path in tree.rglob('*.rej') if '.git' not in path.parts]
    if rejects:
        print(f'{len(rejects)} rejected hunks in upstream patches', file=sys.stderr)
        failed = True

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
