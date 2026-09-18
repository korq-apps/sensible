"""PAM transactions and real libpam evaluation use temporary paths only."""
import contextlib
import ctypes
import ctypes.util
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / 'tools/biometrics'
sys.path.insert(0, str(TOOLS))
import local_ops as ops
import pam_ops as pam
import pam_guard
import pam_session
import recover
import tui
import wizard

COMMON = b'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n'
KDE_COMMON = COMMON + b'auth optional pam_kwallet5.so\n'
KDE_SERVICE = b'@include common-auth\n@include common-account\n@include common-password\n@include common-session\n'
SERVICE = b'# Fixture service\nauth requisite pam_nologin.so\n@include common-auth\nauth optional pam_gnome_keyring.so\n@include common-account\nsession required pam_limits.so\n'


class Transactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('pam', 'howdy', 'howdy/models', 'lib'):
            (self.root / name).mkdir(mode=0o755, exist_ok=True)
        for target, name, value in (
            (ops, 'STATE', self.root / 'state'), (ops, 'CONFIG', self.root / 'howdy/config.ini'),
            (ops, 'PAM_MODULE', self.root / 'lib/pam_howdy.so'),
            (ops, 'PAM_PATH', self.root / 'pam/sensible-howdy-test'), (pam, 'PAM_DIR', self.root / 'pam')):
            patcher = patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        package_locks = patch.object(ops, 'PACKAGE_LOCKS', (self.root / 'lock-frontend', self.root / 'lock-dpkg'))
        package_locks.start()
        self.addCleanup(package_locks.stop)
        for path, content in (
            (ops.CONFIG, b'[core]\ndisabled=false\n[video]\ntimeout=4\ndevice_path=/dev/v4l/by-path/fixture\n'),
            (ops.CONFIG.parent / 'models/fixture.dat', b'face-data'), (ops.PAM_MODULE, b'fixture module'),
            (pam.PAM_DIR / 'common-auth', COMMON), (pam.PAM_DIR / 'common-account', b'account required pam_unix.so\n'),
            (pam.PAM_DIR / 'gdm-password', SERVICE), (pam.PAM_DIR / 'sudo', b'@include common-auth\n@include common-account\n')):
            path.write_bytes(content)
            path.chmod(0o644)
        self.arm = patch.object(pam, 'arm_recovery')
        self.timer = self.arm.start()
        self.addCleanup(self.arm.stop)
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def proof(self):
        with ops.locked_state():
            pam.write_json('verified.json', {'user': 'fixture', 'fingerprint': pam.fingerprint('fixture'),
                                            'checks': {'face': time.time()}})

    def activate(self, services=('gdm-password',)):
        self.proof()
        pam.enable('fixture', list(services))

    def test_enable_requires_a_recent_matching_face_check(self):
        with self.assertRaises(ValueError): pam.enable('fixture', ['gdm-password'])
        self.proof()
        with ops.locked_state():
            proof = pam.read_json('verified.json')
            proof['checks']['face'] = 0
            pam.write_json('verified.json', proof)
        with self.assertRaises(ValueError): pam.enable('fixture', ['gdm-password'])
        self.proof()
        ops.CONFIG.write_bytes(ops.CONFIG.read_bytes() + b'# changed\n')
        with self.assertRaises(ValueError): pam.enable('fixture', ['gdm-password'])
        self.timer.assert_not_called()

    def test_optional_diagnostic_match_does_not_block_verified_activation(self):
        self.proof()
        with patch.object(ops, 'run_pam_service', return_value={
                'start': 0, 'auth': 0, 'account': None, 'message': 'Success'}):
            result = pam.verify('fixture', 'reject')
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'unexpected_match')
        self.assertEqual(set(pam.verification_status('fixture')['checks']), {'face'})
        pam.enable('fixture', ['gdm-password'])
        self.assertEqual(pam.status()['status'], 'pending')

    def test_verify_uses_the_face_only_service_and_failure_invalidates_previous_pass(self):
        with patch.object(ops, 'run_pam_service') as run:
            run.return_value = {'start': 0, 'auth': 0, 'account': 0, 'message': 'Success'}
            self.assertTrue(pam.verify('fixture', 'face')['ok'])
            self.assertEqual(run.call_args.args[0], ops.PAM_FACE)
            self.assertEqual(pam.verification_status('fixture')['checks'], ['face'])
            run.return_value = {'start': 0, 'auth': 7, 'account': None, 'message': 'Authentication failure'}
            self.assertFalse(pam.verify('fixture', 'face')['ok'])
        with ops.locked_state(): self.assertNotIn('face', pam.read_json('verified.json')['checks'])
        with self.assertRaises(ValueError): pam.verify('fixture', 'password')

    def test_rejection_requires_face_pass_and_real_rejection_not_timeout(self):
        with patch.object(ops, 'run_pam_service') as run:
            self.assertEqual(pam.verify('fixture', 'reject')['reason'], 'face_check_required')
            run.return_value = {'start': 0, 'auth': 0, 'account': 0, 'message': 'Success'}
            pam.verify('fixture', 'face')
            self.assertEqual(pam.verify('fixture', 'reject')['reason'], 'unexpected_match')
            run.side_effect = subprocess.TimeoutExpired(['pamtester'], 45)
            self.assertEqual(pam.verify('fixture', 'reject')['reason'], 'timeout')
            run.side_effect = None
            run.return_value = {'start': 0, 'auth': 7, 'account': None, 'message': 'Authentication failure'}
            self.assertTrue(pam.verify('fixture', 'reject')['ok'])
            self.assertFalse(run.call_args.kwargs['account'])

    def test_account_denial_is_not_a_successful_no_face_test(self):
        result = {'start': 0, 'auth': 0, 'account': 13, 'message': 'Account expired'}
        self.assertEqual(pam.verification_result('reject', result)['reason'], 'unexpected_match')
        self.assertEqual(pam.verification_result('face', result)['reason'], 'account_denied')
        result = {'start': 0, 'auth': 4, 'account': None, 'message': 'System error'}
        self.assertEqual(pam.verification_result('reject', result)['reason'], 'unavailable')

    def test_resume_uses_only_fresh_unchanged_checks(self):
        self.proof()
        self.assertEqual(set(pam.verification_status('fixture')['checks']), {'face'})
        with patch.object(pam.time, 'time', return_value=time.time() + 901):
            self.assertEqual(pam.verification_status('fixture')['checks'], [])
        ops.CONFIG.write_bytes(ops.CONFIG.read_bytes() + b'# changed\n')
        self.assertEqual(pam.verification_status('fixture')['checks'], [])

    def test_countdown_happens_before_scan(self):
        self.proof()
        events = []
        with patch.object(pam.time, 'sleep', side_effect=lambda _: events.append('wait')), \
             patch.object(ops, 'run_pam_service', side_effect=lambda *a, **k: (events.append('scan') or
                          {'start': 0, 'auth': 7, 'account': None, 'message': 'Authentication failure'})), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(pam.verify('fixture', 'reject', delay=5)['ok'])
        self.assertEqual(events, ['wait'] * 5 + ['scan'])

    def test_pre_update_checks_do_not_bypass_new_verification(self):
        self.proof()
        with ops.locked_state():
            proof = pam.read_json('verified.json')
            proof['fingerprint'].pop('verification_schema')
            pam.write_json('verified.json', proof)
        self.assertEqual(pam.verification_status('fixture')['checks'], [])
        with self.assertRaises(ValueError): pam.enable('fixture', ['gdm-password'])

    def test_unknown_policy_and_services_refused_without_writes(self):
        self.proof()
        (pam.PAM_DIR / 'common-auth').write_bytes(COMMON + b'auth required pam_u2f.so\n')
        with self.assertRaises(ValueError): pam.service_plan('fixture', ['gdm-password'])
        with self.assertRaises(ValueError): pam.service_plan('fixture', ['sshd'])
        with self.assertRaises(ValueError): pam.service_plan('fixture', ['sddm'])
        with self.assertRaises(ValueError): pam.proposed(SERVICE.replace(b'@include common-account\n', b''), 'fixture')
        with self.assertRaises(ValueError): pam.proposed(SERVICE + b'auth required pam_faillock.so\n', 'fixture')
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_stock_kde_wallet_profile_can_activate_and_restore_without_changing_common_auth(self):
        path = pam.PAM_DIR / 'common-auth'
        path.write_bytes(KDE_COMMON)
        (pam.PAM_DIR / 'kde').write_bytes(KDE_SERVICE)
        (pam.PAM_DIR / 'kde').chmod(0o644)
        (pam.PAM_DIR / 'sddm').write_bytes(SERVICE)
        (pam.PAM_DIR / 'sddm').chmod(0o644)
        self.assertEqual(pam.validate_password_stack(), KDE_COMMON)
        self.activate(('kde', 'sudo'))
        self.assertEqual(pam.status()['services'], ['kde', 'sudo'])
        self.assertIn(pam.block('fixture', 'kde'), (pam.PAM_DIR / 'kde').read_bytes())
        self.assertEqual(path.read_bytes(), KDE_COMMON)
        self.assertEqual((pam.PAM_DIR / 'sddm').read_bytes(), SERVICE)
        pam.rollback()
        self.assertEqual((pam.PAM_DIR / 'kde').read_bytes(), KDE_SERVICE)
        self.assertEqual(path.read_bytes(), KDE_COMMON)

    def test_wallet_allowance_does_not_accept_changed_primary_rules_or_extra_modules(self):
        candidates = [
            KDE_COMMON.replace(b'auth optional pam_kwallet5', b'auth sufficient pam_kwallet5'),
            KDE_COMMON.replace(b'auth optional pam_kwallet5', b'auth required pam_kwallet5'),
            KDE_COMMON.replace(b'pam_kwallet5.so\n', b'pam_kwallet5.so force_run\n'),
            KDE_COMMON + b'auth optional pam_kwallet5.so\n',
            b'auth optional pam_kwallet5.so\n' + COMMON,
            KDE_COMMON.replace(b'success=1', b'success=2'),
            KDE_COMMON.replace(b'pam_unix.so', b'pam_sss.so'),
            b'',
        ]
        candidates += [KDE_COMMON + f'auth {control} {module}\n'.encode()
                       for control in ('optional', 'required')
                       for module in ('pam_u2f.so', 'pam_faillock.so', 'pam_sss.so')]
        for content in candidates:
            with self.subTest(content=content):
                (pam.PAM_DIR / 'common-auth').write_bytes(content)
                with self.assertRaises(ValueError): pam.service_plan('fixture', ['gdm-password'])
                self.assertFalse((ops.STATE / 'pam.json').exists())
        self.timer.assert_not_called()

    def test_guard_before_writes_and_backup_precedes_timer(self):
        self.proof()
        def arm():
            self.assertEqual(pam.read_json('pam.json')['status'], 'pending')
            self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)
        self.timer.side_effect = arm
        pam.enable('fixture', ['gdm-password'])
        self.assertIn(pam.block('fixture'), (pam.PAM_DIR / 'gdm-password').read_bytes())
        with self.assertRaises(ValueError): pam.confirm()

    def test_timer_failure_leaves_original(self):
        self.proof()
        self.timer.side_effect = subprocess.CalledProcessError(1, ['systemd-run'])
        with self.assertRaises(subprocess.CalledProcessError): pam.enable('fixture', ['gdm-password'])
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)
        self.assertFalse((ops.STATE / 'pam.json').exists())

    def test_partial_write_rolls_back_every_service(self):
        self.proof()
        original = ops.atomic_write
        def fail(path, data, *args, **kwargs):
            if path == pam.PAM_DIR / 'sudo' and pam.BEGIN.encode() in data:
                raise OSError('simulated disk write failure')
            return original(path, data, *args, **kwargs)
        with patch.object(ops, 'atomic_write', side_effect=fail), self.assertRaises(OSError):
            pam.enable('fixture', ['gdm-password', 'sudo'])
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_check_and_confirm_then_boot_recovery_leaves_active(self):
        self.activate()
        with patch.object(pam.subprocess, 'run') as run:
            pam.check_services()
            self.assertIn('acct_mgmt', run.call_args.args[0])
        pam.confirm()
        pam.rollback(pending_only=True)
        self.assertEqual(pam.status()['status'], 'active')
        pam.rollback()
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_expiry_and_boot_recover_pending_without_confirmation(self):
        self.activate()
        with patch.object(pam.time, 'time', return_value=time.time() + 301), self.assertRaises(ValueError):
            pam.confirm()
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)
        self.activate()
        pam.rollback(pending_only=True)
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_preserves_external_edits_and_refuses_modified_block(self):
        self.activate()
        path = pam.PAM_DIR / 'gdm-password'
        path.write_bytes(path.read_bytes() + b'# administrator note\n')
        pam.rollback()
        self.assertEqual(path.read_bytes(), SERVICE + b'# administrator note\n')
        self.activate()
        path.write_bytes(path.read_bytes().replace(b'quiet user', b'quiet debug user'))
        with self.assertRaises(ValueError): pam.rollback()
        self.assertTrue((ops.STATE / 'pam.json').exists())

    def test_recovery_can_run_during_service_prompt(self):
        self.activate()
        with patch.object(pam.subprocess, 'run', side_effect=lambda *a, **k: pam.rollback(pending_only=True)):
            with self.assertRaises(ValueError): pam.check_services()
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_recovery_can_run_during_manual_pam_test(self):
        self.activate()
        with patch.object(ops.subprocess, 'run', side_effect=lambda *a, **k: pam.rollback(pending_only=True)):
            ops.pam_test('fixture', timeout=300)
        self.assertEqual(pam.status()['status'], 'off')
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

    def test_recovery_during_verification_does_not_resurrect_proof(self):
        self.activate()
        def prompt(*args, **kwargs):
            pam.rollback(pending_only=True)
            return {'start': 0, 'auth': 0, 'account': 0, 'message': 'Success'}
        with patch.object(ops, 'run_pam_service', side_effect=prompt), self.assertRaises(ValueError):
            pam.verify('fixture', 'face')
        self.assertEqual(pam.status()['status'], 'off')
        self.assertFalse((ops.STATE / 'verified.json').exists())

    def test_original_bytes_with_changed_metadata_retain_recovery_backup(self):
        self.activate()
        path = pam.PAM_DIR / 'gdm-password'
        path.write_bytes(SERVICE)
        path.chmod(0o600)
        with self.assertRaises(pam.ReconciliationError): pam.rollback()
        self.assertTrue((ops.STATE / 'pam.json').exists())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_late_pam_edit_is_not_overwritten_during_activation(self):
        self.proof()
        write = ops.atomic_write
        path = pam.PAM_DIR / 'gdm-password'
        edited = SERVICE + b'# intervening edit\n'
        def concurrent(target, *args, **kwargs):
            if target == path: path.write_bytes(edited)
            return write(target, *args, **kwargs)
        with patch.object(ops, 'atomic_write', side_effect=concurrent), self.assertRaises(pam.ReconciliationError):
            pam.enable('fixture', ['gdm-password'])
        self.assertEqual(path.read_bytes(), edited)
        self.assertTrue((ops.STATE / 'pam.json').exists())

    def test_rollback_retry_after_partial_recovery(self):
        self.activate(('gdm-password', 'sudo'))
        original = ops.atomic_write
        def fail(path, *a, **kw):
            if path.name == 'sudo': raise OSError('temporarily read-only')
            return original(path, *a, **kw)
        with patch.object(ops, 'atomic_write', side_effect=fail), self.assertRaises(OSError): pam.rollback()
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)
        pam.rollback()
        self.assertEqual(pam.status()['status'], 'off')

    def test_recovery_survives_more_than_five_package_lock_failures(self):
        code = ('import fcntl,sys,os; f=open(sys.argv[1], "a+"); os.fchmod(f.fileno(), 0o640); '
                'fcntl.lockf(f, fcntl.LOCK_EX); print("locked", flush=True); sys.stdin.read(1)')
        for path in ops.PACKAGE_LOCKS:
            with self.subTest(lock=path):
                self.activate()
                before = (pam.PAM_DIR / 'gdm-password').read_bytes()
                child = subprocess.Popen([sys.executable, '-c', code, str(path)], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, text=True)
                try:
                    self.assertEqual(child.stdout.readline().strip(), 'locked')
                    # Bypass only recover.py's root entry-point check; fixture
                    # file ownership validation still uses the real test UID.
                    with patch.object(recover, 'os', SimpleNamespace(geteuid=lambda: 0)), \
                         contextlib.redirect_stderr(io.StringIO()):
                        for _ in range(7):
                            self.assertEqual(recover.main(), 1)
                            self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), before)
                            self.assertEqual(pam.status()['status'], 'pending')
                finally:
                    child.communicate('x', timeout=5)
                with patch.object(recover, 'os', SimpleNamespace(geteuid=lambda: 0)):
                    self.assertEqual(recover.main(), 0)
                self.assertEqual(pam.status()['status'], 'off')
                self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)


