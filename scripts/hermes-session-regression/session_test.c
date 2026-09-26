/* Focused tests of real HERMES VARA workers, with loopback TCP and controlled
 * thread interleavings. No radio or UUCP process is started. GPL-3.0-or-later. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include "uucpd.h"
#include "net.h"
#include "serial.h"

static rhizo_conn c;
static int peer, control_peer;
static uint8_t in_storage[64], out_storage[64];
static _Thread_local int role; /* 1 receive, 2 control receive, 3 cleanup */
static atomic_int read_entered, held, release_hold, full_seen, markers, bad_marker;
static atomic_int calls, disconnects, cleanup_done, fault, fault_count;
static int hold_read, hold_full, hold_final, accelerated = 1;
static atomic_int final_wait;
static pthread_t rx, crx;
static int have_rx, have_crx, have_tx;
static pthread_t tx;
static atomic_int tx_held, tx_release, tx_exited, crx_exited, ctx_exited;
static int hold_tx, send_limit;
static atomic_int reject_bridge;
static atomic_int send_error, send_errors;
static atomic_int storm, storm_entered, release_storm, drain_attempts;
static atomic_int control_command_read, retire_exited, rx_locks, idle_sleeps;

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
#define WAIT(expr) do { double end = now()+3; while (!(expr)) { \
    if (now()>end) { fprintf(stderr,"TIMEOUT %s:%d %s\n",__FILE__,__LINE__,#expr); exit(2); } \
    usleep(1000); } } while (0)

static void pause_read(void) {
    if (hold_read && !atomic_exchange(&held,1)) WAIT(atomic_load(&release_hold));
}
static bool test_tcp_read(int fd, uint8_t *buf, size_t n) {
    if (role==1) atomic_fetch_add(&read_entered,1);
    bool ok=tcp_read(fd,buf,n);
    if(role==2 && ok && n==1 && *buf=='\r') atomic_fetch_add(&control_command_read,1);
    if (role==1 && ok) pause_read();
    return ok;
}
static ssize_t test_recv(int fd, void *buf, size_t n, int flags) {
    if (role==1) atomic_fetch_add(&read_entered,1);
    if(role==3 && fd==c.data_socket && atomic_load(&storm)) {
        atomic_store(&storm_entered,1); WAIT(atomic_load(&release_storm));
        atomic_fetch_add(&drain_attempts,1);
        if(atomic_load(&storm)==1) {errno=EINTR;return -1;}
        if(atomic_load(&storm)==2) {memset(buf,'O',n);return (ssize_t)n;}
    }
    if (fd==c.data_socket && atomic_load(&fault_count)>0) {
        atomic_fetch_sub(&fault_count,1); errno=atomic_load(&fault); return -1;
    }
    ssize_t result=recv(fd,buf,n,flags);
    if (role==1 && result>0) pause_read();
    return result;
}
static size_t test_free(cbuf_handle_t b) {
    size_t n=circular_buf_free_size(b);
    if (role==1 && !n) atomic_store(&full_seen,1);
    return n;
}
static unsigned test_sleep(unsigned n) {
    if(role==4 && hold_tx && !atomic_exchange(&tx_held,1)) WAIT(tx_release);
    if(role==1 && !c.connected) atomic_fetch_add(&idle_sleeps,1);
    if (role==3 && !c.clean_buffers) { atomic_store(&cleanup_done,1); pthread_exit(NULL); }
    usleep(accelerated?1000:n*1000000); return 0;
}
static int test_usleep(useconds_t n) {
    if (role==1 && hold_full && n==100000) WAIT(atomic_load(&release_hold));
    if (role==3 && n==1200000 && hold_final && atomic_fetch_add(&final_wait,1)==1)
        WAIT(atomic_load(&release_hold));
    return usleep(accelerated?1000:n);
}
static int test_system(const char *s) {
    assert(!strcmp(s,"killall uucico") || !strcmp(s,"killall uuport")); return 0;
}
static int test_fprintf(FILE *f,const char *fmt,...) {
    if (!strcmp(fmt,"Connection cleanup complete.\n")) {
        if(c.clean_buffers || c.connected || c.buffer_size || circular_buf_size(c.out_buffer))
            atomic_store(&bad_marker,1);
        atomic_fetch_add(&markers,1);
    }
    va_list ap; va_start(ap,fmt); int n=vfprintf(f,fmt,ap); va_end(ap); return n;
}
static bool test_tcp_write(int fd,uint8_t *p,size_t n) {
    if(fd==c.control_socket && n==11 && !memcmp(p,"DISCONNECT\r",11))
        atomic_fetch_add(&disconnects,1);
    return tcp_write(fd,p,n);
}
static ssize_t test_send(int fd,const void *p,size_t n,int flags) {
    if(role==4) {
        if(send_errors>0){atomic_fetch_sub(&send_errors,1);errno=send_error;return -1;}
        if(send_limit && n>(size_t)send_limit)n=send_limit;
    }
    return send(fd,p,n,flags);
}
static int test_mutex_lock(pthread_mutex_t *m) {
    if(role==1) atomic_fetch_add(&rx_locks,1);
    return pthread_mutex_lock(m);
}

