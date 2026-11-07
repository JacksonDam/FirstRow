#include "CPortable.h"

#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>

static int started = 0;

static int start_sockets(void)
{
    if(!started) {
        WSADATA data;
        if(WSAStartup(MAKEWORD(2, 2), &data) != 0)
            return 0;
        started = 1;
    }
    return 1;
}
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static int start_sockets(void)
{
    return 1;
}
#endif

int64_t fr_tcp_connect_loopback(int port)
{
    if(!start_sockets())
        return -1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
#ifdef _WIN32
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if(s == INVALID_SOCKET)
        return -1;
    if(connect(s, (struct sockaddr*)&address, sizeof(address)) != 0) {
        closesocket(s);
        return -1;
    }
#else
    int s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if(s < 0)
        return -1;
    if(connect(s, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(s);
        return -1;
    }
#endif
    int on = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&on, sizeof(on));
    return (int64_t)s;
}

int64_t fr_tcp_send(int64_t s, const void* bytes, int64_t length)
{
    int64_t sent = 0;
    while(sent < length) {
        int chunk = length - sent > 1 << 20 ? 1 << 20 : (int)(length - sent);
#ifdef _WIN32
        int count = send((SOCKET)s, (const char*)bytes + sent, chunk, 0);
#else
        ssize_t count = send((int)s, (const char*)bytes + sent, (size_t)chunk, MSG_NOSIGNAL);
#endif
        if(count <= 0)
            return -1;
        sent += count;
    }
    return sent;
}

int64_t fr_tcp_receive(int64_t s, void* buffer, int64_t capacity)
{
    int chunk = capacity > 1 << 20 ? 1 << 20 : (int)capacity;
#ifdef _WIN32
    int count = recv((SOCKET)s, (char*)buffer, chunk, 0);
#else
    ssize_t count = recv((int)s, buffer, (size_t)chunk, 0);
#endif
    return count < 0 ? -1 : (int64_t)count;
}

void fr_tcp_close(int64_t s)
{
#ifdef _WIN32
    shutdown((SOCKET)s, SD_BOTH);
    closesocket((SOCKET)s);
#else
    shutdown((int)s, SHUT_RDWR);
    close((int)s);
#endif
}
