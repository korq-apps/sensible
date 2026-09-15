"""One-launch guided terminal flow; passwords stay with sudo/PAM, never Python input."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from pam_ops import SERVICES
import tui

HERE = Path(__file__).resolve().parent
CLI = HERE / 'sensible-biometrics'
TITLE = 'Face Login Setup'
STEPS = 6


class Cancelled(Exception):
    pass


class Terminal:
    """Presentation goes through tui; every prompt still reads plain stdin."""

    def __init__(self, style=None):
        self.style = style or tui.Style()

    def banner(self, title, *caption):
        tui.banner(self.style, title, *caption)

    def step(self, number, title, detail=None):
        tui.step(self.style, number, STEPS, title, detail)

    def say(self, message, kind=None):
        tui.say(self.style, message, kind)

    def yes(self, question, default=False):
        answer = input(tui.prompt_text(self.style, question, '[Y/n]' if default else '[y/N]')).strip().lower()
        if not answer:
            return default
        return answer in ('yes', 'y')

    def choose(self, title, options, default=0):
        self.say(title)
        for number, option in enumerate(options, 1):
            print(tui.GUTTER + '  ' + self.style.paint(f'{number}.', 'cyan', 'bold') + ' ' + option, flush=True)
        while True:
            value = input(tui.prompt_text(self.style, 'Choose', f'[default {default + 1}]')).strip()
            if not value:
                return default
            if value.isdigit() and 1 <= int(value) <= len(options):
                return int(value) - 1
            self.say('Enter one of the numbers shown.', kind='warn')

    def pause(self, text):
        self.say(text)
        input(tui.prompt_text(self.style, 'Press Enter to continue.'))


class Backend:
    def run(self, *args, root=False, capture=False):
        # -B keeps root from writing bytecode caches into the user's checkout.
        command = [sys.executable, '-B', str(CLI), *map(str, args)]
        if root:
            command = ['sudo', '--', *command]
        result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture else None)
        return json.loads(result.stdout) if capture else None

    def installed(self):
        result = subprocess.run(['dpkg-query', '-W', '-f=${Version} ${Status}', 'howdy-next'],
                                text=True, capture_output=True)
        pins = json.loads((HERE / 'sources.json').read_text())
        return result.returncode == 0 and result.stdout == pins['version'] + ' install ok installed'

    def desktop_services(self):
        path = Path('/etc/X11/default-display-manager')
        dm = path.read_text().strip() if path.exists() else ''
        if Path(dm).name in ('gdm', 'gdm3'):
            return ['gdm-password']
        if Path(dm).name == 'sddm':
            return [s for s in ('sddm', 'kde') if (Path('/etc/pam.d') / s).is_file()]
        return []


def verify_step(ui, backend, user):
    """Isolated face check through a temporary PAM service; the password is out of scope here."""
    while True:
        ui.say('Face recognition', kind='info')
        ui.pause('Look at the camera. This test should accept your face without asking for a password.')
        try:
            result = backend.run('verify', 'face', '--user', user, '--json', root=True, capture=True)
        except subprocess.CalledProcessError:
            result = {'ok': False, 'reason': 'unavailable',
                      'message': 'The check could not run. Review the message above, then retry this step.'}
        ui.say(result['message'], kind='ok' if result['ok'] else 'fail')
        if result['ok']:
            return
        choice = ui.choose('How would you like to continue?',
                           ['Retry this check', 'Open camera preview', 'Stop setup and keep progress'])
        if choice == 2:
            raise Cancelled('Setup paused. Face login is still off. The fresh check and enrollment are kept.')
        if choice == 1:
            ui.say('Use this preview to check that your face is visible in the active camera. '
                   'Press Q to close it, then retry the check.', kind='info')
            try:
                backend.run('preview', '--user', user)
            except subprocess.CalledProcessError:
                ui.say('The preview could not open. Check camera privacy controls and close other camera apps.',
                       kind='warn')


def remaining_test_time(ui, backend):
    state = backend.run('pam-status', root=True, capture=True)
    remaining = int((state.get('deadline') or 0) - time.time())
    if state['status'] != 'pending' or remaining <= 0:
        raise Cancelled('The login test window ended. The changes will not be kept; run setup again to retry.')
    ui.say(f'Automatic rollback in {remaining // 60}:{remaining % 60:02d}.', kind='info')


def setup(ui=None, backend=None):
    ui, backend = ui or Terminal(), backend or Backend()
    if os.geteuid() == 0:
        raise ValueError('Launch setup from your normal desktop account. It requests sudo when needed.')
    import local_ops
    user = local_ops.target_user()
    ui.banner(TITLE, 'Sensible', 'Howdy-next face recognition', 'account ' + user)
    ui.say('Set up this account using your infrared camera. '
           'Keep your password: it remains your recovery method and may be needed for the keyring.')
    if not ui.yes('Start setup?', default=True):
        return
    state = backend.run('pam-status', root=True, capture=True)
    if state['status'] != 'off':
        choice = ui.choose('Face login is ' + state['status'] + '.',
                           ['Leave settings as they are', 'Turn off face login', 'Turn off and set up again'])
        if choice == 0:
            return
        backend.run('pam-disable', root=True)
        if choice == 1:
            return
    services = backend.desktop_services()
    if not services:
        raise ValueError('No supported GNOME/GDM or KDE/SDDM login service was detected.')
    if ui.yes('Also use face login for administrator commands (sudo)?'):
        services.append('sudo')
    service_args = [arg for service in services for arg in ('--service', service)]
    # Discover unsupported authentication policies before downloads or enrollment.
    backend.run('pam-plan', '--user', user, *service_args, root=True)
    ui.step(1, 'Install recognition software')
    if not backend.installed():
        ui.say('The first source build can take several minutes.', kind='info')
        if not (HERE.parents[1] / '.build/biometrics/dist/build.json').is_file():
            backend.run('deps')
            backend.run('build')  # build.py sizes --jobs from the CPU count.
        backend.run('install')
    else:
        ui.say('Recognition software is already installed.', kind='ok')
    backend.run('runtime-deps')
    saved = 'face' in backend.run('verify-status', '--user', user, root=True, capture=True)['checks']
    resume = saved and ui.choose('There is a fresh face check for this camera and enrollment.',
                                 ['Continue to login activation', 'Review camera and enrollment']) == 0
    if resume:
        ui.step(3, 'Camera and enrollment')
        ui.say('Keeping the verified camera configuration and saved enrollment.', kind='ok')
    else:
        check_camera_and_enroll(ui, backend, user)
    ui.step(4, 'Verify face recognition')
    if resume:
        ui.say('Face recognition already passed recently with these settings.', kind='ok')
    else:
        verify_step(ui, backend, user)
    ui.step(5, 'Enable and test login',
            'Use face login for: ' + ', '.join(SERVICES[s] for s in services) + '.')
    ui.say('Changes are automatically undone after five minutes unless you keep them. '
           'Closing this window or rebooting during the test also leaves recovery armed.', kind='warn')
    if not ui.yes('Enable face login for testing?'):
        raise Cancelled('Setup paused. Enrollment is saved locally; face login is still off.')
    activated = False
    try:
        backend.run('pam-enable', '--user', user, *service_args, root=True)
        activated = True
        backend.run('pam-check', root=True)
        ui.step(6, 'Check the lock screen',
                'Keep this setup window open. First lock the screen and unlock with your face. '
                'Return to this window afterwards.')
        remaining_test_time(ui, backend)
        if not ui.yes('Did the lock screen unlock using your face?'):
            raise Cancelled('Face unlock was not confirmed. Restoring the previous login settings.')
        ui.say('Next, lock the screen again and unlock using your password while the camera cannot see '
               'your face. Keep your face out of view, or use an opaque cover on the active lens '
               'identified in the preview. Return here after signing in.', kind='info')
        remaining_test_time(ui, backend)
        if not ui.yes('Did your password unlock the screen with your face out of view?'):
            raise Cancelled('Password fallback was not confirmed. Restoring the previous login settings.')
        remaining_test_time(ui, backend)
        if not ui.yes('Keep face login enabled?'):
            raise Cancelled('Face login was not kept. Restoring the previous login settings.')
        backend.run('pam-confirm', root=True)
        activated = False
        ui.say('Face login is ready. Open Face Login Setup again to turn it off or run setup again.', kind='ok')
    finally:
        if activated:
            try:
                backend.run('pam-disable', root=True)
            except (OSError, subprocess.CalledProcessError):
                ui.say('Immediate recovery could not run. The independent rollback timer is still armed; '
                       'wait five minutes or reboot to restore the previous login configuration.', kind='fail')


def check_camera_and_enroll(ui, backend, user):
    ui.step(2, 'Check the camera')
    report = backend.run('probe', '--json', root=True, capture=True)
    candidates = [c for c in report['cameras'] if c['capture'] and c['ir_candidate'] and c['stable_paths']]
    if not candidates:
        raise ValueError('No usable infrared camera was found. Check camera privacy controls and try again.')
    while True:
        selected = 0 if len(candidates) == 1 else ui.choose('Choose the infrared camera',
                    [c['name'] or c['node'] for c in candidates])
        camera = candidates[selected]
        backend.run('configure', '--device', camera['stable_paths'][0])
        backend.run('models')
        ui.say('A camera preview will open. Check that your face is clearly visible, '
               'then close the preview (Escape or Q).', kind='info')
        backend.run('preview', '--user', user)
        if ui.yes('Was the image clear and moving?'):
            break
        if not ui.yes('Try the camera check again?'):
            raise Cancelled('Camera setup paused. Login settings have not been enabled. '
                            'A dark image may require hardware-specific IR emitter support.')
    ui.step(3, 'Enroll your face')
    reuse = ui.yes('Have you already enrolled a face with this Howdy-next setup?')
    if reuse:
        backend.run('list', '--user', user)
        reuse = ui.yes('Use the existing enrollment?')
    if not reuse:
        backend.run('enroll', '--user', user)


def install_launcher():
    if os.geteuid() == 0:
        raise ValueError('Install the launcher as your normal desktop user')
    # Desktop Exec quoting is not shell quoting; percent escapes field codes.
    def quote(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'
    destination = Path.home() / '.local/share/applications/sensible-biometrics.desktop'
    destination.parent.mkdir(parents=True, exist_ok=True)
    content = ('[Desktop Entry]\nType=Application\nName=Face Login Setup\n'
               'Comment=Set up, test or turn off face login\nIcon=preferences-system-privacy\n'
               f'Exec={quote(sys.executable)} {quote(CLI)} setup --keep-open\n'
               'Terminal=true\nCategories=Settings;Security;\nStartupNotify=false\n')
    destination.write_text(content)
    destination.chmod(0o644)
    tui.say(tui.Style(), f'Installed {destination}. Open Face Login Setup from the applications menu.', 'ok')
    return destination
