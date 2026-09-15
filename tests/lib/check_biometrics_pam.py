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
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / 'tools/biometrics'
sys.path.insert(0, str(TOOLS))
import local_ops as ops
import pam_ops as pam
import pam_session
import tui
import wizard

COMMON = b'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n'
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
        with self.assertRaises(ValueError): pam.proposed(SERVICE.replace(b'@include common-account\n', b''), 'fixture')
        with self.assertRaises(ValueError): pam.proposed(SERVICE + b'auth required pam_faillock.so\n', 'fixture')
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)

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

    def test_rollback_retry_after_partial_recovery(self):
        self.activate(('gdm-password', 'sudo'))
        original = ops.atomic_write
        def fail(path, *a, **kw):
            if path.name == 'sudo': raise OSError('temporarily read-only')
            return original(path, *a, **kw)
        with patch.object(ops, 'atomic_write', side_effect=fail), self.assertRaises(ValueError): pam.rollback()
        self.assertEqual((pam.PAM_DIR / 'gdm-password').read_bytes(), SERVICE)
        pam.rollback()
        self.assertEqual(pam.status()['status'], 'off')


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

    def authenticate(self, face=0, password=7, account=0, target=None, prefix='', suffix='', missing_guard=False):
        generated = pam.block(target or self.user).decode().replace('pam_howdy.so', f'{self.module} {face}' if face is not None else '/nonexistent/module.so')
        if missing_guard: generated = generated.replace('pam_succeed_if.so', '/nonexistent/guard.so')
        (self.root / 'check').write_text(prefix + generated + suffix + f'account required {self.module} {account}\n')
        (self.root / 'common-auth').write_text(f'auth [success=1 default=ignore] {self.module} {password}\n'
                                               'auth requisite pam_deny.so\nauth required pam_permit.so\n')
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
        (self.root / 'worker').write_text(f'auth required {self.module} 7\naccount required {self.module} 0\n')
        result = pam_session.authenticate('worker', self.user, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (7, None))
        self.assertTrue(pam.verification_result('reject', result)['ok'])

    def test_worker_process_delivers_structured_results_through_private_fd(self):
        (self.root / 'worker').write_text(f'auth required {self.module} 0\naccount required {self.module} 13\n')
        result = pam_session.run('worker', self.user, timeout=5, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (0, 13))
        result = pam_session.run('worker', self.user, timeout=5, account=False, confdir=self.root)
        self.assertEqual((result['auth'], result['account']), (0, None))


class FakeBackend:
    def __init__(self, fail=None, checks=(), results=None):
        self.calls, self.fail = [], fail
        self.active = False
        self.checks = list(checks)
        self.results = results or {}
    def installed(self): return True
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
        if args[0] == 'probe': return {'cameras': [{'capture': True, 'ir_candidate': True,
                                                  'stable_paths': ['/dev/v4l/by-path/fixture'], 'name': 'IR'}]}


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

    def test_bad_camera_stops_before_enrollment(self):
        backend = FakeBackend()
        with self.assertRaises(wizard.Cancelled): self.execute([True, False, False, False], backend)
        self.assertNotIn('enroll', [c[0] for c in backend.calls])

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
