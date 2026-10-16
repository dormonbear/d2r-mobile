#!/usr/bin/env python3
"""真实客户端对本地 Postman 协议替身的集成测试；所有存档都是自造文本。
Integration tests of the real client against a local Postman protocol stand-in; saves are authored text.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[3]


class WebDAVSync(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='d2r-webdav-tests-')
        cls.folder = Path(cls.temp.name)
        cls.client = cls.folder / 'client'
        subprocess.run(['clang', '-O1', '-c', str(ROOT / 'dm/host/dm_cloudsync.c'), '-o', str(cls.folder / 'core.o')], check=True)
        subprocess.run(['clang', '-O1', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-DDM_WEBDAV_TESTING', '-I' + str(ROOT / 'dm/host'), str(ROOT / 'dm/ios/tests/webdav_client.m'), str(ROOT / 'dm/ios/Sources/dm_webdav_store.m'), str(cls.folder / 'core.o'), '-framework', 'Foundation', '-o', str(cls.client)], check=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cls.url = f'http://127.0.0.1:{port}'
        handler = ROOT / 'postman/mocks/webdav/default.js'
        (cls.folder / 'mock.yaml').write_text(f'version: 1\nname: WebDAV\nslug: webdav\nprotocol: http\nport: {port}\nscenarios:\n  - name: default\n    path: {json.dumps(str(handler))}\n    default: true\n')
        (cls.folder / 'test.sim.yaml').write_text(f'simulation: webdav-save-test\nrouting: path\nmocks:\n  - routeKey: webdav\n    path: {json.dumps(str(cls.folder / "mock.yaml"))}\n')
        cls.log = (cls.folder / 'simulation.log').open('w')
        cls.server = subprocess.Popen(['postman', 'simulate', 'run', str(cls.folder / 'test.sim.yaml')], stdout=cls.log, stderr=cls.log, start_new_session=True)
        for _ in range(60):
            try:
                cls.control(reset=True)
                break
            except OSError:
                if cls.server.poll() is not None:
                    raise RuntimeError((cls.folder / 'simulation.log').read_text())
                time.sleep(0.2)
        else:
            raise RuntimeError('Postman mock failed to start')

    @classmethod
    def tearDownClass(cls):
        os.killpg(cls.server.pid, signal.SIGINT)
        try:
            cls.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(cls.server.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                if cls.server.poll() is None:
                    cls.server.terminate()
            cls.server.wait(timeout=5)
        cls.log.close()
        if os.environ.get('DM_WEBDAV_TEST_ARTIFACTS'):
            output = Path(os.environ['DM_WEBDAV_TEST_ARTIFACTS'])
            output.mkdir(parents=True, exist_ok=True)
            shutil.copy2(cls.folder / 'simulation.log', output / 'postman-simulation.log')
            print('Postman request log:', output / 'postman-simulation.log')
        cls.temp.cleanup()

    @classmethod
    def control(cls, **data):
        request = urllib.request.Request(cls.url + '/__test__', json.dumps(data).encode(), {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.load(response)

    def setUp(self):
        self.control(reset=True)
        self.case = Path(tempfile.mkdtemp(dir=self.folder))

    def device(self, name):
        path = self.case / name / 'save'
        path.mkdir(parents=True, exist_ok=True)
        return path

    def put(self, device, text, name='Alice'):
        path = self.device(device) / name / (name + '.d2s')
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)
        stamp = int(time.time()) + sum(text.encode())
        os.utime(path, (stamp, stamp))

    def sync(self, device, down=True, choice=None, url=None, choice_only=False):
        save = self.device(device)
        cmd = [str(self.client), url or self.url, str(save), str(save.parent / 'work'), str(int(down))]
        if choice:
            cmd.extend((choice[0], str(int(choice[1]))))
        if choice_only:
            cmd.append('choice-only')
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(result.stdout.splitlines()[-1])

    def contents(self, device):
        return (self.device(device) / 'Alice/Alice.d2s').read_text()

    def baseline(self):
        self.put('a', 'base')
        self.assertTrue(self.sync('a')['ok'])
        self.assertTrue(self.sync('b')['ok'])

    def test_two_devices_download_and_upload(self):
        self.baseline()
        self.assertEqual(self.contents('b'), 'base')
        self.put('a', 'new version')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertEqual(self.sync('b', down=False)['code'], 7)
        self.assertEqual(self.contents('b'), 'base')
        self.assertTrue(self.sync('b')['ok'])
        self.assertEqual(self.contents('b'), 'new version')

    def test_conflict_preserves_both_and_can_choose_server(self):
        self.baseline()
        self.put('a', 'server edit')
        self.put('b', 'local edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        before = self.control()['index']
        result = self.sync('b')
        self.assertEqual(result['code'], 6)
        self.assertIn('Alice', result['conflicts'])
        self.assertEqual(self.contents('b'), 'local edit')
        self.assertEqual(before, self.control()['index'])
        self.assertTrue(self.sync('b', choice=('Alice', False))['ok'])
        self.assertEqual(self.contents('b'), 'server edit')
        backups = list((self.case / 'b/work/backups').rglob('Alice.d2s'))
        self.assertTrue(any(p.read_text() == 'local edit' for p in backups))

    def test_explicit_local_wins_and_old_remote_objects_remain(self):
        self.baseline()
        self.put('a', 'server edit')
        self.put('b', 'local edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        before = set(self.control()['files'])
        self.assertTrue(self.sync('b', choice=('Alice', True))['ok'])
        self.assertTrue(before <= set(self.control()['files']))
        self.assertTrue(self.sync('c')['ok'])
        self.assertEqual(self.contents('c'), 'local edit')

    def test_choice_does_not_apply_to_later_versions(self):
        self.baseline()
        self.put('a', 'server edit')
        self.put('b', 'local edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b', choice=('Alice', True), choice_only=True)['ok'])
        self.put('a', 'server edited again')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertEqual(self.sync('b')['code'], 6)
        self.assertEqual(self.contents('b'), 'local edit')

    def test_deletion_is_a_pack_and_preserves_local_backup(self):
        self.baseline()
        shutil.rmtree(self.device('a') / 'Alice')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b')['ok'])
        self.assertFalse((self.device('b') / 'Alice').exists())
        self.assertTrue(list((self.case / 'b/work/backups').rglob('Alice.d2s')))

    def test_downloaded_deletion_stays_deleted_across_restarts(self):
        self.baseline()
        shutil.rmtree(self.device('a') / 'Alice')
        self.assertTrue(self.sync('a', down=False)['ok'])
        for device in ('b', 'fresh'):
            for _ in range(3):
                self.assertTrue(self.sync(device)['ok'])
                self.assertFalse((self.device(device) / 'Alice').exists())
                self.put(device, 'unrelated progress', name='Bob')
                self.assertTrue(self.sync(device, down=False)['ok'])

    def test_missing_startup_save_does_not_publish_deletions(self):
        self.baseline()
        before = self.control()['index']
        shutil.rmtree(self.device('a'))
        self.assertTrue(self.sync('a')['ok'])
        self.assertEqual(self.control()['index'], before)
        self.assertEqual(self.contents('a'), 'base')
        shutil.rmtree(self.device('a') / 'Alice')
        self.assertTrue(self.sync('a')['ok'])
        self.assertEqual(self.control()['index'], before)
        self.assertTrue(self.sync('b')['ok'])
        self.assertEqual(self.contents('b'), 'base')

    def test_offline_deletion_survives_next_startup(self):
        self.baseline()
        shutil.rmtree(self.device('a') / 'Alice')
        self.control(fault='server')
        self.assertFalse(self.sync('a', down=False)['ok'])
        self.control(fault='')
        self.assertTrue(self.sync('a')['ok'])
        self.assertFalse((self.device('a') / 'Alice').exists())
        self.assertTrue(self.sync('b')['ok'])
        self.assertFalse((self.device('b') / 'Alice').exists())

    def test_lost_publish_response_does_not_conflict_with_later_local_progress(self):
        self.baseline()
        self.put('a', 'first update')
        self.control(fault='lost-index-response')
        self.assertEqual(self.sync('a', down=False)['code'], 2)
        self.control(fault='')
        self.put('a', 'second update')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b')['ok'])
        self.assertEqual(self.contents('b'), 'second update')

    def test_shared_stash_conflict_is_not_automatically_merged(self):
        relative = 'ModernSharedStashSoftCoreV2/ModernSharedStashSoftCoreV2.d2i'
        def put_stash(device, text):
            p = self.device(device) / relative
            p.parent.mkdir(exist_ok=True)
            p.write_text(text)
            stamp = 1900000000 + sum(text.encode())
            os.utime(p, (stamp, stamp))
        put_stash('a', 'base stash')
        self.assertTrue(self.sync('a')['ok'])
        self.assertTrue(self.sync('b')['ok'])
        put_stash('a', 'server stash edit')
        put_stash('b', 'local stash edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        result = self.sync('b')
        self.assertEqual(result['code'], 6)
        self.assertIn('_stash', result['conflicts'])
        self.assertEqual((self.device('b') / relative).read_text(), 'local stash edit')
        self.assertTrue(self.sync('b', choice=('_stash', False))['ok'])
        self.assertEqual((self.device('b') / relative).read_text(), 'server stash edit')
        for down in (False, True, False):
            self.assertTrue(self.sync('b', down=down)['ok'])
            self.assertEqual((self.device('b') / relative).read_text(), 'server stash edit')

    def test_structured_stash_choice_and_later_shrink_are_exact(self):
        relative = 'ModernSharedStashSoftCoreV2/ModernSharedStashSoftCoreV2.d2i'
        def data(count):
            size = 148 + 10 * count
            out = bytearray(size)
            out[:4] = bytes.fromhex('55aa55aa')
            struct.pack_into('<I', out, 16, size)
            out[64:68] = bytes.fromhex('c0edeac0')
            struct.pack_into('<HH', out, 68, 1, count)
            for i in range(count):
                struct.pack_into('<IHI', out, 84 + 10 * i, i + 1, 0, 1)
            return bytes(out)
        def put(device, count):
            path = self.device(device) / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data(count))
        put('a', 2)
        self.assertTrue(self.sync('a')['ok'])
        self.assertTrue(self.sync('b')['ok'])
        put('a', 3)
        put('b', 5)
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b', choice=('_stash', False))['ok'])
        for down in (False, True):
            self.assertTrue(self.sync('b', down=down)['ok'])
            self.assertEqual((self.device('b') / relative).read_bytes(), data(3))
        put('b', 1)
        self.assertTrue(self.sync('b', down=False)['ok'])
        self.assertTrue(self.sync('a')['ok'])
        self.assertEqual((self.device('a') / relative).read_bytes(), data(1))

    def test_failed_index_cas_does_not_advance_checkpoint(self):
        self.baseline()
        checkpoint = self.case / 'a/work/checkpoint.json'
        before = checkpoint.read_bytes()
        old_index = self.control()['index']
        self.put('a', 'new version')
        self.control(fault='race')
        self.assertEqual(self.sync('a', down=False)['code'], 6)
        self.assertEqual(checkpoint.read_bytes(), before)
        self.assertEqual(self.control()['index'], old_index)
        self.control(fault='')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b')['ok'])
        self.assertEqual(self.contents('b'), 'new version')

    def test_http_failures_and_corruption_leave_local_untouched(self):
        self.baseline()
        for mode, expected in [('auth', 3), ('server', 4), ('noetag', 5), ('weak', 5), ('static-etag', 5), ('ignore-conditions', 5), ('redirect', 5), ('corrupt', 5), ('timeout', 2)]:
            with self.subTest(mode=mode):
                self.control(fault=mode)
                out = self.sync('fresh-' + mode)
                self.assertFalse(out['ok'])
                self.assertEqual(out['code'], expected)
                self.assertFalse(list(self.device('fresh-' + mode).rglob('*.d2s')))
                self.assertFalse((self.case / ('fresh-' + mode) / 'work/checkpoint.json').exists())
                self.control(fault='')

    def test_cross_character_pack_is_rejected(self):
        self.baseline()
        value = self.control()['index']['units']['Alice']
        self.control(mutate={'version': 1, 'units': {'Bob': value}})
        self.assertEqual(self.sync('fresh')['code'], 5)
        self.assertFalse(list(self.device('fresh').rglob('*.d2s')))

    def test_backup_failure_does_not_replace_live_save(self):
        self.baseline()
        self.put('a', 'server edit')
        self.put('b', 'local edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        path = self.case / 'b/work/backups'
        if path.exists():
            shutil.rmtree(path)
        path.write_text('cannot make a backup directory here')
        self.assertEqual(self.sync('b', choice=('Alice', False))['code'], 8)
        self.assertEqual(self.contents('b'), 'local edit')

    def test_corrupt_checkpoint_fails_without_touching_live_save(self):
        self.baseline()
        checkpoint = self.case / 'b/work/checkpoint.json'
        checkpoint.write_text('{"local": null, "remote": {}}')
        self.assertEqual(self.sync('b')['code'], 8)
        self.assertEqual(self.contents('b'), 'base')

    def test_corrupt_choice_is_ignored_without_overwrite(self):
        self.baseline()
        self.put('a', 'server edit')
        self.put('b', 'local edit')
        self.assertTrue(self.sync('a', down=False)['ok'])
        (self.case / 'b/work/choices.json').write_text('{"Alice":null}')
        self.assertEqual(self.sync('b')['code'], 6)
        self.assertEqual(self.contents('b'), 'local edit')

    def test_every_object_and_index_write_is_conditional(self):
        self.baseline()
        self.put('a', 'next')
        self.assertTrue(self.sync('a', down=False)['ok'])
        requests = self.control()['served']
        objects = [r for r in requests if r['method'] == 'PUT' and '/objects/' in r['path']]
        indexes = [r for r in requests if r['method'] == 'PUT' and r['path'].endswith('/index.json')]
        self.assertTrue(objects and indexes)
        self.assertTrue(all(r['ifNoneMatch'] == '*' for r in objects))
        self.assertTrue(all(r['ifNoneMatch'] == '*' or r['ifMatch'] for r in indexes))
        self.assertTrue(any(r['method'] == 'GET' and '/objects/' in r['path'] for r in requests))

    def test_fnos_uses_enforced_collection_lock_when_conditionals_are_ignored(self):
        self.control(fault='fnos')
        self.baseline()
        self.put('a', 'fnos update')
        self.assertTrue(self.sync('a', down=False)['ok'])
        self.assertTrue(self.sync('b')['ok'])
        self.assertEqual(self.contents('b'), 'fnos update')
        report = self.control()
        self.assertFalse(report['lockActive'])
        self.assertTrue(any(r['method'] == 'LOCK' for r in report['served']))
        self.assertTrue(any(r['method'] == 'UNLOCK' for r in report['served']))
        index_writes = [r for r in report['served'] if r['method'] == 'PUT' and r['path'].endswith('/index.json')]
        self.assertTrue(index_writes)
        self.assertTrue(all(r['hasLock'] for r in index_writes))

    def test_concurrent_fnos_clients_preserve_both_devices_progress(self):
        self.control(fault='fnos')
        self.baseline()
        self.put('a', 'alice progress')
        self.put('b', 'bob progress', name='Bob')
        self.control(fault='fnos-delayed')
        processes = []
        for name in ('a', 'b'):
            save = self.device(name)
            processes.append(subprocess.Popen([str(self.client), self.url, str(save), str(save.parent / 'work'), '1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        reports = []
        for process in processes:
            output, error = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, error)
            reports.append(json.loads(output.splitlines()[-1]))
        self.assertTrue(any(r['ok'] for r in reports))
        for name, report in zip(('a', 'b'), reports):
            if not report['ok']:
                self.assertEqual(report['code'], 6)
                self.assertTrue(self.sync(name)['ok'])
        self.assertTrue(self.sync('c')['ok'])
        self.assertEqual(self.contents('c'), 'alice progress')
        self.assertEqual((self.device('c') / 'Bob/Bob.d2s').read_text(), 'bob progress')
        self.assertFalse(self.control()['lockActive'])

    def test_nonexclusive_collection_lock_is_rejected_and_both_tokens_released(self):
        self.control(fault='fnos-shared-lock')
        self.put('a', 'local only')
        self.assertEqual(self.sync('a')['code'], 5)
        self.assertEqual(self.contents('a'), 'local only')
        report = self.control()
        self.assertIsNone(report['index'])
        self.assertFalse(report['lockActive'])
        self.assertEqual(sum(r['method'] == 'LOCK' and r['code'] == 200 for r in report['served']), 2)
        self.assertTrue(all(not r['hasLock'] for r in report['served'] if r['method'] == 'LOCK'))
        self.assertEqual(sum(r['method'] == 'UNLOCK' and r['code'] == 204 for r in report['served']), 2)

    def test_unenforced_collection_lock_is_rejected(self):
        self.control(fault='fnos-unsafe-lock')
        self.put('a', 'local only')
        self.assertEqual(self.sync('a')['code'], 5)
        self.assertEqual(self.contents('a'), 'local only')
        self.assertIsNone(self.control()['index'])
        self.assertFalse(self.control()['lockActive'])

    def test_expired_collection_lock_cannot_publish_or_advance_checkpoint(self):
        self.control(fault='fnos')
        self.baseline()
        checkpoint = self.case / 'a/work/checkpoint.json'
        before = checkpoint.read_bytes()
        index = self.control()['index']
        self.put('a', 'unpublished progress')
        self.control(fault='fnos-expired')
        self.assertEqual(self.sync('a', down=False)['code'], 6)
        self.assertEqual(checkpoint.read_bytes(), before)
        self.assertEqual(self.control()['index'], index)
        self.control(fault='fnos')
        self.assertTrue(self.sync('a', down=False)['ok'])

    def test_unwritable_root_is_reported_before_any_save_upload(self):
        self.control(fault='unwritable-root')
        device = self.device('unwritable')
        result = subprocess.run([str(self.client), self.url, str(device), str(device.parent / 'work'), 'check'], capture_output=True, text=True, timeout=25, check=True)
        out = json.loads(result.stdout.splitlines()[-1])
        self.assertFalse(out['ok'])
        self.assertEqual(out['code'], 4)
        self.assertEqual(out['diagnostics']['httpStatus'], 405)
        requests = out['diagnostics']['requests']
        self.assertEqual([r['method'] for r in requests], ['MKCOL', 'MKCOL', 'MKCOL', 'PUT'])
        self.assertTrue(all(r['httpStatus'] == 405 for r in requests))
        self.assertNotIn('/index.json', json.dumps(self.control()['served']))
        self.assertEqual(self.control()['files'], [])

    def test_connection_failures_have_redacted_request_diagnostics(self):
        for fault, code, status in [('auth', 3, 401), ('server', 4, 500), ('noetag', 5, 501), ('unexpected-precondition', 5, 501)]:
            self.control(fault=fault)
            device = self.device('check-' + fault)
            result = subprocess.run([str(self.client), self.url, str(device), str(device.parent / 'work'), 'check'], capture_output=True, text=True, timeout=25, check=True)
            out = json.loads(result.stdout.splitlines()[-1])
            self.assertFalse(out['ok'])
            self.assertEqual(out['code'], code)
            self.assertEqual(out['diagnostics']['httpStatus'], status)
            encoded = json.dumps(out['diagnostics'])
            self.assertNotIn('authorization', encoded.lower())
            self.assertNotIn('dXNlcjpwYXNz', encoded)
            self.assertNotIn(self.url, encoded)
            self.assertNotIn('127.0.0.1', encoded)
            self.assertIn(out['diagnostics']['method'], ('MKCOL', 'GET', 'PUT', 'LOCK'))
        self.control(fault='')

    def test_connection_network_failure_has_no_success_status_or_address(self):
        self.control(fault='timeout')
        device = self.device('network-check')
        result = subprocess.run([str(self.client), self.url, str(device), str(device.parent / 'work'), 'check'], capture_output=True, text=True, timeout=15, check=True)
        out = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(out['code'], 2)
        self.assertEqual(out['diagnostics']['httpStatus'], 0)
        self.assertEqual(out['diagnostics']['networkDomain'], 'NSURLErrorDomain')
        self.assertEqual(out['diagnostics']['networkCode'], -1001)
        self.assertNotIn('127.0.0.1', json.dumps(out['diagnostics']))

    def test_unencrypted_non_loopback_or_embedded_credentials_are_rejected(self):
        self.assertEqual(self.sync('a', url='http://192.168.1.2/dav')['code'], 1)
        self.assertEqual(self.sync('a', url='https://user:secret@example.invalid/dav')['code'], 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