class GdmGuard(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)
        self.parent = self.proc / '42'
        self.parent.mkdir()
        self.worker = self.proc / 'gdm-session-worker'
        self.worker.write_bytes(b'fixture')
        self.worker.chmod(0o755)
        (self.parent / 'exe').symlink_to(self.worker)
        (self.parent / 'status').write_bytes(b'Name:\tgdm-session-worker\nUid:\t0\t0\t0\t0\n')
        (self.parent / 'environ').write_bytes(b'PATH=/usr/bin\0GDM_SESSION_FOR_REAUTH=1\0')

    def allowed(self, proc_owner=0, exe_owner=0):
        # Fixture files belong to the test runner, not root. Only metadata is
        # substituted: exercise the real fd-relative reads, symlinks and parser.
        real_stat = os.stat
        def executable_stat(*args, **kwargs):
            info = real_stat(*args, **kwargs)
            return SimpleNamespace(st_uid=exe_owner, st_mode=info.st_mode)
        with patch.object(pam_guard.os, 'fstat', return_value=SimpleNamespace(st_uid=proc_owner)), \
             patch.object(pam_guard.os, 'stat', side_effect=executable_stat):
            return pam_guard.gdm_unlock(42, self.proc, (str(self.worker),))

    def test_only_trusted_reauthentication_worker_is_allowed(self):
        self.assertTrue(self.allowed())
        self.assertFalse(self.allowed(proc_owner=1000))
        self.assertFalse(self.allowed(exe_owner=1000))
        self.worker.chmod(0o777)
        self.assertFalse(self.allowed())

    def test_initial_login_logout_and_reboot_need_no_stale_marker_cleanup(self):
        for environment in (b'', b'PATH=/usr/bin\0', b'GDM_SESSION_FOR_REAUTH=0\0',
                            b'GDM_SESSION_FOR_REAUTH=1suffix\0', b'XGDM_SESSION_FOR_REAUTH=1\0',
                            b'GDM_SESSION_FOR_REAUTH=1\0GDM_SESSION_FOR_REAUTH=0\0'):
            with self.subTest(environment=environment):
                (self.parent / 'environ').write_bytes(environment)
                # A spoofed helper environment must not unlock an initial-login
                # worker, including when another user/session is already open.
                with patch.dict(os.environ, {'GDM_SESSION_FOR_REAUTH': '1', 'XDG_SESSION_ID': '2'}):
                    self.assertFalse(self.allowed())

    def test_unprivileged_or_unfamiliar_process_cannot_claim_to_be_gdm(self):
        for uids in (b'1000 0 0 0', b'0 1000 0 0', b'0 0 1000 0', b'0 0 0 1000', b'0 0 0'):
            (self.parent / 'status').write_bytes(b'Uid:\t' + uids + b'\n')
            self.assertFalse(self.allowed())
        (self.parent / 'status').write_bytes(b'Uid:\t0 0 0 0\n')
        (self.parent / 'exe').unlink()
        (self.parent / 'exe').symlink_to('/usr/bin/python3')
        self.assertFalse(self.allowed())

    def test_missing_unreadable_oversized_or_symlinked_context_falls_back(self):
        (self.parent / 'environ').write_bytes(b'GDM_SESSION_FOR_REAUTH=1\0' + b'x' * 1024 * 1024)
        self.assertFalse(self.allowed())
        (self.parent / 'environ').unlink()
        self.assertFalse(self.allowed())
        (self.parent / 'environ').symlink_to(self.worker)
        self.assertFalse(self.allowed())
        with patch.object(pam_guard.os, 'open', side_effect=PermissionError):
            self.assertFalse(pam_guard.gdm_unlock(42))

    def test_entry_point_rejects_other_services_and_changed_parent(self):
        with patch.object(pam_guard.os, 'geteuid', return_value=0), \
             patch.object(pam_guard.os, 'getppid', return_value=42), \
             patch.object(pam_guard, 'gdm_unlock', return_value=True) as guard:
            with patch.dict(os.environ, {'PAM_SERVICE': 'sudo', 'PAM_TYPE': 'auth'}):
                self.assertEqual(pam_guard.main(), 1)
                guard.assert_not_called()
            with patch.dict(os.environ, {'PAM_SERVICE': 'gdm-password', 'PAM_TYPE': 'auth'}):
                self.assertEqual(pam_guard.main(), 0)
                with patch.object(pam_guard.os, 'getppid', side_effect=[42, 43]):
                    self.assertEqual(pam_guard.main(), 1)


