# SPDX-License-Identifier: MIT
"""Owning bake binds actual npm package bytes before issuing custody."""

import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


class TypeScriptCustodyTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('typescript_custody', ROOT / 'docker/retain-typescript-custody.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        verifier_spec = importlib.util.spec_from_file_location('typescript_verifier', ROOT / 'scripts/verify-typescript-custody.py')
        self.verifier = importlib.util.module_from_spec(verifier_spec)
        verifier_spec.loader.exec_module(self.verifier)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.node = root / 'node'
        self.node.write_bytes(b'\x7fELFfixture-node')
        self.node.chmod(0o755)
        self.module.NODE = self.node
        self.verifier.NODE = self.node
        record = patch.object(self.module, 'node_record', side_effect=lambda: {
            'path': str(self.node), 'sha256': hashlib.sha256(self.node.read_bytes()).hexdigest()})
        record.start()
        self.addCleanup(record.stop)
        self.module.DESTINATION = root / 'custody'
        self.verifier.DIRECTORY = self.module.DESTINATION
        self.package = root / 'typescript'
        self.package.mkdir()
        files = {'package.json': b'{"name":"typescript","version":"6.0.3"}', 'lib/typescript.js': b'compiler'}
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for relative, content in files.items():
                path = self.package / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                member = tarfile.TarInfo('package/' + relative)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        archive = stream.getvalue()
        url = 'https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz'
        metadata = {'name': 'typescript', 'version': '6.0.3', 'dist': {
            'tarball': url, 'integrity': 'sha512-' + base64.b64encode(hashlib.sha512(archive).digest()).decode()}}
        self.official = {url: archive, 'https://registry.npmjs.org/typescript/6.0.3': json.dumps(metadata).encode()}
        self.resolved = {'entry': str(self.package / 'lib/typescript.js'), 'version': '6.0.3', 'arch': 'x64', 'platform': 'linux',
                         'packages': [{'root': str(self.package), 'name': 'typescript', 'version': '6.0.3'}]}
        fetch = patch.object(self.module, 'fetch', side_effect=lambda url: self.official[url])
        fetch.start()
        self.addCleanup(fetch.stop)
        resolve = patch.object(self.module.subprocess, 'check_output', side_effect=lambda *args, **kwargs: json.dumps(self.resolved))
        resolve.start()
        self.addCleanup(resolve.stop)

    def test_retains_complete_archive_inventory(self):
        self.module.main('6.0.3')
        receipt = json.loads((self.module.DESTINATION / 'receipt.json').read_text())
        self.assertEqual(set(receipt['packages'][0]['files']), {'package.json', 'lib/typescript.js'})
        self.assertTrue((self.module.DESTINATION / 'package-0.tgz').is_file())

    def test_rejects_replaced_installed_compiler(self):
        (self.package / 'lib/typescript.js').write_bytes(b'replacement')
        with self.assertRaisesRegex(ValueError, 'differs from official archive'):
            self.module.main('6.0.3')

    def test_rejects_changed_archive_integrity(self):
        self.official['https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz'] += b'changed'
        with self.assertRaisesRegex(ValueError, 'integrity differs'):
            self.module.main('6.0.3')

    def test_requires_modern_native_architecture_package(self):
        self.resolved['packages'][0]['version'] = '7.0.0'
        with self.assertRaisesRegex(ValueError, 'architecture-owned executable package'):
            self.module.main('7.0.0')

    def test_offline_verification_uses_retained_archives(self):
        self.module.main('6.0.3')
        # Pure fixture bytes isolate archive joins from production root custody.
        with patch.object(self.verifier, 'sealed', side_effect=Path.read_bytes), \
                patch.object(self.module, 'fetch', side_effect=AssertionError('offline verifier fetched npm')):
            self.verifier.main()

    def test_offline_verification_rejects_mutated_provider(self):
        for failure in ('installed', 'archive', 'inventory', 'metadata', 'selected'):
            with self.subTest(failure=failure):
                self.module.main('6.0.3')
                receipt_path = self.module.DESTINATION / 'receipt.json'
                receipt = json.loads(receipt_path.read_text())
                if failure == 'installed':
                    (self.package / 'lib/typescript.js').write_bytes(b'replacement')
                elif failure == 'archive':
                    (self.module.DESTINATION / 'package-0.tgz').write_bytes(b'changed')
                elif failure == 'inventory':
                    receipt['packages'][0]['files'].pop('lib/typescript.js')
                elif failure == 'metadata':
                    (self.module.DESTINATION / 'package-0.json').write_bytes(b'changed')
                else:
                    receipt['entry'] = str(self.package / 'other.js')
                receipt_path.write_text(json.dumps(receipt))
                with patch.object(self.verifier, 'sealed', side_effect=Path.read_bytes):
                    with self.assertRaises(ValueError):
                        self.verifier.main()
                (self.package / 'lib/typescript.js').write_bytes(b'compiler')

    def test_substituted_native_driver_fails_before_execution(self):
        self.module.main('6.0.3')
        self.node.write_bytes(b'\x7fELFsubstituted-driver')
        with patch.object(self.verifier, 'sealed', side_effect=Path.read_bytes), \
                patch.object(self.verifier.subprocess, 'check_output', side_effect=AssertionError('unbound driver executed')):
            with self.assertRaisesRegex(ValueError, 'drivers differ'):
                self.verifier.main()

    def test_driver_uses_absolute_path_and_clean_startup_environment(self):
        calls = []
        def execute(command, **options):
            calls.append((command, options))
            return json.dumps(self.resolved)
        with patch.dict('os.environ', {'NODE_OPTIONS': '--require /tmp/foreign.js', 'LD_PRELOAD': '/tmp/foreign.so'}), \
                patch.object(self.module.subprocess, 'check_output', side_effect=execute):
            self.module.main('6.0.3')
            with patch.object(self.verifier, 'sealed', side_effect=Path.read_bytes):
                self.verifier.main()
        self.assertEqual(len(calls), 2)
        for command, options in calls:
            self.assertEqual(command[0], str(self.node))
            self.assertNotIn('NODE_OPTIONS', options['env'])
            self.assertNotIn('LD_PRELOAD', options['env'])
            self.assertEqual(options['env']['NODE_PATH'], '/usr/lib/node_modules:/usr/local/lib/node_modules')