#define send test_send
#define tcp_read test_tcp_read
#define tcp_write test_tcp_write
#define recv test_recv
#define circular_buf_free_size test_free
#define sleep test_sleep
#define usleep test_usleep
#define system test_system
#define fprintf test_fprintf
#define pthread_mutex_lock test_mutex_lock
#if VARIANT != 2
/* Used only by patch-specific test branches, never by upstream workers. */
static pthread_mutex_t vara_rx_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif
#include VARA_SOURCE
#undef pthread_mutex_lock
#undef send
#undef tcp_read
#undef tcp_write
#undef recv
#undef circular_buf_free_size
#undef sleep
#undef usleep
#undef system
#undef fprintf

bool call_uucico(rhizo_conn *unused) { (void)unused; if(reject_bridge)return false; atomic_fetch_add(&calls,1); return true; }
void connected_led_on(int a,int b) { (void)a;(void)b; }
void connected_led_off(int a,int b) { (void)a;(void)b; }
void key_on(int a,int b) { (void)a;(void)b; }
void key_off(int a,int b) { (void)a;(void)b; }
void modem_bytes_received(int32_t a,int b) { (void)a;(void)b; }
void modem_bytes_transmitted(int32_t a,int b) { (void)a;(void)b; }
void modem_snr(int32_t a,int b) { (void)a;(void)b; }
void modem_bitrate(uint32_t a,int b) { (void)a;(void)b; }

