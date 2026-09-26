/* GPL-3.0-or-later. Real SysV shared rings, actual uuport in a child process,
 * and actual VARA workers. Kill commands target only this test's child. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/shm.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>
#include "uucpd.h"
#include "shm.h"
#include "net.h"
#include "serial.h"
static rhizo_conn *state;
static pid_t bridge_pid;
static atomic_int calls,markers,kills;
static _Thread_local int cleanup_role;
extern int run_uuport(key_t);
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
#define WAIT(c) do { double end=now()+5;while(!(c)){assert(now()<end);usleep(1000);} }while(0)
static int local_system(const char *s) {
    if(!strcmp(s,"killall uucico"))return 0;
    assert(!strcmp(s,"killall uuport"));assert(kill(bridge_pid,SIGTERM)==0);atomic_fetch_add(&kills,1);return 0;
}
static unsigned local_sleep(unsigned n){
    if(cleanup_role && !state->clean_buffers)pthread_exit(NULL);
    return sleep(n);
}
static int observed_fprintf(FILE *f,const char *fmt,...){
    if(!strcmp(fmt,"Connection cleanup complete.\n"))atomic_fetch_add(&markers,1);
    va_list ap;va_start(ap,fmt);int n=vfprintf(f,fmt,ap);va_end(ap);return n;
}
#define system local_system
#define sleep local_sleep
#define fprintf observed_fprintf
#include VARA_SOURCE
#undef system
#undef sleep
#undef fprintf
bool call_uucico(rhizo_conn *p){(void)p;atomic_fetch_add(&calls,1);return true;}
void connected_led_on(int a,int b){(void)a;(void)b;}
void connected_led_off(int a,int b){(void)a;(void)b;}
void key_on(int a,int b){(void)a;(void)b;}
void key_off(int a,int b){(void)a;(void)b;}
void modem_bytes_received(int32_t a,int b){(void)a;(void)b;}
void modem_bytes_transmitted(int32_t a,int b){(void)a;(void)b;}
void modem_snr(int32_t a,int b){(void)a;(void)b;}
void modem_bitrate(uint32_t a,int b){(void)a;(void)b;}
static void pair(int *a,int *b){
    int l=socket(AF_INET,SOCK_STREAM,0);assert(l>=0);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(!bind(l,(void*)&addr,sizeof(addr)));assert(!listen(l,1));
    socklen_t n=sizeof(addr);assert(!getsockname(l,(void*)&addr,&n));
    *b=socket(AF_INET,SOCK_STREAM,0);assert(!connect(*b,(void*)&addr,n));
    *a=accept(l,NULL,NULL);assert(*a>=0);close(l);
}
static void *cleanup(void *p){cleanup_role=1;return vara_control_worker_thread_tx(p);}
int main(int argc,char **argv){
    bool crash=argc>1 && !strcmp(argv[1],"crash");
    alarm(15);
    key_t key=0x62000000 | ((getpid() & 0xffff)*8);
    for(int i=0;i<6;i++)assert(!shm_is_created(key+i,1));
    assert(shm_create(key,sizeof(*state)));state=shm_attach(key,sizeof(*state));assert(state);
    memset(state,0,sizeof(*state));
#ifdef TEST_BRIDGE_SEMAPHORE
    assert(getenv("HERMES_TEST_SEMID"));state->bridge_semid=atoi(getenv("HERMES_TEST_SEMID"));
#endif
    state->in_buffer=circular_buf_init_shm(INTERNAL_BUFFER_SIZE,key+2);
    state->out_buffer=circular_buf_init_shm(INTERNAL_BUFFER_SIZE,key+4);
    state->connected=true;strcpy(state->call_sign,"TESTA");state->vara_mode=2300;
    int data_peer,control_peer;pair(&state->data_socket,&data_peer);pair(&state->control_socket,&control_peer);
    int input[2],output[2];assert(!pipe(input));assert(!pipe(output));
    circular_buf_put_range(state->out_buffer,(uint8_t*)"OLD",3);
    bridge_pid=fork();assert(bridge_pid>=0);
    if(!bridge_pid){
        dup2(input[0],0);dup2(output[1],1);close(input[1]);close(output[0]);
        _exit(run_uuport(key));
    }
    close(input[0]);close(output[1]);
    int status;assert(waitpid(bridge_pid,&status,WUNTRACED)==bridge_pid);assert(WIFSTOPPED(status));
    /* End a live session through the actual control handler. Current upstream
     * deliberately kills a bridge only for this path, not idle notifications. */
    pthread_t rx,crx;assert(!pthread_create(&crx,NULL,vara_control_worker_thread_rx,state));
    const char *cmd="DISCONNECTED\r";
    assert(send(control_peer,cmd,strlen(cmd),0)==(ssize_t)strlen(cmd));
    WAIT(!state->connected && state->clean_buffers);
    pthread_t cleanup_thread;assert(!pthread_create(&cleanup_thread,NULL,cleanup,state));
    WAIT(kills==1);
    /* Exceed the old implementation's remaining 1.2-second teardown sleep. */
    usleep(1500000);
    /* The old bridge stays stopped; control must still reject an early call. */
    assert(!pthread_create(&rx,NULL,vara_data_worker_thread_rx,state));
    cmd="CONNECTED TESTA TESTB\r";
    assert(send(control_peer,cmd,strlen(cmd),0)==(ssize_t)strlen(cmd));
    WAIT(state->connected);
