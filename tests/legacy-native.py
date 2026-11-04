#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native npm 6 proof; takes the built checks.<system>.legacy-node-tools path."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from registry_fixture import registry

tools = Path(sys.argv[1]).resolve()
expected_archive = Path(sys.argv[2]).resolve()
env = dict(os.environ, PATH=str(tools / 'bin') + os.pathsep + os.environ['PATH'])


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, env=env, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


with tempfile.TemporaryDirectory(prefix='npm-legacy-native-') as temporary:
    root = Path(temporary) / 'project'
    shutil.copytree(Path(__file__).parent / 'fixtures' / 'legacy-node', root)
    env['HOME'] = str(Path(temporary) / 'home')
    Path(env['HOME']).mkdir()
    before = {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()}
    assert run('node', '--version', cwd=root) == 'v12.22.12'
    assert run('npm', '--version', cwd=root).startswith('6.')
    run('npm-purifier', 'lock', cwd=root)
    run('npm-purifier', 'prefetch', cwd=root)
    env['npm_config_registry'] = 'http://127.0.0.1:9'
    run('npm', 'ci', cwd=root)
    run('npm', 'run', 'build', cwd=root)
    run('npm', 'test', cwd=root)
    assert run('node', 'cli.js', cwd=root) == '42 on v12.22.12'
    assert (root / 'built.txt').read_text() == 'v12.22.12'
    for name, contents in before.items():
        assert (root / name).read_bytes() == contents, f'native workflow changed {name}'
    with registry(root) as (url, uploads):
        env['npm_config_registry'] = url
        run('npm-purifier', 'publish', '--registry', url, cwd=root)
        assert uploads and 'npm/6.' in uploads[0][1] and 'node/v12.22.12' in uploads[0][1], uploads
    assert uploads[0][0] == expected_archive.read_bytes(), 'native upload differs from the pure release'
    for name, contents in before.items():
        assert (root / name).read_bytes() == contents, f'publication changed {name}'
    print('PASS npm6/Node12 lock, prefetch, offline ci, build/test and actual publication; v1 lockfile unchanged')