class RecoveryExit(unittest.TestCase):
    def test_interactive_disable_preserves_recovery_exit_status_and_handles_confirmed_setup(self):
        for error, expected in ((pam.ReconciliationError('external edit'), 78),
                                (ValueError('unsafe backup'), 78), (OSError('busy'), 1), (None, 0)):
            with self.subTest(error=error), patch.object(recover.os, 'geteuid', return_value=0), \
                 patch.object(pam, 'rollback', side_effect=error) as rollback, \
                 patch.object(sys, 'argv', ['sensible-biometrics', 'pam-disable']), \
                 contextlib.redirect_stderr(io.StringIO()):
                if expected:
                    with self.assertRaises(SystemExit) as caught:
                        runpy.run_path(str(TOOLS / 'sensible-biometrics'), run_name='__main__')
                    self.assertEqual(caught.exception.code, expected)
                else:
                    runpy.run_path(str(TOOLS / 'sensible-biometrics'), run_name='__main__')
                rollback.assert_called_once_with(pending_only=False)

    def test_only_transient_errors_remain_retryable(self):
        for error, expected in ((pam.ReconciliationError('external edit'), 78),
                                (ValueError('invalid backup'), 78), (OSError('busy'), 1), (None, 0)):
            with self.subTest(error=error), patch.object(recover.os, 'geteuid', return_value=0), \
                 patch.object(pam, 'rollback', side_effect=error), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(recover.main(), expected)
        unit = pam.recovery_unit()
        self.assertIn(b'RestartPreventExitStatus=78\n', unit)
        # A persistent transient failure must not loop forever behind the
        # display-manager ordering; the burst limit lets it fail and release.
        self.assertIn(b'StartLimitBurst=5\n', unit)
        self.assertIn(b'StartLimitIntervalSec=120\n', unit)
        with patch.object(pam, 'install_recovery'), patch.object(pam.subprocess, 'run') as run:
            pam.arm_recovery()
            command = next(call.args[0] for call in run.call_args_list if call.args[0][0] == 'systemd-run')
            self.assertIn('--property=RestartPreventExitStatus=78', command)
            self.assertIn('--property=Restart=on-failure', command)
            self.assertIn('--property=RestartSec=5s', command)
            self.assertIn('--property=StartLimitIntervalSec=0', command)
            self.assertFalse(any(arg.startswith('--property=StartLimitBurst=') for arg in command))