static void pair(int *a,int *b) {
    int l=socket(AF_INET,SOCK_STREAM,0); assert(l>=0);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(bind(l,(void*)&addr,sizeof(addr))==0); assert(listen(l,1)==0);
    socklen_t len=sizeof(addr); assert(getsockname(l,(void*)&addr,&len)==0);
    *b=socket(AF_INET,SOCK_STREAM,0); assert(connect(*b,(void*)&addr,len)==0);
    *a=accept(l,NULL,NULL); assert(*a>=0); close(l);
}
static void init(void) {
#ifdef TEST_BRIDGE_SEMAPHORE
    assert(getenv("HERMES_TEST_SEMID"));c.bridge_semid=atoi(getenv("HERMES_TEST_SEMID"));
#endif
    cbuf_handle_t *h[]={&c.in_buffer,&c.out_buffer}; uint8_t *b[]={in_storage,out_storage};
    for(int i=0;i<2;i++) {
        *h[i]=calloc(1,sizeof(**h[i])); (*h[i])->internal=calloc(1,sizeof(*(*h[i])->internal));
        (*h[i])->buffer=b[i]; (*h[i])->internal->max=64;
        atomic_flag_clear(&(*h[i])->internal->acquire); circular_buf_reset(*h[i]);
    }
    c.radio_type=RADIO_TYPE_NONE; c.vara_mode=2300; strcpy(c.call_sign,"TESTA");
    pair(&c.data_socket,&peer); pair(&c.control_socket,&control_peer);
}
static void *receive(void *p) { role=1; return vara_data_worker_thread_rx(p); }
static void *control(void *p) { role=2; void *r=vara_control_worker_thread_rx(p);crx_exited=1;return r; }
static void *transmit(void *p) {role=4;void *r=vara_data_worker_thread_tx(p);tx_exited=1;return r;}
static void *control_tx(void *p) {role=5;void *r=vara_control_worker_thread_tx(p);ctx_exited=1;return r;}
static void *cleanup(void *p) { role=3; return vara_control_worker_thread_tx(p); }
static void *storm_cleanup(void *p) {
    role=3; void *r=vara_control_worker_thread_tx(p); atomic_store(&retire_exited,1);return r;
}
static void start(void) {
    assert(!pthread_create(&rx,NULL,receive,&c)); have_rx=1;
    assert(!pthread_create(&crx,NULL,control,&c)); have_crx=1;
}
static void command(const char *s) { assert(send(control_peer,s,strlen(s),MSG_NOSIGNAL)==(ssize_t)strlen(s)); }
static void connect_session(void) {
    int prior=atomic_load(&calls); command("CONNECTED TESTA TESTB\r"); WAIT(atomic_load(&calls)>prior);
}
static void disconnect_session(void) {
    command("DISCONNECTED\r"); WAIT(!c.connected && c.clean_buffers);
}
static void retire(void) {
    pthread_t t; atomic_store(&cleanup_done,0);
    assert(!pthread_create(&t,NULL,cleanup,&c)); assert(!pthread_join(t,NULL));
}
static void send_data(const char *p,size_t n) { assert(send(peer,p,n,MSG_NOSIGNAL)==(ssize_t)n); }
static size_t pending(void) {
    char b[16384]; ssize_t n=recv(c.data_socket,b,sizeof(b),MSG_PEEK|MSG_DONTWAIT);
    return n>0?(size_t)n:0;
}
static bool drain(void) {
#if VARIANT==2
    pthread_mutex_lock(&vara_rx_mutex);
    bool ok=vara_discard_stale_data(&c);
    pthread_mutex_unlock(&vara_rx_mutex); return ok;
#elif VARIANT==1
    vara_discard_stale_data(&c); return !pending();
#else
    return !pending();
#endif
}
static bool greeting(void) {
    send_data("Shere",5); WAIT(circular_buf_size(c.out_buffer)>=5 || c.shutdown);
    char b[5]; bool ok=circular_buf_size(c.out_buffer)==5;
    if(ok) { circular_buf_get_range(c.out_buffer,(uint8_t*)b,5); ok=!memcmp(b,"Shere",5); }
    return ok;
}
static int finish(const char *name,bool ok) {
    c.shutdown=true; atomic_store(&release_hold,1);
    shutdown(peer,SHUT_RDWR); shutdown(control_peer,SHUT_RDWR);
    if(have_rx) pthread_join(rx,NULL);
    if(have_crx) pthread_join(crx,NULL);
    if(have_tx) pthread_join(tx,NULL);
    printf("%s %s buffered=%zu pending=%zu markers=%d invalid=%d\n",ok?"PASS":"FAIL",name,
        circular_buf_size(c.out_buffer),pending(),atomic_load(&markers),atomic_load(&bad_marker));
    close(peer);close(control_peer);close(c.data_socket);close(c.control_socket);
    circular_buf_free(c.in_buffer);circular_buf_free(c.out_buffer);return ok?0:1;
}

