"""Installed outside the checkout; called by the rollback timer and at boot."""
import os
import sys
import pam_ops


def main(pending_only=True):
    if os.geteuid() != 0:
        print('Recovery requires root', file=sys.stderr)
        return pam_ops.RECOVERY_RECONCILE
    try:
        pam_ops.rollback(pending_only=pending_only)
    except ValueError as error:
        print(f'Recovery needs manual reconciliation: {error}. Backup retained; automatic retries stopped.', file=sys.stderr)
        return pam_ops.RECOVERY_RECONCILE
    except OSError as error:
        print(f'Recovery could not finish: {error}. Backup retained; recovery will retry.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
