#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bind image-installed TypeScript and native compiler packages to npm archives."""

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
from urllib.parse import quote
from urllib.request import urlopen


DESTINATION = Path("/opt/compiler-custody/typescript")
ORIGIN = "https://registry.npmjs.org/"
MAX_BYTES = 256 * 1024 * 1024
NODE = Path('/usr/bin/node')


def runtime_environment():
    return {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': '/tmp', 'LANG': 'C.UTF-8',
            'NODE_PATH': '/usr/lib/node_modules:/usr/local/lib/node_modules'}


def node_record():
    for path in (NODE, *NODE.parents):
        info = path.lstat()
        if path.is_symlink() or info.st_uid != 0 or info.st_gid != 0 or info.st_mode & 0o022:
            raise ValueError('selected Node driver is not sealed by owning provider')
    content = NODE.read_bytes()
    if not content.startswith(b'\x7fELF') or not NODE.stat().st_mode & 0o111:
        raise ValueError('selected Node driver is not an executable native image')
    return {'path': str(NODE), 'sha256': hashlib.sha256(content).hexdigest()}


def fetch(url):
    if not url.startswith(ORIGIN):
        raise ValueError("compiler package has foreign npm origin")
    with urlopen(url, timeout=120) as response:
        if not response.url.startswith(ORIGIN):
            raise ValueError("compiler package redirected to foreign origin")
        content = response.read(MAX_BYTES + 1)
    if len(content) > MAX_BYTES:
        raise ValueError("compiler package exceeds bound")
    return content


def main(version):
    node = node_record()
    script = r"""
const fs=require('fs'),path=require('path'),{createRequire}=require('module');
const entry=require.resolve('typescript'), roots=[], seen=new Set();
function enroll(file) {
  let root=path.dirname(file);
  while(!fs.existsSync(path.join(root,'package.json'))) {
    const parent=path.dirname(root); if(parent===root) throw Error('package absent'); root=parent;
  }
  if(seen.has(root))return; seen.add(root);
  const manifest=JSON.parse(fs.readFileSync(path.join(root,'package.json'))),req=createRequire(path.join(root,'package.json'));
  roots.push({root,name:manifest.name,version:manifest.version});
  const optional=manifest.optionalDependencies||{};
  for(const name of new Set([...Object.keys(manifest.dependencies||{}),...Object.keys(optional)])) {
    const found=(req.resolve.paths(name)||[]).map(p=>path.join(p,name,'package.json')).filter(p=>fs.existsSync(p));
    if(!found.length) {if(name in optional) continue; throw Error('compiler dependency absent: '+name);}
    enroll(found[0]);
  }
}
enroll(entry);console.log(JSON.stringify({entry,packages:roots,arch:process.arch,platform:process.platform}));
"""
    resolved = json.loads(subprocess.check_output([str(NODE), "-e", script], text=True,
                                                cwd="/tmp", env=runtime_environment()))
    if resolved["packages"][0] != {"root": resolved["packages"][0]["root"], "name": "typescript", "version": version}:
        raise ValueError("installed TypeScript differs from image pin")
    if version.startswith("7.") and not any(row["name"] == f"@typescript/typescript-{resolved['platform']}-{resolved['arch']}" for row in resolved["packages"]):
        raise ValueError("installed TypeScript lacks architecture-owned executable package")
    DESTINATION.mkdir(parents=True, exist_ok=True)
    packages = []
    for index, row in enumerate(resolved["packages"]):
        url = ORIGIN + quote(row["name"], safe="@") + "/" + quote(row["version"], safe="")
        meta_bytes = fetch(url)
        meta = json.loads(meta_bytes)
        if any(meta.get(key) != row[key] for key in ("name", "version")):
            raise ValueError("official metadata package identity mismatch")
        dist = meta["dist"]
        content = fetch(dist["tarball"])
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(content).digest()).decode()
        if dist.get("integrity") != integrity:
            raise ValueError("compiler package integrity differs from npm metadata")
        archive_path = DESTINATION / f"package-{index}.tgz"
        archive_path.write_bytes(content)
        metadata_path = DESTINATION / f"package-{index}.json"
        metadata_path.write_bytes(meta_bytes)
        files = {}
        total = 0
        root = Path(row["root"])
        with tarfile.open(archive_path, "r:gz") as archive:
            for number, member in enumerate(archive):
                parts = Path(member.name).parts
                total += member.size
                if number > 100000 or total > 512 * 1024 * 1024 or member.size < 0 or not parts or parts[0] != "package" or ".." in parts:
                    raise ValueError("unsafe compiler package archive")
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ValueError("compiler package contains nonregular member")
                relative = Path(*parts[1:])
                path = root / relative
                if path.is_symlink() or not path.is_file():
                    raise ValueError("installed compiler package member absent")
                published = archive.extractfile(member).read()
                if path.read_bytes() != published:
                    raise ValueError(f"installed compiler differs from official archive: {relative}")
                if relative.as_posix() in files:
                    raise ValueError("duplicate compiler package member")
                files[relative.as_posix()] = {"member": member.name, "sha256": hashlib.sha256(published).hexdigest()}
        packages.append({**row, "metadata": metadata_path.name, "metadataUrl": url,
                         "metadataSha256": hashlib.sha256(meta_bytes).hexdigest(), "archive": archive_path.name,
                         "integrity": integrity, "files": files})
    native_drivers = []
    for row in packages:
        if row['name'] != f"@typescript/typescript-{resolved['platform']}-{resolved['arch']}":
            continue
        for relative, owned in row['files'].items():
            path = Path(row['root']) / relative
            if path.read_bytes().startswith(b'\x7fELF'):
                if not path.stat().st_mode & 0o111:
                    raise ValueError('native TypeScript driver is not executable')
                native_drivers.append({'path': str(path), 'sha256': owned['sha256']})
    native_drivers.sort(key=lambda row: row['path'])
    if version.startswith('7.') and not native_drivers:
        raise ValueError('modern compiler package has no actual native driver')
    receipt = {"schema": "brefwiz.compiler-custody/1", "language": "typescript", "version": version,
               "entry": resolved["entry"], "arch": resolved["arch"], "platform": resolved["platform"], "packages": packages,
               "runtime": {'node': node, 'nativeDrivers': native_drivers}}
    (DESTINATION / "receipt.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
