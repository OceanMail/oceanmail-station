"""Test-owned semaphore lifetime, including failed or timed-out subprocesses."""
from contextlib import contextmanager
import ctypes
import secrets

libc=ctypes.CDLL(None,use_errno=True)

@contextmanager
def semaphore_env(env, keyed=False):
    key=0
    if keyed:
        # Startup must reopen the same set by key. IPC_EXCL prevents touching
        # unrelated IPC; the Python parent owns removal even after test failure.
        for _ in range(100):
            key=0x50000000 | secrets.randbelow(0x0fffffff)
            semid=libc.semget(key,2,0o600 | 0o1000 | 0o2000)
            if semid>=0:break
    else:
        semid=libc.semget(0,1,0o600) # IPC_PRIVATE; parent owns cleanup
    if semid<0:raise OSError(ctypes.get_errno(),'semget')
    try:
        if libc.semctl(semid,0,16,1)<0: # Linux SETVAL
            raise OSError(ctypes.get_errno(),'semctl SETVAL')
        if keyed and libc.semctl(semid,1,16,1)<0:
            raise OSError(ctypes.get_errno(),'semctl daemon SETVAL')
        yield dict(env,HERMES_TEST_SEMID=str(semid),HERMES_TEST_SEMKEY=str(key))
    finally:
        libc.semctl(semid,0,0) # IPC_RMID
