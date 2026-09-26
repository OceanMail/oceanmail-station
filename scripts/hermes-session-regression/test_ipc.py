"""Test-owned semaphore lifetime, including failed or timed-out subprocesses."""
from contextlib import contextmanager
import ctypes

libc=ctypes.CDLL(None,use_errno=True)

@contextmanager
def semaphore_env(env):
    semid=libc.semget(0,1,0o600) # IPC_PRIVATE; parent owns cleanup
    if semid<0:raise OSError(ctypes.get_errno(),'semget')
    try:
        if libc.semctl(semid,0,16,1)<0: # Linux SETVAL
            raise OSError(ctypes.get_errno(),'semctl SETVAL')
        yield dict(env,HERMES_TEST_SEMID=str(semid))
    finally:
        libc.semctl(semid,0,0) # IPC_RMID