class ResultChannel(unittest.TestCase):
    def test_result_is_separate_from_conversation_output(self):
        expected = {'start': 0, 'auth': 7, 'account': None, 'message': 'Authentication failure'}
        def child(command, **kwargs):
            self.assertEqual(command[-1], 'auth-only')
            fd = int(command[-2])
            self.assertEqual(kwargs['pass_fds'], (fd,))
            self.assertIs(kwargs['stdout'], sys.stderr)
            os.write(fd, json.dumps(expected).encode())
        with patch.object(pam_session.subprocess, 'run', side_effect=child):
            self.assertEqual(pam_session.run('fixture', 'fixture', account=False), expected)

    def test_malformed_result_is_not_authentication_evidence(self):
        def child(command, **kwargs): os.write(int(command[-2]), b'{"auth": 7}')
        with patch.object(pam_session.subprocess, 'run', side_effect=child), self.assertRaises(ValueError):
            pam_session.run('fixture', 'fixture')


class RealPam(unittest.TestCase):
    """Use pam_start_confdir; never create files in /etc/pam.d or touch credentials."""
    @classmethod
    def setUpClass(cls):
        if not shutil.which('cc') or not Path('/usr/include/security/pam_modules.h').exists():
            raise unittest.SkipTest('real PAM checks require a C compiler and libpam0g-dev')
        permit = Path('/usr/lib/x86_64-linux-gnu/security/pam_permit.so')
        if permit.exists() and permit.stat().st_uid != 0:
            raise unittest.SkipTest('sandbox remaps root-owned PAM modules; run these checks on the host')
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.addClassCleanup(cls.temp.cleanup)
        source = cls.root / 'module.c'
        source.write_text('#include <security/pam_modules.h>\n#include <stdlib.h>\n'
                          'int pam_sm_authenticate(pam_handle_t*p,int f,int n,const char**v){return n?atoi(v[0]):PAM_AUTH_ERR;}\n'
                          'int pam_sm_setcred(pam_handle_t*p,int f,int n,const char**v){return PAM_SUCCESS;}\n'
                          'int pam_sm_acct_mgmt(pam_handle_t*p,int f,int n,const char**v){return n?atoi(v[0]):PAM_AUTH_ERR;}\n')
        cls.module = cls.root / 'fixture.so'
        subprocess.run(['cc', '-shared', '-fPIC', str(source), '-o', str(cls.module)], check=True)
        cls.lib = ctypes.CDLL(ctypes.util.find_library('pam'))
        cls.lib.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_char_p,
                                             ctypes.POINTER(ctypes.c_void_p)]
        cls.lib.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
        cls.lib.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
        cls.lib.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
        cls.user = pwd.getpwuid(os.getuid()).pw_name

    def authenticate(self, face=0, password=7, account=0, target=None, prefix='', suffix='', missing_guard=False,
                     unlock=0, service='gdm-password', wallet=None):
        generated = pam.block(target or self.user, service).decode().replace('pam_howdy.so', f'{self.module} {face}' if face is not None else '/nonexistent/module.so')
        guard_command = f'pam_exec.so quiet quiet_log /usr/bin/python3 -I -B {pam.RECOVERY_DIR}/pam_guard.py'
        generated = generated.replace(guard_command, f'{self.module} {unlock}' if unlock is not None else '/nonexistent/guard.so')
        if missing_guard: generated = generated.replace('pam_succeed_if.so', '/nonexistent/guard.so')
        (self.root / 'check').write_text(prefix + generated + suffix + f'account required {self.module} {account}\n')
        common = KDE_COMMON if wallet is not None else COMMON
        common = common.decode().replace('pam_unix.so nullok', f'{self.module} {password}')
        common = common.replace('pam_kwallet5.so', f'{self.module} {wallet}')
        (self.root / 'common-auth').write_text(common)
        handle = ctypes.c_void_p()
        # No fixture module prompts. A non-NULL conversation structure is required.
        conversation = (ctypes.c_void_p * 2)()
        rc = self.lib.pam_start_confdir(b'check', self.user.encode(), conversation, str(self.root).encode(), ctypes.byref(handle))
        self.assertEqual(rc, 0)
        try:
            rc = self.lib.pam_authenticate(handle, 0)
            return self.lib.pam_acct_mgmt(handle, 0) if rc == 0 else rc
        finally:
            self.lib.pam_end(handle, rc)

    def test_face_success_skips_password_and_runs_account_checks(self):
        self.assertEqual(self.authenticate(), 0)
        self.assertNotEqual(self.authenticate(account=13), 0)

    def test_face_failure_and_missing_module_fall_back_to_password(self):
        for face in (7, 4, 25, None):
            with self.subTest(face=face):
                self.assertEqual(self.authenticate(face=face, password=0), 0)
                self.assertNotEqual(self.authenticate(face=face, password=7), 0)

    def test_other_account_and_missing_guard_cannot_use_face(self):
        self.assertNotEqual(self.authenticate(target='nobody'), 0)
        self.assertEqual(self.authenticate(target='nobody', password=0), 0)
        self.assertNotEqual(self.authenticate(missing_guard=True), 0)

    def test_initial_login_and_guard_errors_skip_a_successful_face_match(self):
        for unlock in (7, 4, 25, None):
            with self.subTest(unlock=unlock):
                self.assertNotEqual(self.authenticate(unlock=unlock, password=7), 0)
                self.assertEqual(self.authenticate(unlock=unlock, password=0), 0)

    def test_kde_and_sudo_do_not_depend_on_gdm_and_sddm_is_forbidden(self):
        for service in ('kde', 'sudo'):
            self.assertEqual(self.authenticate(service=service, unlock=7), 0)
            self.assertNotIn(b'pam_exec', pam.block(self.user, service))
        with self.assertRaises(ValueError): pam.block(self.user, 'sddm')

    def test_kde_wallet_hook_cannot_authenticate_or_veto_valid_authentication(self):
        for wallet in (0, 7, 25):
            with self.subTest(wallet=wallet):
                self.assertEqual(self.authenticate(service='kde', face=0, password=7, wallet=wallet), 0)
                self.assertEqual(self.authenticate(service='kde', face=7, password=0, wallet=wallet), 0)
                self.assertNotEqual(self.authenticate(service='kde', face=7, password=7, wallet=wallet), 0)
                self.assertNotEqual(self.authenticate(service='kde', account=13, wallet=wallet), 0)

    def test_real_guard_rejects_pamtester_context_even_with_spoofed_environment(self):
        # Execute the actual helper through libpam/pam_exec; this Python process
        # is not GDM. A successful face double must never be reached.
        with patch.object(pam, 'RECOVERY_DIR', TOOLS):
            generated = pam.block(self.user).decode().replace('pam_howdy.so', f'{self.module} 0')
        (self.root / 'gdm-password').write_text(generated)
        (self.root / 'common-auth').write_text('auth required pam_deny.so\n')
        with patch.dict(os.environ, {'GDM_SESSION_FOR_REAUTH': '1', 'PAM_SERVICE': 'gdm-password'}):
            result = pam_session.authenticate('gdm-password', self.user, account=False, confdir=self.root)
        self.assertNotEqual(result['auth'], 0)

    def test_required_restrictions_before_and_after_are_preserved(self):
        self.assertNotEqual(self.authenticate(prefix=f'auth required {self.module} 7\n'), 0)
        self.assertNotEqual(self.authenticate(suffix=f'auth required {self.module} 7\n'), 0)
        self.assertEqual(self.authenticate(suffix=f'auth optional {self.module} 7\n'), 0)

    def test_structured_runner_separates_authentication_and_account_results(self):
        (self.root / 'worker').write_text(f'auth required {self.module} 0\naccount required {self.module} 13\n')
        result = pam_session.authenticate('worker', self.user, confdir=self.root)
        self.assertEqual((result['start'], result['auth'], result['account']), (0, 0, 13))
        result = pam_session.authenticate('worker', self.user, account=False, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (0, None))
        # No argument: the compiled module returns the actual header's PAM_AUTH_ERR.
        (self.root / 'worker').write_text(f'auth required {self.module}\naccount required {self.module} 0\n')
        result = pam_session.authenticate('worker', self.user, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (pam.PAM_AUTH_ERR, None))
        self.assertTrue(pam.verification_result('reject', result)['ok'])

    def test_worker_process_delivers_structured_results_through_private_fd(self):
        (self.root / 'worker').write_text(f'auth required {self.module} 0\naccount required {self.module} 13\n')
        result = pam_session.run('worker', self.user, timeout=5, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (0, 13))
        result = pam_session.run('worker', self.user, timeout=5, account=False, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (0, None))