int main(int argc,char **argv) {
    assert(argc==2); signal(SIGPIPE,SIG_IGN); alarm(15); init(); const char *name=argv[1]; bool ok=false;
    if(!strcmp(name,"duplicate-disconnected")) {
        start();connect_session();disconnect_session();retire();
        circular_buf_put_range(c.in_buffer,(uint8_t*)"NEW",3);
        int commands=control_command_read;
        command("DISCONNECTED\r");WAIT(control_command_read>commands);
        /* Wait for the handler, not just its last socket read. */
        usleep(20000);
        ok=!c.clean_buffers && markers==1 && circular_buf_size(c.in_buffer)==3;
        connect_session();ok &= greeting();
    } else if(!strcmp(name,"local-disconnect-ack")) {
        start();connect_session();c.clean_buffers=true;pthread_t t;
        assert(!pthread_create(&t,NULL,cleanup,&c));WAIT(disconnects==1);
        command("DISCONNECTED\r");pthread_join(t,NULL);
        ok=!c.clean_buffers && !c.connected && markers==1;
        connect_session();ok &= greeting();
    } else if(!strcmp(name,"incoming-busy")) {
        reject_bridge=1;start();command("CONNECTED TESTA TESTB\r");
        WAIT(c.clean_buffers && c.connected);pthread_t t;
        assert(!pthread_create(&t,NULL,cleanup,&c));WAIT(disconnects==1);
        /* Cleanup may finish before a polling observer sees clean_buffers.
         * Join its worker and assert the durable final state instead. */
        command("DISCONNECTED\r");pthread_join(t,NULL);
        ok=!calls && markers==1 && !c.connected && !c.clean_buffers && !c.shutdown;
        reject_bridge=0;connect_session();ok &= greeting();
    } else if(!strcmp(name,"tx-retained-generation")) {
        hold_tx=1;c.connected=true;c.buffer_size=MAX_VARA_BUFFER;
        circular_buf_put_range(c.in_buffer,(uint8_t*)"OLD",3);
        assert(!pthread_create(&tx,NULL,transmit,&c));have_tx=1;
        WAIT(tx_held);assert(circular_buf_size(c.in_buffer)==0);
        start();disconnect_session();retire();connect_session();
        circular_buf_put_range(c.in_buffer,(uint8_t*)"NEW",3);tx_release=1;
        uint8_t b[3];assert(tcp_read(peer,b,3));
        /* Socket readability can precede accounting immediately after send. */
        WAIT(c.bytes_buffered_tx==3);
        printf("transmitted=%02x%02x%02x accounted=%d\n",b[0],b[1],b[2],c.bytes_buffered_tx);
        ok=!memcmp(b,"NEW",3);
    } else if(!strncmp(name,"tx-partial-",11)) {
        c.connected=true;send_limit=2;
        send_error=!strcmp(name,"tx-partial-eintr")?EINTR:EAGAIN;send_errors=3;
        uint8_t payload[]={0,1,2,255,254,0,13,10,42},b[sizeof(payload)];
        circular_buf_put_range(c.in_buffer,payload,sizeof(payload));
        assert(!pthread_create(&tx,NULL,transmit,&c));have_tx=1;
        assert(tcp_read(peer,b,sizeof(b)));
        WAIT(c.bytes_buffered_tx==(int)sizeof(b));
        ok=!memcmp(b,payload,sizeof(b)) && circular_buf_size(c.in_buffer)==0 && !c.shutdown;
    } else if(!strcmp(name,"control-reset-shutdown")) {
        accelerated=0;c.connected=true;
        start();assert(!pthread_create(&tx,NULL,transmit,&c));have_tx=1;
        pthread_t t;assert(!pthread_create(&t,NULL,control_tx,&c));
        char commands[1024];assert(recv(control_peer,commands,sizeof(commands),0)>0);
        struct linger abortive={1,0};assert(!setsockopt(control_peer,SOL_SOCKET,SO_LINGER,&abortive,sizeof(abortive)));
        double begin=now();close(control_peer);control_peer=-1;
        WAIT(crx_exited);double control_exit=now()-begin;
        WAIT(tx_exited && ctx_exited);pthread_join(t,NULL);
        ok=c.shutdown && control_exit<0.25 && now()-begin<1.25;
        printf("control_exit_seconds=%.6f all_exit_seconds=%.6f\n",control_exit,now()-begin);
    } else if(!strcmp(name,"retirement-eintr-storm") || !strcmp(name,"retirement-data-stream")) {
        c.clean_buffers=true;storm=!strcmp(name,"retirement-eintr-storm")?1:2;
        assert(!pthread_create(&crx,NULL,control,&c));have_crx=1;
        pthread_t t;assert(!pthread_create(&t,NULL,storm_cleanup,&c));WAIT(storm_entered);
        command("CONNECTED TESTA TESTB\r");WAIT(control_command_read);
        double begin=now();release_storm=1;
        WAIT(disconnects==1);
        double control_seconds=now()-begin;
        ok=!c.shutdown && c.clean_buffers && !markers && !calls && !retire_exited;
        int first_attempts=drain_attempts;
        command("DISCONNECTED\r");WAIT(!c.connected);
        WAIT(drain_attempts>first_attempts);
        printf("control_seconds=%.6f attempts=%d stopped=%d\n",control_seconds,atomic_load(&drain_attempts),c.shutdown);
        ok &= control_seconds < 0.25;
        /* After arbitrarily many batches, a finite tail still retires normally. */
        storm=0;pthread_join(t,NULL);
        ok &= !c.shutdown && !c.clean_buffers && markers==1 && !bad_marker;
        int lock=pthread_mutex_trylock(&vara_rx_mutex);ok &= lock==0;
        if(lock==0)pthread_mutex_unlock(&vara_rx_mutex);
        assert(!pthread_create(&rx,NULL,receive,&c));have_rx=1;
        connect_session();ok &= greeting();
    } else if(!strcmp(name,"idle-polling")) {
        accelerated=0;assert(!pthread_create(&rx,NULL,receive,&c));have_rx=1;
        usleep(250000);ok=atomic_load(&rx_locks)<4 && !atomic_load(&read_entered);
        printf("idle_locks=%d idle_sleeps=%d\n",atomic_load(&rx_locks),atomic_load(&idle_sleeps));
    } else if(!strncmp(name,"drain-",6)) {
        int count=!strcmp(name,"drain-large")?12289:6;
        if(!strcmp(name,"drain-empty") || !strcmp(name,"drain-eof")) count=0;
        char b[12289]; memset(b,'O',sizeof(b)); if(count) {send_data(b,count);WAIT(pending()==(size_t)count);}
        if(!strcmp(name,"drain-eof")) shutdown(peer,SHUT_WR);
        if(!strcmp(name,"drain-eintr")) {fault=EINTR;fault_count=3;}
        if(!strcmp(name,"drain-error")) {fault=ECONNRESET;fault_count=1;}
        int flags=fcntl(c.data_socket,F_GETFL); bool success=drain();
        bool fatal=!strcmp(name,"drain-eof")||!strcmp(name,"drain-error");
        ok=fatal?!success:success&&!pending(); ok&=flags==fcntl(c.data_socket,F_GETFL);
    } else if(!strncmp(name,"cleanup-",8)) {
        c.clean_buffers=true; c.buffer_size=17; circular_buf_put(c.in_buffer,'X'); circular_buf_put(c.out_buffer,'X');
        send_data("OOOOOO",6); WAIT(pending()==6);
        bool fatal=!strcmp(name,"cleanup-error") || !strcmp(name,"cleanup-eof");
        if(!strcmp(name,"cleanup-error")){fault=EBADF;fault_count=1;}
        if(!strcmp(name,"cleanup-eof")) shutdown(peer,SHUT_WR);
        if(!strcmp(name,"cleanup-eintr")){fault=EINTR;fault_count=3;}
        if(!strcmp(name,"cleanup-real-time")) accelerated=0;
        double start=now(); retire(); printf("cleanup_seconds=%.6f\n",now()-start);
        ok=fatal ? c.shutdown && c.clean_buffers && !markers : !c.shutdown && !c.clean_buffers &&
            !pending() && markers==1 && !bad_marker;
    } else if(!strcmp(name,"full-buffer-disconnect")) {
        hold_full=1; c.connected=true; for(int i=0;i<64;i++) circular_buf_put(c.out_buffer,'X');
        send_data("O",1); start(); WAIT(full_seen);
        disconnect_session(); retire(); atomic_store(&release_hold,1);
        /* A rejected old byte must not pollute a new, valid greeting. */
        connect_session(); ok=greeting();
    } else if(!strcmp(name,"reconnect-inflight") || !strcmp(name,"disconnect-during-read")) {
        hold_read=1; c.connected=true; start(); WAIT(read_entered); send_data("O",1); WAIT(held);
#if VARIANT==2
        /* The old schedule is now impossible: recv and enqueue own the session
         * mutex. Control cannot retire/reopen a session while this byte is held. */
        assert(pthread_mutex_trylock(&vara_rx_mutex)==EBUSY);
        command("DISCONNECTED\r"); atomic_store(&release_hold,1);
        WAIT(!c.connected && c.clean_buffers); retire();
#else
        disconnect_session(); retire();
        if(!strcmp(name,"reconnect-inflight")) connect_session();
        atomic_store(&release_hold,1);
        if(!strcmp(name,"disconnect-during-read")) {
            usleep(20000); ok=circular_buf_size(c.out_buffer)==0; return finish(name,ok);
        }
#endif
#if VARIANT==2
        connect_session();
#endif
        ok=greeting();
    } else if(!strcmp(name,"early-connect") || !strcmp(name,"connect-during-final-wait")) {
        c.clean_buffers=true; start(); pthread_t t;
        bool during=!strcmp(name,"connect-during-final-wait");
        if(during){hold_final=1;assert(!pthread_create(&t,NULL,cleanup,&c));WAIT(final_wait>=2);}
        command("CONNECTED TESTA TESTB\r"); WAIT(c.connected);
        if(VARIANT!=2) { if(during){release_hold=1;c.connected=false;pthread_join(t,NULL);}return finish(name,false); }
        WAIT(disconnects); ok=calls==0 && c.clean_buffers;
        send_data("old greeting",12); disconnect_session();
        if(during){release_hold=1;pthread_join(t,NULL);}else retire();
        ok &= !pending() && markers==1 && !bad_marker;
        connect_session(); ok &= greeting();
    } else {
        start();connect_session();
        if(!strcmp(name,"active-greeting")) ok=greeting();
        else if(!strcmp(name,"receive-eintr")){fault=EINTR;fault_count=3;ok=greeting();}
        else if(!strcmp(name,"receive-eof") || !strcmp(name,"receive-error")) {
            if(!strcmp(name,"receive-eof"))shutdown(peer,SHUT_WR);
            else {fault=ECONNRESET;fault_count=1;}
            WAIT(c.shutdown);ok=!circular_buf_size(c.out_buffer);
        } else if(!strcmp(name,"repeated-sessions")) {
            ok=true;for(int i=0;i<20;i++){ok &= greeting();disconnect_session();retire();connect_session();}
            ok &= markers==20&&!bad_marker;
        } else if(!strcmp(name,"binary-transfer")) {
            uint8_t b[4096],received[4096];for(int i=0;i<4096;i++)b[i]=(i*37)&255;
            send_data((char*)b,sizeof(b));size_t n=0;double end=now()+5;
            while(n<sizeof(b)&&now()<end){size_t ready=circular_buf_size(c.out_buffer);if(ready){circular_buf_get_range(c.out_buffer,received+n,ready);n+=ready;}else usleep(1000);}
            ok=n==sizeof(b)&&!memcmp(b,received,n);
        } else assert(!"unknown test");
    }
    return finish(name,ok);
}
