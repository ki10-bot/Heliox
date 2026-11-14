#!/usr/bin/env python3
import argparse
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_series(path):
    return [line.strip() for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def overlay_patches(target):
    patches = target / 'patches'
    destination = patches / 'heliox'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(ROOT / 'patches' / 'heliox', destination)

    series_path = patches / 'series'
    series = series_path.read_text(encoding='utf-8')
    existing = set(read_series(series_path))
    additions = [entry for entry in read_series(ROOT / 'patches' / 'series') if entry not in existing]
    if additions:
        if not series.endswith('\n'):
            series += '\n'
        series += '\n' + '\n'.join(additions) + '\n'
        series_path.write_text(series, encoding='utf-8')
    return len(additions)


def merge_entries(path, entries, key):
    current = json.loads(path.read_text(encoding='utf-8')) if path.exists() else []
    index = {key(entry): position for position, entry in enumerate(current) if entry}
    for entry in entries:
        position = index.get(key(entry))
        if position is None:
            index[key(entry)] = len(current)
            current.append(entry)
        else:
            current[position] = entry
    path.write_text(json.dumps(current, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def overlay_translations(target):
    i18n = target / 'helium-chromium' / 'i18n'
    source = json.loads((ROOT / 'i18n' / 'source.json').read_text(encoding='utf-8'))
    merge_entries(i18n / 'source.gen.json', source, lambda entry: (entry['name'], entry['message']))

    languages = 0
    for path in sorted((ROOT / 'i18n' / 'translations').glob('*.json')):
        translations = json.loads(path.read_text(encoding='utf-8'))
        merge_entries(i18n / 'translations' / path.name, translations,
                      lambda entry: (entry['name'], entry['source']))
        languages += 1
    return languages


def main():
    parser = argparse.ArgumentParser(description='Add Heliox to a helium-macos checkout')
    parser.add_argument('target', type=Path)
    args = parser.parse_args()

    target = args.target.resolve()
    if not (target / 'patches' / 'series').is_file() or not (target / 'helium-chromium' / 'i18n').is_dir():
        print(f'{target} is not a helium-macos checkout with submodules', file=sys.stderr)
        return 1

    patches = overlay_patches(target)
    languages = overlay_translations(target)
    print(f'heliox: {patches} patches added, {languages} languages merged')
    return 0


if __name__ == '__main__':
    sys.exit(main())
