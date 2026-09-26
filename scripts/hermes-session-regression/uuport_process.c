/* GPL-3.0-or-later. Run actual uuport with isolated test IPC keys. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/prctl.h>
#include <assert.h>
#include "uucpd.h"
#include "shm.h"
static key_t test_key;
static atomic_bool input_waiting;
static int paused;
static ssize_t observed_read(int fd, void *p, size_t n) {
    if(fd==0)atomic_store(&input_waiting,true);
    return read(fd,p,n);
}
static int paused_get(cbuf_handle_t b,uint8_t *p,size_t n) {
    if(!paused++) {
        while(!atomic_load(&input_waiting))usleep(1000);
        raise(SIGSTOP); /* Both workers are outside ring critical sections. */
    }
    return circular_buf_get_range(b,p,n);
}
#undef SYSV_SHM_KEY_STR
#undef SYSV_SHM_KEY_IB
#undef SYSV_SHM_KEY_OB
#define SYSV_SHM_KEY_STR test_key
#define SYSV_SHM_KEY_IB (test_key+2)
#define SYSV_SHM_KEY_OB (test_key+4)
#define main uuport_entry
#define read observed_read
#define circular_buf_get_range paused_get
#include UUPORT_SOURCE
#undef circular_buf_get_range
#undef read
#undef main
int run_uuport(key_t key) {
    assert(!prctl(PR_SET_PDEATHSIG,SIGKILL));
    test_key=key;char *args[]={"uuport",NULL};
    return uuport_entry(1,args);
}