class FakeBackend:
    def __init__(self, fail=None, checks=(), results=None, report=None):
        self.calls, self.fail = [], fail
        self.active = False
        self.checks = list(checks)
        self.results = results or {}
        self.report = report or {'face': {'status': 'needs_verification'},
                                 'cameras': [{'capture': True, 'ir_candidate': True,
                                 'stable_paths': ['/dev/v4l/by-path/fixture'], 'name': 'IR', 'node': '/dev/video2'}]}
    def installed(self): return True
    def reusable_build(self): return False
    def desktop_services(self): return ['gdm-password']
    def run(self, *args, **kwargs):
        self.calls.append(args)
        if args[0] == self.fail: raise subprocess.CalledProcessError(1, args)
        if args[0] == 'pam-status': return {'status': 'pending' if self.active else 'off',
                                           'deadline': time.time() + 300}
        if args[0] == 'pam-enable': self.active = True
        if args[0] == 'verify-status': return {'checks': self.checks}
        if args[0] == 'verify':
            outcomes = self.results.get(args[1], [])
            return outcomes.pop(0) if outcomes else {'ok': True, 'reason': 'verified', 'message': 'Passed.'}
        if args[0] == 'probe': return self.report


class FakeUI:
    def __init__(self, answers, choices=()):
        self.answers, self.choices = iter(answers), iter(choices)
        self.messages, self.questions, self.steps = [], [], []
    def banner(self, title, *caption): self.messages.append(title)
    def step(self, number, title, detail=None): self.steps.append(number)
    def yes(self, text, **k):
        self.questions.append(text)
        return next(self.answers)
    def choose(self, title, options, default=0): return next(self.choices, len(options) - 1)
    def say(self, text, kind=None): self.messages.append(text)
    def pause(self, text): pass


