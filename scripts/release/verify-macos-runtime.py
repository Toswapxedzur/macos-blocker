#!/usr/bin/env python3
"""Check real Mach-O deployment targets, architecture and packaged dependencies."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

CONFIG = {'minimumOS': '13.3'}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def inspect(path, architecture, minimum):
    architectures = output('lipo', '-archs', str(path)).split()
    if architectures != [architecture]:
        raise ValueError(f'{path.name}: expected {architecture}, found {architectures}')
    commands = output('otool', '-l', str(path))
    targets = re.findall(r'\bminos\s+(\d+(?:\.\d+)+)', commands)
    targets += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)+)', commands)
    if not targets or any(version(target) > version(minimum) for target in targets):
        raise ValueError(f'{path.name}: unsupported minimum OS {targets}, target {minimum}')
    return targets


def verify_app(app, architecture):
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if info.get('LSMinimumSystemVersion') != CONFIG['minimumOS']:
        raise ValueError('App minimum OS must match the runtime target')
    frameworks = contents / 'Frameworks'
    binaries = [path for path in (contents / 'MacOS').iterdir() if path.is_file()]
    binaries += [path for path in frameworks.glob('*') if path.suffix in ('.so', '.dylib')]
    if not binaries:
        raise ValueError('App has no executable')
    if any(name in path.name.lower() for path in binaries for name in ('llama', 'ggml', 'libomp')):
        raise ValueError('App contains a retired local inference runtime')
    for path in binaries:
        inspect(path, architecture, CONFIG['minimumOS'])
        for line in output('otool', '-L', str(path)).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/') and (frameworks / dependency[7:]).is_file():
                continue
            raise ValueError(f'{path.name}: unresolved or external dependency {dependency}')
    print(f'PASS {len(binaries)} Mach-O files: {architecture}, macOS {CONFIG["minimumOS"]}, self-contained dependencies')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--architecture', required=True, choices=['arm64', 'x86_64'])
    args = parser.parse_args()
    verify_app(args.app, args.architecture)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
