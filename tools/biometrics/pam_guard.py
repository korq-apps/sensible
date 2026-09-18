"""Allow Howdy in GDM's reauthentication worker, never its initial-login worker.

GDM sets GDM_SESSION_FOR_REAUTH in the worker's *process* environment, not
the PAM environment. pam_exec does not forward it. Read the verified parent's
initial environment through procfs instead of trusting caller-supplied PAM
variables. No password, keyring secret or persistent login marker is needed.
"""
import os
from pathlib import Path
import stat
import sys


WORKERS = ('/usr/libexec/gdm-session-worker', '/usr/lib/gdm3/gdm-session-worker',
           '/usr/lib/gdm/gdm-session-worker')


def gdm_unlock(parent, proc=Path('/proc'), workers=WORKERS):
    """Missing, unfamiliar or unreadable context always selects password auth."""
    try:
        # Opening the directory pins this proc entry against PID reuse. The
        # calling PAM process is synchronously waiting for pam_exec to finish.
        fd = os.open(proc / str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != 0:
                return False
            executable = os.readlink('exe', dir_fd=fd)
            if executable not in workers:
                return False
            info = os.stat('exe', dir_fd=fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                return False
            status_fd = os.open('status', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
            with os.fdopen(status_fd, 'rb') as stream:
                status = stream.read(65536)
            # Require real/effective/saved/fs UIDs all root. A user launching a
            # GDM binary with a forged environment is not a trusted worker.
            uids = [line.split()[1:] for line in status.splitlines() if line.startswith(b'Uid:')]
            if uids != [[b'0', b'0', b'0', b'0']]:
                return False
            env_fd = os.open('environ', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
            with os.fdopen(env_fd, 'rb') as stream:
                environment = stream.read(1024 * 1024 + 1)
            if len(environment) > 1024 * 1024:
                return False
            markers = [entry for entry in environment.split(b'\0')
                       if entry.startswith(b'GDM_SESSION_FOR_REAUTH=')]
            return markers == [b'GDM_SESSION_FOR_REAUTH=1']
        finally:
            os.close(fd)
    except (OSError, ValueError):
        return False


def main():
    # These PAM fields narrow the call site; they are not authentication proof.
    if os.geteuid() != 0 or os.environ.get('PAM_TYPE') != 'auth' or os.environ.get('PAM_SERVICE') != 'gdm-password':
        return 1
    parent = os.getppid()
    return 0 if gdm_unlock(parent) and os.getppid() == parent else 1


if __name__ == '__main__':
    sys.exit(main())
