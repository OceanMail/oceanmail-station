/* GPL-3.0-or-later. Exercise the actual net.c, including a real TCP reset. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
static int interrupted;
static ssize_t interrupted_recv(int fd, void *p, size_t n, int flags) {
    if (interrupted > 0) { --interrupted; errno=EINTR; return -1; }
    return recv(fd,p,n,flags);
}
#define recv interrupted_recv
#include NET_SOURCE
#undef recv
int main(int argc,char **argv) {
    assert(argc==2); alarm(5);
    uint8_t byte=0xa5;
    if(!strcmp(argv[1],"net-ebadf")) {
        bool ok=!tcp_read(-1,&byte,1) && byte==0xa5;
        printf("invalid_fd_rejected=%d unchanged=%d\n",ok,byte==0xa5);return ok?0:1;
    }
    int listener=socket(AF_INET,SOCK_STREAM,0);assert(listener>=0);
    struct sockaddr_in a={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(!bind(listener,(void*)&a,sizeof(a)));assert(!listen(listener,1));
    socklen_t n=sizeof(a);assert(!getsockname(listener,(void*)&a,&n));
    int peer=socket(AF_INET,SOCK_STREAM,0);assert(!connect(peer,(void*)&a,n));
    int fd=accept(listener,NULL,NULL);assert(fd>=0);close(listener);
    bool ok;
    if(!strcmp(argv[1],"net-reset")) {
        struct linger reset={1,0};assert(!setsockopt(peer,SOL_SOCKET,SO_LINGER,&reset,sizeof(reset)));
        close(peer);bool first=tcp_read(fd,&byte,1),second=tcp_read(fd,&byte,1);
        ok=!first && !second && byte==0xa5;
        printf("reset_read_success=%d next_read_success=%d unchanged=%d\n",first,second,byte==0xa5);
    } else {
        interrupted=3;assert(send(peer,"N",1,0)==1);
        ok=tcp_read(fd,&byte,1) && byte=='N' && !interrupted;close(peer);
        printf("eintr_retried=%d exact_byte=%d\n",!interrupted,byte=='N');
    }
    close(fd);return ok?0:1;
}
