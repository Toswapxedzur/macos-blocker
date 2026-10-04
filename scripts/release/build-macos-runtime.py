#!/usr/bin/env python3
"""Build a pinned llama/ggml/OpenMP runtime for macOS 13.3, outside Homebrew."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
CONFIG = json.loads((HERE / 'runtime-sources.json').read_text())
spec = importlib.util.spec_from_file_location('runtime_verifier', HERE / 'verify-macos-runtime.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def source(name, work):
    item = CONFIG['archives'][name]
    archive = work / (name + '.archive')
    if not archive.is_file():
        partial = archive.with_suffix('.download')
        urllib.request.urlretrieve(item['url'], partial)
        if verifier.digest(partial) != item['sha256']:
            raise ValueError(f'{name}: downloaded source checksum mismatch')
        partial.rename(archive)
    if verifier.digest(archive) != item['sha256']:
        raise ValueError(f'{name}: cached source checksum mismatch')
    destination = work / name
    with tarfile.open(archive) as package:
        members = package.getmembers()
        roots = {member.name.split('/')[0] for member in members}
        if len(roots) != 1 or any(member.name.startswith('/') or '..' in pathlib.PurePosixPath(member.name).parts for member in members):
            raise ValueError('Invalid source archive layout')
        if destination.is_dir():
            for member in members:
                path = destination.joinpath(*pathlib.PurePosixPath(member.name).parts[1:])
                if member.isfile():
                    expected = hashlib.sha256(package.extractfile(member).read()).hexdigest()
                    if verifier.digest(path) != expected:
                        raise ValueError(f'{name}: extracted source differs from pinned archive: {path.name}')
                elif member.issym() and (not path.is_symlink() or os.readlink(path) != member.linkname):
                    raise ValueError(f'{name}: extracted source symlink changed')
            return destination
        package.extractall(work)
        (work / roots.pop()).rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=['arm64', 'x86_64'], required=True)
    parser.add_argument('--work', type=pathlib.Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    work = args.work.resolve()
    prefix = work / 'install'
    if (prefix / 'vault-runtime.json').is_file():
        verifier.verify_prefix(prefix, args.architecture)
        print(prefix)
        return
    work.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(work).free < 2 * 1024**3:
        raise ValueError('Runtime build needs at least 2 GiB free staging space')
    llama = source('llama', work)
    openmp = source('openmp', work)
    source('cmake', work)
    common = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
              f'-DCMAKE_OSX_ARCHITECTURES={args.architecture}', '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3',
              '-DCMAKE_INSTALL_RPATH=@loader_path']
    run('cmake', '-S', openmp, '-B', work / 'openmp-build', *common,
        '-DOPENMP_ENABLE_LIBOMPTARGET=OFF', '-DOPENMP_ENABLE_OMPT_TOOLS=OFF', '-DLIBOMP_INSTALL_ALIASES=OFF')
    run('cmake', '--build', work / 'openmp-build', '--parallel', args.jobs)
    run('cmake', '--install', work / 'openmp-build')
    run('cmake', '-S', llama, '-B', work / 'llama-build', *common,
        '-DBUILD_SHARED_LIBS=ON', '-DLLAMA_USE_SYSTEM_GGML=OFF', '-DLLAMA_BUILD_COMMON=OFF',
        '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_TOOLS=OFF',
        '-DLLAMA_CURL=OFF', '-DLLAMA_OPENSSL=OFF', '-DGGML_NATIVE=OFF', '-DGGML_BACKEND_DL=ON',
        f'-DGGML_BACKEND_DIR={prefix / "lib"}', '-DGGML_BLAS=ON', '-DGGML_BLAS_VENDOR=Apple',
        '-DGGML_CPU_ALL_VARIANTS=OFF', '-DGGML_OPENMP=ON', '-DGGML_CCACHE=OFF',
        '-DGGML_METAL=' + ('ON' if args.architecture == 'arm64' else 'OFF'),
        '-DGGML_METAL_EMBED_LIBRARY=ON', '-DGGML_METAL_MACOSX_VERSION_MIN=13.3',
        '-DOpenMP_C_FLAGS=-Xpreprocessor -fopenmp', '-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp',
        '-DOpenMP_C_LIB_NAMES=omp', '-DOpenMP_CXX_LIB_NAMES=omp',
        f'-DOpenMP_omp_LIBRARY={prefix / "lib/libomp.dylib"}',
        f'-DOpenMP_C_INCLUDE_DIR={prefix / "include"}', f'-DOpenMP_CXX_INCLUDE_DIR={prefix / "include"}')
    run('cmake', '--build', work / 'llama-build', '--parallel', args.jobs)
    run('cmake', '--install', work / 'llama-build')
    notices = prefix / 'share/vault-notices'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(llama / 'LICENSE', notices / 'llama-LICENSE.txt')
    shutil.copy2(llama / 'ggml/LICENSE', notices / 'ggml-LICENSE.txt')
    shutil.copy2(openmp / 'LICENSE.TXT', notices / 'OpenMP-LICENSE.txt')
    (notices / 'sources.json').write_text(json.dumps(CONFIG, indent=2) + '\n')
    files = {str(path.relative_to(prefix)): verifier.digest(path) for path in sorted(prefix.rglob('*')) if path.is_file()}
    receipt = dict(CONFIG, schema=1, architecture=args.architecture, files=files,
                   compiler=verifier.output('xcrun', 'clang', '--version'),
                   sdk=verifier.output('xcrun', '--sdk', 'macosx', '--show-sdk-version'))
    (prefix / 'vault-runtime.json').write_text(json.dumps(receipt, indent=2) + '\n')
    verifier.verify_prefix(prefix, args.architecture)
    print(prefix)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
