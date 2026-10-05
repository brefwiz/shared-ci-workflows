#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Smoke the built image's retained npm archives and selected compiler offline."""

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile


DIRECTORY = Path('/opt/compiler-custody/typescript')
NODE = Path('/usr/bin/node')


def runtime_environment():
    return {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': '/tmp', 'LANG': 'C.UTF-8',
            'NODE_PATH': '/usr/lib/node_modules:/usr/local/lib/node_modules'}


def sealed(path):
    for ancestor in (path, *path.parents):
        info = ancestor.lstat()
        if ancestor.is_symlink() or info.st_uid != 0 or info.st_gid != 0 or info.st_mode & 0o022:
            raise ValueError(f'unsealed compiler custody: {ancestor}')
    if not path.is_file() or path.stat().st_size > 256 * 1024 * 1024:
        raise ValueError('compiler custody file absent or exceeds bound')
    return path.read_bytes()


def owned(spelling):
    path = Path(spelling)
    if path.is_absolute() or '..' in path.parts or len(path.parts) != 1:
        raise ValueError('retained compiler input escapes fixed provider directory')
    return DIRECTORY / path


def main():
    receipt = json.loads(sealed(DIRECTORY / 'receipt.json'))
    if receipt['schema'] != 'brefwiz.compiler-custody/1' or receipt['language'] != 'typescript':
        raise ValueError('unexpected compiler custody receipt')
    packages = receipt['packages']
    if not packages or len(packages) > 64 or packages[0]['name'] != 'typescript' or packages[0]['version'] != receipt['version']:
        raise ValueError('compiler graph has wrong root')
    installed = set()
    native_drivers = []
    for row in packages:
        metadata_bytes = sealed(owned(row['metadata']))
        if hashlib.sha256(metadata_bytes).hexdigest() != row['metadataSha256']:
            raise ValueError('retained npm metadata changed')
        metadata = json.loads(metadata_bytes)
        expected_url = 'https://registry.npmjs.org/' + row['name'].replace('/', '%2F') + '/' + row['version']
        if (any(metadata[key] != row[key] for key in ('name', 'version'))
                or row['metadataUrl'] != expected_url or not metadata['dist']['tarball'].startswith('https://registry.npmjs.org/')):
            raise ValueError('retained npm package identity changed')
        archive = owned(row['archive'])
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(sealed(archive)).digest()).decode()
        if integrity != row['integrity'] or integrity != metadata['dist']['integrity']:
            raise ValueError('retained npm archive changed')
        members = set()
        root = Path(row['root'])
        if not root.is_absolute():
            raise ValueError('retained installed package root is not absolute')
        total = 0
        with tarfile.open(archive, 'r:gz') as bundle:
            for index, member in enumerate(bundle):
                total += member.size
                if index >= 100000 or member.size < 0 or total > 512 * 1024 * 1024:
                    raise ValueError('retained compiler archive exceeds bounds')
                if member.isdir():
                    continue
                parts = Path(member.name).parts
                if not member.isfile() or not parts or parts[0] != 'package' or '..' in parts:
                    raise ValueError('unsafe retained npm member')
                relative = Path(*parts[1:]).as_posix()
                if relative in members:
                    raise ValueError('duplicate retained npm member')
                members.add(relative)
                if relative not in row['files']:
                    raise ValueError('retained compiler inventory incomplete')
                installed_record = row['files'][relative]
                content = bundle.extractfile(member).read()
                path = root / relative
                if (installed_record['member'] != member.name or hashlib.sha256(content).hexdigest() != installed_record['sha256']
                        or sealed(path) != content):
                    raise ValueError(f'installed compiler differs from retained npm archive: {path}')
                installed.add(str(path))
                if (row['name'] == f"@typescript/typescript-{receipt['platform']}-{receipt['arch']}"
                        and content.startswith(b'\x7fELF')):
                    if not path.stat().st_mode & 0o111:
                        raise ValueError('native TypeScript driver is not executable')
                    native_drivers.append({'path': str(path), 'sha256': installed_record['sha256']})
        if members != set(row['files']):
            raise ValueError('retained compiler inventory incomplete')
    script = "const p=require('typescript/package.json');console.log(JSON.stringify({entry:require.resolve('typescript'),version:p.version,arch:process.arch,platform:process.platform}))"
    node_bytes = sealed(NODE)
    node = {'path': str(NODE), 'sha256': hashlib.sha256(node_bytes).hexdigest()}
    native_drivers.sort(key=lambda row: row['path'])
    if (not node_bytes.startswith(b'\x7fELF') or not NODE.stat().st_mode & 0o111
            or receipt.get('runtime') != {'node': node, 'nativeDrivers': native_drivers}
            or (receipt['version'].startswith('7.') and not native_drivers)):
        raise ValueError('selected compiler drivers differ from retained provider bytes')
    actual = json.loads(subprocess.check_output([str(NODE), '-e', script], cwd='/tmp',
                                               text=True, env=runtime_environment()))
    if any(actual[key] != receipt[key] for key in ('entry', 'version', 'arch', 'platform')) or actual['entry'] not in installed:
        raise ValueError('selected compiler differs from retained compiler')
    if receipt['version'].startswith('7.') and not any(
            row['name'] == f"@typescript/typescript-{actual['platform']}-{actual['arch']}" for row in packages):
        raise ValueError('retained compiler lacks architecture package')
    print('TypeScript installed compiler custody verified')


if __name__ == '__main__':
    main()