class WizardFlow(unittest.TestCase):
    def execute(self, answers, backend, choices=()):
        ui = FakeUI(answers, choices)
        with patch.object(ops, 'target_user', return_value='fixture'), patch.object(wizard.os, 'geteuid', return_value=1000):
            wizard.setup(ui, backend)
        return ui

    def test_success_enables_only_after_verification_and_confirms_last(self):
        backend = FakeBackend()
        ui = self.execute([True, False, True, False, True, True, True, True], backend)
        self.assertEqual(ui.steps, [1, 2, 3, 4, 5, 6])
        self.assertTrue(any('run sudo without a password' in message for message in ui.messages),
                        'the sudo prompt must be preceded by a passwordless-root warning')
        self.assertTrue(any('cannot replace that first password login' in message for message in ui.messages),
                        'activation must explain password login after each boot or logout')
        calls = [c[0] for c in backend.calls]
        self.assertEqual([c[1] for c in backend.calls if c[0] == 'verify'], ['face'])
        self.assertLess(max(i for i, c in enumerate(calls) if c == 'verify'), calls.index('pam-enable'))
        self.assertLess(calls.index('pam-check'), calls.index('pam-confirm'))
        self.assertEqual(ui.questions[-3:], ['Did the lock screen unlock using your face?',
                                             'Did your password unlock the screen with your face out of view?',
                                             'Keep face login enabled?'])
        self.assertNotIn('pam-disable', calls)

    def test_failed_face_check_never_activates(self):
        backend = FakeBackend(results={'face': [{'ok': False, 'reason': 'not_authenticated', 'message': 'Try again.'}]})
        with self.assertRaises(wizard.Cancelled): self.execute([True, False, True, False], backend)
        self.assertNotIn('pam-enable', [c[0] for c in backend.calls])

    def test_verification_process_error_allows_clean_stop(self):
        backend = FakeBackend(fail='verify')
        with self.assertRaises(wizard.Cancelled): self.execute([True, False, True, False], backend)
        self.assertNotIn('pam-enable', [c[0] for c in backend.calls])

    def test_declining_keep_and_service_failure_trigger_rollback(self):
        for fail, answers, expected in ((None, [True, False, True, False, True, False], wizard.Cancelled),
                                        ('pam-check', [True, False, True, False, True], subprocess.CalledProcessError)):
            backend = FakeBackend(fail=fail)
            with self.assertRaises(expected): self.execute(answers, backend)
            self.assertEqual(backend.calls[-1][0], 'pam-disable')

    def test_failed_recovery_distinguishes_reconciliation_from_transient_errors(self):
        for error in (subprocess.CalledProcessError(78, ['pam-disable']),
                      subprocess.CalledProcessError(1, ['pam-disable']), OSError('could not launch')):
            with self.subTest(error=error):
                backend = FakeBackend()
                original = backend.run
                def fail_recovery(*args, **kwargs):
                    result = original(*args, **kwargs)
                    if args[0] == 'pam-disable':
                        raise error
                    return result
                backend.run = fail_recovery
                ui = FakeUI([True, False, True, False, True, False])
                with patch.object(ops, 'target_user', return_value='fixture'), \
                     patch.object(wizard.os, 'geteuid', return_value=1000), self.assertRaises(wizard.Cancelled):
                    wizard.setup(ui, backend)
                messages = '\n'.join(ui.messages)
                self.assertIn('/var/lib/sensible-biometrics/pam.json', messages)
                self.assertIn('journalctl -u sensible-biometrics-rollback.service', messages)
                if getattr(error, 'returncode', None) == 78:
                    self.assertIn('Recovery requires manual reconciliation', messages)
                    self.assertIn('waiting or rebooting will not resolve it', messages)
                else:
                    self.assertIn('retries temporary package-lock or I/O failures', messages)
                    self.assertIn('restoration is not guaranteed', messages)
                self.assertNotIn('wait five minutes or reboot to restore', messages)
                self.assertNotIn('pam-confirm', [c[0] for c in backend.calls])

    def test_bad_camera_stops_before_enrollment(self):
        backend = FakeBackend()
        with self.assertRaises(wizard.Cancelled): self.execute([True, False, False, False], backend)
        self.assertNotIn('enroll', [c[0] for c in backend.calls])

    def test_unreadable_peer_blocks_configuration_despite_readable_ir_candidate(self):
        backend = FakeBackend()
        backend.report['face']['status'] = 'incomplete'
        with self.assertRaises(ValueError): self.execute([True, False], backend)
        self.assertNotIn('configure', [c[0] for c in backend.calls])
        self.assertNotIn('enroll', [c[0] for c in backend.calls])

    def test_camera_menu_does_not_emit_device_control_sequences(self):
        backend = FakeBackend()
        camera = backend.report['cameras'][0]
        camera['name'] = 'IR\x1b[2J\nInjected text'
        backend.report['cameras'].append(dict(camera, name='Second camera', node='/dev/video4'))
        ui = FakeUI([True, False])
        with patch.object(ui, 'choose', return_value=0) as choose:
            wizard.check_camera_and_enroll(ui, backend, 'fixture')
        self.assertEqual(choose.call_args.args[1], ['/dev/video2', 'Second camera'])

    def test_face_check_retry_keeps_enrollment(self):
        backend = FakeBackend(results={'face': [{'ok': False, 'reason': 'not_authenticated', 'message': 'No match.'}]})
        self.execute([True, False, True, False, True, True, True, True], backend, choices=[0])
        self.assertEqual([c[1] for c in backend.calls if c[0] == 'verify'], ['face', 'face'])
        self.assertEqual(sum(c[0] == 'enroll' for c in backend.calls), 1)
        self.assertEqual(backend.calls[-1][0], 'pam-confirm')

    def test_failed_face_checks_can_open_preview_or_stop(self):
        bad = {'ok': False, 'reason': 'not_authenticated', 'message': 'No match.'}
        backend = FakeBackend(results={'face': [bad, bad]})
        with self.assertRaises(wizard.Cancelled):
            self.execute([True, False, True, False], backend, choices=[1, 2])
        self.assertEqual(sum(c[0] == 'preview' for c in backend.calls), 2)
        self.assertNotIn('pam-enable', [c[0] for c in backend.calls])

    def test_resume_skips_completed_camera_enrollment_and_face_check(self):
        backend = FakeBackend(checks=['face'])
        ui = self.execute([True, False, True, True, True, True], backend, choices=[0])
        self.assertEqual(ui.steps, [1, 3, 4, 5, 6])
        self.assertNotIn('enroll', [c[0] for c in backend.calls])
        self.assertNotIn('preview', [c[0] for c in backend.calls])
        self.assertEqual([c[1] for c in backend.calls if c[0] == 'verify'], [])

    def test_each_final_confirmation_can_restore_previous_login(self):
        for final in ([False], [True, False], [True, True, False]):
            with self.subTest(final=final):
                backend = FakeBackend()
                with self.assertRaises(wizard.Cancelled):
                    self.execute([True, False, True, False, True, *final], backend)
                self.assertEqual(backend.calls[-1][0], 'pam-disable')
                self.assertNotIn('pam-confirm', [c[0] for c in backend.calls])