#ifdef TEST_BRIDGE_SEMAPHORE
    pthread_mutex_lock(&vara_rx_mutex);
    pthread_mutex_unlock(&vara_rx_mutex);
#else
    WAIT(calls==1);
#endif
    bool held_retirement=!markers && state->clean_buffers && !calls;
    bool retired=false,recovered=false;
    assert(waitpid(bridge_pid,&status,WNOHANG)==0);
    if (!held_retirement) {
        assert(!kill(bridge_pid,SIGCONT));
        assert(waitpid(bridge_pid,&status,0)==bridge_pid);
        assert(!pthread_join(cleanup_thread,NULL));
        printf("FAIL cleanup_completed_with_old_bridge_alive=%d late_old_bridge_marked_new_session_dirty=%d\n",
               markers==1,state->connected && state->clean_buffers);
        goto done;
    }
    cmd="DISCONNECTED\r";assert(send(control_peer,cmd,strlen(cmd),0)==(ssize_t)strlen(cmd));
    WAIT(!state->connected);
    assert(kill(bridge_pid,crash?SIGKILL:SIGCONT)==0);
    assert(waitpid(bridge_pid,&status,0)==bridge_pid);
    assert(!pthread_join(cleanup_thread,NULL));
    retired=markers==1 && !state->clean_buffers;
    cmd="CONNECTED TESTA TESTB\r";assert(send(control_peer,cmd,strlen(cmd),0)==(ssize_t)strlen(cmd));
    WAIT(calls==1);assert(send(data_peer,"NEW",3,0)==3);WAIT(circular_buf_size(state->out_buffer)==3);
    char greeting[3];assert(!circular_buf_get_range(state->out_buffer,(uint8_t*)greeting,3));
    recovered=!state->clean_buffers && !memcmp(greeting,"NEW",3);
    printf("crash=%d retirement_waited_for_bridge=%d retired=%d new_session_exact=%d\n",crash,held_retirement,retired,recovered);
done:
    state->shutdown=true;shutdown(data_peer,SHUT_RDWR);shutdown(control_peer,SHUT_RDWR);
    pthread_join(rx,NULL);pthread_join(crx,NULL);
    close(input[1]);close(output[0]);close(data_peer);close(control_peer);
    close(state->data_socket);close(state->control_socket);
    circular_buf_free_shm(state->in_buffer,INTERNAL_BUFFER_SIZE,key+2);
    circular_buf_free_shm(state->out_buffer,INTERNAL_BUFFER_SIZE,key+4);
    shm_dettach(key,sizeof(*state),state);shm_destroy(key,sizeof(*state));
    return held_retirement && retired && recovered?0:1;
}
