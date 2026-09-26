/* GPL-3.0-or-later. Real process death, startup exclusion and SEM_UNDO. */
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include "shm.h"

static void expect_refused(key_t key) {
    pid_t child=fork();assert(child>=0);
    if(!child)_exit(bridge_startup(key)<0 ? 0 : 1);
    int status;assert(waitpid(child,&status,0)==child);
    assert(WIFEXITED(status) && WEXITSTATUS(status)==0);
}

int main(void) {
    alarm(15);
    key_t key=(key_t)strtoul(getenv("HERMES_TEST_SEMKEY"),NULL,10);
    int semid=atoi(getenv("HERMES_TEST_SEMID"));
    assert(key!=IPC_PRIVATE);
    int ready[2];assert(!pipe(ready));
    pid_t daemon=fork();assert(daemon>=0);
    if(!daemon) {
        assert(!prctl(PR_SET_PDEATHSIG,SIGKILL));
        assert(bridge_startup(key)==semid);
        bridge_release(semid);
        assert(write(ready[1],"D",1)==1);
        for(;;)pause();
    }
    char byte;assert(read(ready[0],&byte,1)==1);
    expect_refused(key); /* a live daemon excludes a second startup */
    assert(semctl(semid,0,GETVAL)==1);
    pid_t bridge=fork();assert(bridge>=0);
    if(!bridge) {
        assert(!prctl(PR_SET_PDEATHSIG,SIGKILL));
        assert(bridge_claim(semid));
        assert(write(ready[1],"B",1)==1);
        for(;;)pause();
    }
    assert(read(ready[0],&byte,1)==1);
    int status;assert(!kill(daemon,SIGKILL));assert(waitpid(daemon,&status,0)==daemon);
    assert(semctl(semid,1,GETVAL)==1); /* dead daemon releases only its slot */
    expect_refused(key);
    assert(semget(key,2,0)==semid && semctl(semid,0,GETVAL)==0);
    assert(!kill(bridge,SIGKILL));assert(waitpid(bridge,&status,0)==bridge);
    assert(bridge_startup(key)==semid); /* recovery reuses, never replaces */
    bridge_release(semid);
    printf("live_daemon_refused=1 surviving_bridge_preserved=1 dead_bridge_recovered=1\n");
    close(ready[0]);close(ready[1]);return 0;
}