class InstallLayout(unittest.TestCase):
    """A packaged install never compiles; a checkout reuses only a validated build."""

    def run_setup(self, layout, backend):
        with patch.object(wizard, 'HERE', layout), patch.object(ops, 'target_user', return_value='fixture'), \
             patch.object(wizard.os, 'geteuid', return_value=1000):
            wizard.setup(FakeUI([True, False]), backend)

    def test_missing_package_without_build_recipe_explains_supported_recovery(self):
        backend = FakeBackend()
        backend.installed = lambda: False
        with tempfile.TemporaryDirectory() as baked:
            with self.assertRaises(ValueError) as caught:
                self.run_setup(Path(baked), backend)
        self.assertIn('Debian APT does not provide it', str(caught.exception))
        self.assertIn('matching Sensible source checkout', str(caught.exception))
        self.assertIn('deps, then build, then install', str(caught.exception))
        self.assertFalse({'deps', 'build', 'install'} & {c[0] for c in backend.calls})

    def test_checkout_without_package_builds_then_installs(self):
        backend = FakeBackend()
        backend.installed = lambda: False
        with tempfile.TemporaryDirectory() as checkout:
            (Path(checkout) / 'build.py').write_text('')
            with self.assertRaises(StopIteration):  # The fake runs out of answers after the build steps.
                self.run_setup(Path(checkout), backend)
        calls = [c[0] for c in backend.calls]
        self.assertEqual([c for c in calls if c in ('deps', 'build', 'install')], ['deps', 'build', 'install'])

    def test_checkout_cache_uses_real_build_validation_without_version_bump(self):
        for change in ('none', 'pins', 'patch', 'packaging', 'artifact', 'missing', 'manifest'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as checkout:
                root = Path(checkout)
                tools = root / 'tools/biometrics'
                shutil.copytree(TOOLS, tools, ignore=shutil.ignore_patterns('__pycache__'))
                inputs = subprocess.check_output([sys.executable, '-B', str(tools / 'build.py'), 'inputs'],
                                                 text=True).strip()
                dist = root / '.build/biometrics/dist'
                dist.mkdir(parents=True)
                package = dist / 'howdy-next.deb'
                package.write_bytes(b'fixture package')
                pins = json.loads((tools / 'sources.json').read_text())
                manifest = {'package': package.name, 'sha256': ops.sha(package.read_bytes()),
                            'sources': pins, 'inputs': inputs}
                (dist / 'build.json').write_text(json.dumps(manifest))
                if change == 'pins':
                    pins['howdy']['sha256'] = 'changed without a version bump'
                    (tools / 'sources.json').write_text(json.dumps(pins))
                elif change == 'patch':
                    (tools / 'patches/new.patch').write_text('new patch')
                elif change == 'packaging':
                    (tools / 'debian/rules').write_text('changed packaging')
                elif change == 'artifact':
                    package.write_bytes(b'changed artifact')
                elif change == 'missing':
                    package.unlink()
                elif change == 'manifest':
                    (dist / 'build.json').write_text('{')
                backend = FakeBackend()
                backend.installed = lambda: False
                backend.reusable_build = wizard.Backend().reusable_build
                with self.assertRaises(StopIteration):  # Stop at the first camera prompt.
                    self.run_setup(tools, backend)
                expected = ['install'] if change == 'none' else ['deps', 'build', 'install']
                self.assertEqual([c[0] for c in backend.calls if c[0] in ('deps', 'build', 'install')], expected)

    def test_failed_rebuild_does_not_install_stale_package_or_enroll(self):
        backend = FakeBackend(fail='build')
        backend.installed = lambda: False
        with tempfile.TemporaryDirectory() as checkout:
            (Path(checkout) / 'build.py').write_text('')
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_setup(Path(checkout), backend)
        self.assertFalse({'install', 'configure', 'enroll', 'pam-enable'} & {c[0] for c in backend.calls})


class TerminalPrompts(unittest.TestCase):
    """The real Terminal keeps plain stdin semantics under any styling."""

    def terminal(self, replies):
        terminal = wizard.Terminal(tui.Style(color=True, unicode=True, width=80))
        prompts = []
        def fake_input(prompt=''):
            prompts.append(prompt)
            return replies.pop(0)
        return terminal, prompts, fake_input

    def test_yes_defaults_and_accepts_only_yes_words(self):
        terminal, prompts, fake_input = self.terminal(['', 'Y', 'no', 'yes'])
        with patch('builtins.input', fake_input), contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(terminal.yes('Start setup?', default=True))
            self.assertTrue(terminal.yes('Keep?'))
            self.assertFalse(terminal.yes('Keep?', default=True))
            self.assertTrue(terminal.yes('Keep?'))
        self.assertIn('Start setup?', prompts[0])
        self.assertIn('[Y/n]', prompts[0])
        self.assertIn('[y/N]', prompts[1])

    def test_choose_rejects_out_of_range_then_returns_index(self):
        terminal, prompts, fake_input = self.terminal(['9', 'x', '2', ''])
        out = io.StringIO()
        with patch('builtins.input', fake_input), contextlib.redirect_stdout(out):
            self.assertEqual(terminal.choose('Pick', ['First', 'Second']), 1)
            self.assertEqual(terminal.choose('Pick', ['First', 'Second'], default=1), 1)
        self.assertEqual(len(prompts), 4)
        self.assertIn('Enter one of the numbers shown.', out.getvalue())
        self.assertIn('1.', out.getvalue())
        self.assertIn('Second', out.getvalue())


if __name__ == '__main__':
    unittest.main()
