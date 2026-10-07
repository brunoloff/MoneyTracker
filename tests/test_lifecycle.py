import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
from lifecycle import IdleServer

spec = importlib.util.spec_from_file_location('launcher', ROOT / 'launcher/launch-legacy.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class IdleTests(unittest.TestCase):
    def server(self):
        # Test the lifecycle without binding a socket or accessing private data.
        now = [0]
        with patch('lifecycle.ThreadingHTTPServer.__init__', return_value=None):
            server = IdleServer(None, None, clock=lambda: now[0])
        return server, now

    def test_timeout_after_30_minutes_only_once(self):
        server, now = self.server()
        with patch('lifecycle.threading.Thread') as worker:
            now[0] = 1799
            server.service_actions()
            worker.assert_not_called()
            now[0] = 1800
            server.service_actions()
            server.service_actions()
            worker.assert_called_once_with(target=server.shutdown, daemon=True)
            worker.return_value.start.assert_called_once()

    def test_heartbeat_extends_lifetime(self):
        server, now = self.server()
        with patch('lifecycle.threading.Thread') as worker:
            now[0] = 1500
            server.touch()
            now[0] = 1800
            server.service_actions()
            worker.assert_not_called()
            now[0] = 3300
            server.service_actions()
            worker.assert_called_once()

    def test_bank_sync_prevents_timeout(self):
        server, now = self.server()
        server.busy = lambda: True
        now[0] = 3600
        with patch('lifecycle.threading.Thread') as worker:
            server.service_actions()
            worker.assert_not_called()
        self.assertEqual(server.last_activity, 3600)


class LauncherTests(unittest.TestCase):
    def test_reuses_existing_instance(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launcher, 'PRIVATE', Path(temp)), patch.object(launcher, 'health', return_value={'revision':launcher.revision(ROOT)}), patch.object(launcher.subprocess, 'Popen') as spawn:
            launcher.start_server()
            spawn.assert_not_called()

    def test_starts_detached_server_once(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launcher, 'PRIVATE', Path(temp)), patch.object(launcher, 'health', return_value=None), patch.object(launcher, 'ready', side_effect=[False, True]), patch.object(launcher.subprocess, 'Popen') as spawn, patch.object(launcher.time, 'sleep'):
            spawn.return_value.poll.return_value = None
            launcher.start_server()
            spawn.assert_called_once()
            self.assertTrue(spawn.call_args.kwargs['start_new_session'])
            self.assertEqual(spawn.call_args.args[0][-1], str(ROOT / 'server/main.py'))

    def test_occupied_port_does_not_open_browser(self):
        with patch.object(launcher, 'start_server', side_effect=RuntimeError('port occupied')), patch.object(launcher, 'open_browser') as browser, patch.object(launcher.shutil, 'which', return_value=None):
            self.assertEqual(launcher.main(), 1)
            browser.assert_not_called()

    def test_success_opens_default_browser(self):
        with patch.object(launcher, 'start_server') as start, patch.object(launcher, 'open_browser') as browser:
            self.assertEqual(launcher.main(), 0)
            start.assert_called_once()
            browser.assert_called_once()


class LauncherUpdateTests(unittest.TestCase):
    def test_restarts_old_revision_before_starting(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launcher,'PRIVATE',Path(temp)), patch.object(launcher,'health',return_value={'revision':'old'}), patch.object(launcher,'stop_outdated') as stop, patch.object(launcher,'ready',return_value=True), patch.object(launcher.subprocess,'Popen') as spawn:
            launcher.start_server()
            stop.assert_called_once_with({'revision':'old'})
            spawn.assert_called_once()
    def test_graceful_restart_waits_for_sync(self):
        with patch.object(launcher,'request',side_effect=[{'syncing':True},{'syncing':False},{'ok':True}]) as request, patch.object(launcher,'ready',return_value=False), patch.object(launcher.time,'sleep'), patch.object(launcher.os,'kill') as kill:
            launcher.stop_outdated({'revision':'old'})
            self.assertEqual(request.call_args.args,('api/restart',{}))
            kill.assert_not_called()
    def test_legacy_restart_requires_verified_pid(self):
        with patch.object(launcher,'request',return_value={'syncing':False}), patch.object(launcher,'legacy_server_pid',return_value=4321), patch.object(launcher,'ready',return_value=False), patch.object(launcher.os,'kill') as kill:
            launcher.stop_outdated({})
            kill.assert_called_once_with(4321,launcher.signal.SIGTERM)
    def test_legacy_pid_requires_correct_project_and_socket(self):
        with tempfile.TemporaryDirectory() as temp:
            proc=Path(temp)
            (proc/'net').mkdir()
            (proc/'net/tcp').write_text('header\n0: 0100007F:223D 00000000:0000 0A 0 0 0 0 0 12345\n')
            entry=proc/'4321';entry.mkdir();(entry/'fd').mkdir()
            (entry/'cwd').symlink_to(ROOT,target_is_directory=True)
            (entry/'cmdline').write_bytes(b'python\x00server/main.py\x00')
            (entry/'fd/3').symlink_to('socket:[12345]')
            self.assertEqual(launcher.legacy_server_pid(proc),4321)
            (entry/'cmdline').write_bytes(b'python\x00other/server/main.py\x00')
            with self.assertRaises(RuntimeError): launcher.legacy_server_pid(proc)
