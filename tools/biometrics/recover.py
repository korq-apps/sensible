"""Installed outside the checkout; called by the rollback timer and at boot."""
import os
import pam_ops

if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit('Recovery requires root')
    pam_ops.rollback(pending_only=True)
