"""Account-scoped PAM activation with persistent backups and independent recovery."""
import base64
import configparser
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

import local_ops as ops

PAM_DIR = Path('/etc/pam.d')
RECOVERY_DIR = Path('/usr/local/lib/sensible-biometrics')
UNIT = Path('/etc/systemd/system/sensible-biometrics-recover.service')
SERVICES = {'gdm-password': 'GNOME login and screen unlock',
            'sddm': 'KDE login', 'kde': 'KDE screen unlock', 'sudo': 'Administrator commands (sudo)'}
BEGIN = '# BEGIN sensible-biometrics v1\n'
END = '# END sensible-biometrics v1\n'
WINDOW = 300
PROOF_AGE = 900


def read_json(name):
    path = ops.STATE / name
    return json.loads(ops.checked_read(path)[0]) if path.exists() else None


def write_json(name, value):
    ops.atomic_write(ops.STATE / name, (json.dumps(value, indent=2) + '\n').encode(), 0o600)


def statements(data):
    return [' '.join(line.split()) for line in data.decode().splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def validate_password_stack():
    data = ops.checked_read(PAM_DIR / 'common-auth')[0]
    lines = statements(data)
    # Do not turn a site-specific MFA/domain/lockout policy into face OR password.
    if len(lines) != 3 or not re.fullmatch(
        r'auth \[success=1 default=ignore\] pam_unix\.so(?: (?:nullok|try_first_pass))*', lines[0]
    ) or lines[1:] != ['auth requisite pam_deny.so', 'auth required pam_permit.so']:
        raise ValueError('The existing authentication policy needs a dedicated adapter. '
                         'Automatic setup supports the standard Debian local-password stack.')
    return data


def block(user):
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*[$]?', user):
        raise ValueError('Account name cannot be represented safely in PAM')
    # A substack counts as ONE jump target and keeps required failures sticky.
    # The final permit establishes success after a jump; it cannot erase failures.
    return (BEGIN + f'auth [success=ignore default=1] pam_succeed_if.so quiet user = {user}\n'
            '-auth [success=1 default=ignore] pam_howdy.so\n'
            'auth substack common-auth\n'
            'auth required pam_permit.so\n' + END).encode()


def proposed(data, user):
    text = data.decode()
    if 'sensible-biometrics' in text or 'pam_howdy' in text or 'pam_python' in text or '\\\n' in text:
        raise ValueError('Existing biometric/custom PAM configuration needs reconciliation')
    includes = list(re.finditer(r'^@include[ \t]+common-auth[ \t]*\n', text, re.M))
    if len(includes) != 1:
        raise ValueError('Expected exactly one @include common-auth in this service')
    if statements(data).count('@include common-account') != 1:
        raise ValueError('Expected the existing common-account checks in this service')
    for line in statements(data):
        if line.startswith('@include '):
            if line not in ('@include common-auth', '@include common-account', '@include common-session',
                            '@include common-session-noninteractive', '@include common-password'):
                raise ValueError('An unfamiliar PAM include needs review')
        elif line.startswith(('auth ', '-auth ')):
            if not re.fullmatch(r'auth (?:required|requisite) pam_nologin\.so', line) and not re.fullmatch(
                r'auth required pam_succeed_if\.so user != root (?:quiet_success|quiet)', line
            ) and not re.fullmatch(r'auth optional pam_(?:gnome_keyring|kwallet5|kwallet6)\.so(?: auto_start)?', line):
                raise ValueError('An unfamiliar service authentication rule needs review')
    match = includes[0]
    replacement = block(user)
    return text[:match.start()].encode() + replacement + text[match.end():].encode(), match[0].encode()


def service_plan(user, services):
    if not services or len(set(services)) != len(services) or any(s not in SERVICES for s in services):
        raise ValueError('Choose supported desktop services or sudo')
    ops.check_directory(PAM_DIR)
    validate_password_stack()
    plan = {}
    for name in services:
        original, info = ops.checked_read(PAM_DIR / name)
        updated, include = proposed(original, user)
        plan[name] = {'original': base64.b64encode(original).decode(),
                      'include': include.decode(), 'block': block(user).decode(),
                      'before_sha256': ops.sha(original), 'after_sha256': ops.sha(updated),
                      'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}
    return plan


def fingerprint(user):
    config, _ = ops.checked_read(ops.CONFIG)
    parsed = configparser.ConfigParser(interpolation=None)
    parsed.read_string(config.decode())
    if parsed.getboolean('core', 'disabled', fallback=False):
        raise ValueError('Howdy is disabled in its configuration')
    timeout = parsed.getint('video', 'timeout')
    if not 1 <= timeout <= 20:
        raise ValueError('Set a bounded camera timeout before enabling login')
    model = ops.CONFIG.parent / 'models' / (user + '.dat')
    ops.check_directory(model.parent)
    result = {'verification_schema': 2, 'config': ops.sha(config), 'enrollment': ops.sha(ops.checked_read(model)[0]),
              'password_policy': ops.sha(validate_password_stack()),
              'account_policy': ops.sha(ops.checked_read(PAM_DIR / 'common-account')[0])}
    # Native binaries are larger than config files; check metadata and hash in chunks.
    import hashlib
    ops.check_directory(ops.PAM_MODULE.parent)
    fd = os.open(ops.PAM_MODULE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('PAM module is not owner-controlled')
        result['module'] = hashlib.file_digest(stream, 'sha256').hexdigest()
    return result


def verification_result(kind, result):
    if result['start'] != 0 or result['auth'] not in (0, 7):
        return {'ok': False, 'reason': 'unavailable',
                'message': 'The authentication check could not finish normally. ' + result['message']}
    if kind == 'reject':
        if result['auth'] == 0:
            return {'ok': False, 'reason': 'unexpected_match',
                    'message': 'Howdy reported a face match, so this diagnostic did not confirm rejection. '
                               'To retry, move completely out of view. This optional diagnostic does not change login settings.'}
        return {'ok': True, 'reason': 'rejected',
                'message': 'No face was accepted. This is the expected result — the optional no-face diagnostic passed.'}
    if result['auth'] != 0:
        return {'ok': False, 'reason': 'not_authenticated',
                'message': 'No face match was found. Look at the camera and try again.'}
    if result['account'] != 0:
        return {'ok': False, 'reason': 'account_denied',
                'message': 'Authentication succeeded, but the account check did not allow login. ' + result['message']}
    return {'ok': True, 'reason': 'verified', 'message': 'Face recognition passed.'}


def verify(user, kind, timeout=45, delay=0):
    if kind not in ('face', 'reject'):
        raise ValueError('Unknown verification step')
    with ops.locked_state():
        before = fingerprint(user)
        proof = read_json('verified.json')
        if not proof or proof['user'] != user or proof['fingerprint'] != before:
            proof = {'user': user, 'fingerprint': before, 'checks': {}}
        # Clear a previous pass BEFORE attempting another check, including cancellation.
        proof['checks'].pop(kind, None)
        write_json('verified.json', proof)
        if kind == 'reject' and time.time() - proof['checks'].get('face', 0) > PROOF_AGE:
            return {'ok': False, 'reason': 'face_check_required',
                    'message': 'Repeat the face recognition check before the no-face check.'}
        if not 0 <= delay <= 10:
            raise ValueError('Verification countdown must be between 0 and 10 seconds')
        for remaining in range(delay, 0, -1):
            print(f'No-face scan starts in {remaining}…', file=sys.stderr, flush=True)
            time.sleep(1)
        if delay:
            print('Scanning now. Stay out of view until the result appears.', file=sys.stderr, flush=True)
        try:
            result = ops.run_pam_service(ops.PAM_FACE, user, timeout, structured=True, account=kind != 'reject')
        except subprocess.TimeoutExpired:
            return {'ok': False, 'reason': 'timeout',
                    'message': 'The test process stopped responding. Check the camera and retry; this does not count as a pass.'}
        outcome = verification_result(kind, result)
        if not outcome['ok']:
            return outcome
        if fingerprint(user) != before:
            raise ValueError('Configuration changed during verification; repeat the checks')
        proof['checks'][kind] = time.time()
        write_json('verified.json', proof)
        return outcome


def require_proof(user):
    proof = read_json('verified.json')
    now = time.time()
    if not proof or proof['user'] != user or proof['fingerprint'] != fingerprint(user) or not (
        0 <= now - proof['checks'].get('face', 0) < PROOF_AGE
    ):
        raise ValueError('Complete a fresh face check before activation')
    return proof['fingerprint']


def verification_status(user):
    with ops.locked_state():
        proof = read_json('verified.json')
        if not proof or proof['user'] != user:
            return {'checks': []}
        try:
            unchanged = proof['fingerprint'] == fingerprint(user)
        except (OSError, ValueError):
            unchanged = False
        now = time.time()
        return {'checks': [kind for kind in ('face', 'reject') if unchanged
                           and 0 <= now - proof['checks'].get(kind, 0) < PROOF_AGE]}


def recovery_unit():
    return ('# Managed by sensible-biometrics\n[Unit]\nDescription=Undo unconfirmed face login setup\n'
            'After=local-fs.target\nBefore=display-manager.service\n'
            '[Service]\nType=oneshot\nRestart=on-failure\nRestartSec=5s\nExecStart=/usr/bin/python3 -Es '
            f'{RECOVERY_DIR}/recover.py\n[Install]\nWantedBy=multi-user.target\n').encode()


def install_recovery():
    if not Path('/run/systemd/system').is_dir():
        raise ValueError('Automatic rollback requires a running systemd system instance')
    ops.check_directory(RECOVERY_DIR.parent)
    RECOVERY_DIR.mkdir(mode=0o755, exist_ok=True)
    ops.check_directory(RECOVERY_DIR)
    here = Path(__file__).resolve().parent
    for name in ('local_ops.py', 'pam_ops.py', 'recover.py'):
        dest = RECOVERY_DIR / name
        if dest.exists():
            ops.checked_read(dest)
        ops.atomic_write(dest, (here / name).read_bytes(), 0o644, 0, 0)
    unit = recovery_unit()
    ops.check_directory(UNIT.parent)
    if UNIT.exists() and ops.checked_read(UNIT)[0] != unit:
        raise ValueError('Recovery service name is already used by another configuration')
    ops.atomic_write(UNIT, unit, 0o644, 0, 0)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', UNIT.name], check=True)


def arm_recovery():
    install_recovery()
    subprocess.run(['systemctl', 'stop', 'sensible-biometrics-rollback.timer',
                    'sensible-biometrics-rollback.service'], check=False, capture_output=True)
    subprocess.run(['systemctl', 'reset-failed', 'sensible-biometrics-rollback.service'],
                   check=False, capture_output=True)
    subprocess.run(['systemd-run', '--quiet', '--collect', '--unit=sensible-biometrics-rollback',
                    f'--on-active={WINDOW}s', '--timer-property=AccuracySec=1s',
                    '--property=Restart=on-failure', '--property=RestartSec=5s',
                    '/usr/bin/python3', '-Es', str(RECOVERY_DIR / 'recover.py')], check=True)
    subprocess.run(['systemctl', 'is-active', '--quiet', 'sensible-biometrics-rollback.timer'], check=True)


def _rollback(state):
    errors = []
    for name, entry in state['files'].items():
        try:
            path = PAM_DIR / name
            current, info = ops.checked_read(path)
            original = base64.b64decode(entry['original'], validate=True)
            if ops.sha(current) == entry['before_sha256']:
                continue  # Also handles a crash before this file was written.
            if (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) != (entry['mode'], entry['uid'], entry['gid']):
                raise ValueError(f'{name}: permissions changed outside setup')
            if ops.sha(current) == entry['after_sha256']:
                restored = original
            elif current.count(entry['block'].encode()) == 1:
                # Preserve administrator edits outside our exact block.
                restored = current.replace(entry['block'].encode(), entry['include'].encode(), 1)
            else:
                raise ValueError(f'{name}: managed block changed; backup is retained in {ops.STATE}/pam.json')
            ops.atomic_write(path, restored, entry['mode'], entry['uid'], entry['gid'])
        except (OSError, ValueError) as error:
            errors.append(str(error))
    if errors:
        raise ValueError('; '.join(errors))
    (ops.STATE / 'pam.json').unlink(missing_ok=True)
    (ops.STATE / 'verified.json').unlink(missing_ok=True)
    print('Previous PAM configuration restored. Face login is off.')


def rollback(pending_only=False):
    with ops.locked_state():
        state = read_json('pam.json')
        if state and (not pending_only or state['status'] == 'pending'):
            _rollback(state)


def enable(user, services):
    with ops.locked_state():
        if read_json('pam.json'):
            raise ValueError('An activation already exists; confirm it or turn it off before reconfiguring')
        proof = require_proof(user)
        plan = service_plan(user, services)
        state = {'status': 'pending', 'user': user, 'fingerprint': proof, 'files': plan,
                 'deadline': time.time() + WINDOW, 'tested': []}
        write_json('pam.json', state)
        try:
            arm_recovery()  # No PAM writes until the independent timer is running.
            for name, entry in plan.items():
                path = PAM_DIR / name
                current, info = ops.checked_read(path)
                if ops.sha(current) != entry['before_sha256']:
                    raise ValueError(f'{name} changed during setup')
                updated, _ = proposed(current, user)
                ops.atomic_write(path, updated, entry['mode'], entry['uid'], entry['gid'])
        except BaseException:
            _rollback(state)
            raise
        print('Face login is enabled for testing. Unconfirmed changes roll back in five minutes.')


def pending_state():
    state = read_json('pam.json')
    if not state or state['status'] != 'pending':
        raise ValueError('There is no pending activation')
    if time.time() >= state['deadline']:
        _rollback(state)
        raise ValueError('The test window expired; previous PAM configuration restored')
    if state['fingerprint'] != fingerprint(state['user']):
        raise ValueError('Authentication configuration changed; turn off and repeat setup')
    for name, entry in state['files'].items():
        data, info = ops.checked_read(PAM_DIR / name)
        if ops.sha(data) != entry['after_sha256'] or (
            stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid
        ) != (entry['mode'], entry['uid'], entry['gid']):
            raise ValueError(f'{name} changed after activation')
    return state


def check_services():
    # Release the state lock during prompts so timeout recovery cannot be blocked.
    with ops.locked_state():
        state = pending_state()
        state['tested'] = []
        write_json('pam.json', state)
    for name in state['files']:
        print(f'Testing {SERVICES[name]} — look at the camera.', flush=True)
        subprocess.run(['pamtester', name, state['user'], 'authenticate', 'acct_mgmt'], check=True, timeout=45)
        with ops.locked_state():
            current = pending_state()
            if current['deadline'] != state['deadline']:
                raise ValueError('Activation changed during the test')
            current['tested'].append(name)
            write_json('pam.json', current)


def confirm():
    with ops.locked_state():
        state = pending_state()
        if set(state['tested']) != set(state['files']):
            raise ValueError('Test each selected PAM service before keeping the change')
        state['status'] = 'active'
        write_json('pam.json', state)
        # A timer racing this write sees active and leaves confirmed settings alone.
        print('Face login enabled. Password fallback remains available.')


def status():
    with ops.locked_state():
        state = read_json('pam.json')
        return {'status': state['status'] if state else 'off',
                'services': list(state['files']) if state else [],
                'user': state['user'] if state else None,
                'deadline': state.get('deadline') if state else None}
