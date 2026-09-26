/* GPL-3.0-or-later. Actual incoming bridge lifecycle, pipes, fork/wait/kill.
 * Only exec is substituted: the child is a controlled, stalled UUCP peer. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/prctl.h>
#define TEST_SIZE 131072
#include "uucpd.h"
#include "call_uucico.h"
static int ready[2], send_greeting, force_preexec;
static void inherited_handler(int sig){(void)sig;write(ready[1],"H",1);_exit(77);}
static pid_t observed_fork(void) {
    pid_t p=fork();if(p==0 && force_preexec)kill(getpid(),SIGTERM);return p;
}
static int fake_exec(const char *path,const char *arg,...) {
    (void)path;(void)arg;assert(!prctl(PR_SET_PDEATHSIG,SIGKILL));
    if(send_greeting)assert(write(1,"NEW",3)==3);
    assert(write(ready[1],"R",1)==1);
    for(;;)pause();
}
#define fork observed_fork
#define execl fake_exec
#define execv(path, args) fake_exec(path, args[0])
#include UUCICO_SOURCE
#undef execl
#undef execv
#undef fork
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
#define WAIT(c) do{double end=now()+3;while(!(c)){assert(now()<end);usleep(1000);}}while(0)
static cbuf_handle_t ring(void) {
    cbuf_handle_t b=calloc(1,sizeof(*b));b->internal=calloc(1,sizeof(*b->internal));
    b->buffer=calloc(TEST_SIZE,1);b->internal->max=TEST_SIZE;atomic_flag_clear(&b->internal->acquire);return b;
}
static void retire(rhizo_conn *c) {
    double start=now();c->clean_buffers=true;WAIT(!bridge_busy(c->bridge_semid));
    assert(!c->uucico_active);
    printf("incoming_bridge_retire_seconds=%.6f\n",now()-start);
}
int main(int argc,char **argv) {
    force_preexec=argc>1 && !strcmp(argv[1],"preexec");
    alarm(10);signal(SIGPIPE,SIG_IGN);assert(!pipe(ready));
    rhizo_conn c={0};c.in_buffer=ring();c.out_buffer=ring();
    assert(getenv("HERMES_TEST_SEMID"));c.bridge_semid=atoi(getenv("HERMES_TEST_SEMID"));
    if(force_preexec) {
        signal(SIGTERM,inherited_handler);
        assert(call_uucico(&c));pthread_t t;assert(!pthread_create(&t,NULL,uucico_thread,&c));
        WAIT(!bridge_busy(c.bridge_semid));
        assert(!fcntl(ready[0],F_SETFL,O_NONBLOCK));char marker;
        bool safe=read(ready[0],&marker,1)<0 && errno==EAGAIN && c.clean_buffers && !c.shutdown;
        c.shutdown=true;pthread_join(t,NULL);
        printf("preexec_parent_handler_avoided=%d\n",safe);
        return safe?0:1;
    }
    uint8_t payload[TEST_SIZE]={0};
    assert(!circular_buf_put_range(c.in_buffer,payload,sizeof(payload)));
    assert(!circular_buf_put_range(c.out_buffer,payload,sizeof(payload)));
    assert(call_uucico(&c));assert(!call_uucico(&c));
    pthread_t t;assert(!pthread_create(&t,NULL,uucico_thread,&c));
    char b;assert(read(ready[0],&b,1)==1);
    int capacity=fcntl(c.pipefd1[1],F_GETPIPE_SZ);printf("pipe_capacity=%d\n",capacity);fflush(stdout);assert(capacity>0 && capacity<TEST_SIZE);
    WAIT(circular_buf_size(c.out_buffer)<TEST_SIZE-(size_t)capacity);
    retire(&c); /* reader throttled by full input; writer blocked in pipe */
    circular_buf_reset(c.in_buffer);circular_buf_reset(c.out_buffer);
    c.clean_buffers=false;send_greeting=1;assert(call_uucico(&c));
    assert(read(ready[0],&b,1)==1);WAIT(circular_buf_size(c.in_buffer)==3);
    uint8_t greeting[3];assert(!circular_buf_get_range(c.in_buffer,greeting,3));
    assert(!memcmp(greeting,"NEW",3));retire(&c);
    c.shutdown=true;pthread_join(t,NULL);
    printf("incoming_backpressure_retired=1 next_bridge_exact=1\n");
    free(c.in_buffer->buffer);free(c.out_buffer->buffer);
    circular_buf_free(c.in_buffer);circular_buf_free(c.out_buffer);
    close(ready[0]);close(ready[1]);return 0;
}
