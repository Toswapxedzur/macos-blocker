#!/usr/bin/env python3
"""Check real Mach-O deployment targets, architecture and packaged dependencies."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

CONFIG = json.loads(pathlib.Path(__file__).with_name('runtime-sources.json').read_text())


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


def verify_prefix(prefix, architecture):
    receipt = json.loads((prefix / 'vault-runtime.json').read_text())
    for key, expected in [('schema', 1), ('architecture', architecture), ('minimumOS', CONFIG['minimumOS']),
                          ('llamaRevision', CONFIG['llamaRevision']), ('openmpVersion', CONFIG['openmpVersion'])]:
        if receipt.get(key) != expected:
            raise ValueError(f'Runtime receipt mismatch: {key}')
    if receipt.get('archives') != CONFIG['archives']:
        raise ValueError('Runtime source archives do not match the pinned sources')
    files = receipt.get('files', {})
    required = ['include/llama.h', 'include/ggml.h', 'lib/libllama.0.dylib', 'lib/libggml.0.dylib',
                'lib/libggml-base.0.dylib', 'lib/libomp.dylib', 'lib/libggml-blas.so']
    if architecture == 'arm64':
        required.append('lib/libggml-metal.so')
    if not any(name.startswith('lib/libggml-cpu') and name.endswith('.so') for name in files):
        raise ValueError('Runtime has no CPU backend')
    if any(name not in files for name in required):
        raise ValueError('Runtime receipt omits a required library or header')
    for name, expected in files.items():
        path = prefix / name
        if not path.resolve().is_relative_to(prefix.resolve()):
            raise ValueError('Runtime receipt contains a path outside its prefix')
        if digest(path) != expected:
            raise ValueError(f'Runtime hash mismatch: {name}')
        if path.suffix in ('.dylib', '.so'):
            inspect(path, architecture, CONFIG['minimumOS'])
    return receipt


def verify_app(app, architecture):
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if info.get('LSMinimumSystemVersion') != CONFIG['minimumOS']:
        raise ValueError('App minimum OS must match the runtime target')
    frameworks = contents / 'Frameworks'
    binaries = [path for path in (contents / 'MacOS').iterdir() if path.is_file()]
    binaries += [path for path in frameworks.iterdir() if path.suffix in ('.so', '.dylib')]
    if not binaries or not (frameworks / 'libllama.0.dylib').is_file():
        raise ValueError('App is missing its native engine')
    for path in binaries:
        inspect(path, architecture, CONFIG['minimumOS'])
        for line in output('otool', '-L', str(path)).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/') and (frameworks / dependency[7:]).is_file():
                continue
            raise ValueError(f'{path.name}: unresolved or external dependency {dependency}')
    for notice in ['llama-LICENSE.txt', 'ggml-LICENSE.txt', 'OpenMP-LICENSE.txt', 'build-receipt.json']:
        if not (contents / 'Resources/ThirdPartyNotices' / notice).is_file():
            raise ValueError(f'Missing runtime notice: {notice}')
    print(f'PASS {len(binaries)} Mach-O files: {architecture}, macOS {CONFIG["minimumOS"]}, self-contained dependencies')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prefix', type=pathlib.Path)
    group.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--architecture', required=True, choices=['arm64', 'x86_64'])
    args = parser.parse_args()
    if args.prefix:
        verify_prefix(args.prefix, args.architecture)
    else:
        verify_app(args.app, args.architecture)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
