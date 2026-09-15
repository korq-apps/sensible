"""Structured PAM results, with terminal conversation handled by libpam_misc."""
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def authenticate(service, user, *, account=True, confdir=None):
    pam = ctypes.CDLL(ctypes.util.find_library('pam'))
    misc = ctypes.CDLL(ctypes.util.find_library('pam_misc'))

    class Conversation(ctypes.Structure):
        _fields_ = [('conv', ctypes.c_void_p), ('data', ctypes.c_void_p)]

    # The C conversation owns password input/echo suppression. Python only sees
    # PAM status codes; no password passes through a Python callback or result.
    conversation = Conversation(ctypes.cast(misc.misc_conv, ctypes.c_void_p), None)
    handle = ctypes.c_void_p()
    signature = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(Conversation)]
    pam.pam_start.argtypes = [*signature, ctypes.POINTER(ctypes.c_void_p)]
    pam.pam_start_confdir.argtypes = [*signature, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    pam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_strerror.restype = ctypes.c_char_p
    args = [service.encode(), user.encode(), ctypes.byref(conversation)]
    if confdir is None:
        start = pam.pam_start(*args, ctypes.byref(handle))
    else:
        start = pam.pam_start_confdir(*args, os.fsencode(confdir), ctypes.byref(handle))
    result = {'start': start, 'auth': None, 'account': None}
    status = start
    try:
        if start == 0:
            status = result['auth'] = pam.pam_authenticate(handle, 0)
            if status == 0 and account:
                status = result['account'] = pam.pam_acct_mgmt(handle, 0)
        result['message'] = pam.pam_strerror(handle, status).decode(errors='replace')
        return result
    finally:
        if handle.value:
            pam.pam_end(handle, status)


def run(service, user, timeout=45, account=True, *, confdir=None):
    # A private inherited descriptor carries the result separately from the
    # interactive conversation. PAM/Howdy output remains visible on stderr.
    with tempfile.TemporaryFile() as result_file:
        command = [sys.executable, '-Es', str(Path(__file__).resolve()), service, user,
                   str(result_file.fileno()), 'account' if account else 'auth-only']
        if confdir is not None:
            command.append(str(Path(confdir).resolve()))
        subprocess.run(command,
                       pass_fds=(result_file.fileno(),), check=True, timeout=timeout,
                       stdout=sys.stderr)
        result_file.seek(0)
        result = json.loads(result_file.read(8192))
    if not isinstance(result, dict) or type(result.get('start')) is not int or any(
        key not in result or type(result[key]) not in (int, type(None)) for key in ('auth', 'account')
    ) or not isinstance(result.get('message'), str):
        raise ValueError('Invalid result from the authentication check')
    return result


if __name__ == '__main__':
    service, user, descriptor, mode = sys.argv[1:5]
    confdir = sys.argv[5] if len(sys.argv) == 6 else None
    result = authenticate(service, user, account=mode == 'account', confdir=confdir)
    with os.fdopen(int(descriptor), 'w') as stream:
        json.dump(result, stream)
