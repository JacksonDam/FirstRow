#include "CPortable.h"

#include <string.h>
#include <time.h>

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
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
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

static void udp_send_to(int64_t s, unsigned long address, int port, const char* message)
{
    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_port = htons((unsigned short)port);
    target.sin_addr.s_addr = address;
#ifdef _WIN32
    sendto((SOCKET)s, message, (int)strlen(message), 0, (struct sockaddr*)&target, sizeof(target));
#else
    sendto((int)s, message, strlen(message), 0, (struct sockaddr*)&target, sizeof(target));
#endif
}

static double now_ms(void)
{
#ifdef _WIN32
    return (double)GetTickCount64();
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
#endif
}

int fr_udp_discover(const char* message, const char* extra_host, int extra_port, int port, int timeout_ms, char* out, int out_capacity)
{
    if(!out || out_capacity < 1 || !start_sockets())
        return 0;
    out[0] = 0;
#ifdef _WIN32
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if(s == INVALID_SOCKET)
        return 0;
#else
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if(s < 0)
        return 0;
#endif
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, (const char*)&on, sizeof(on));
    udp_send_to((int64_t)s, htonl(INADDR_BROADCAST), port, message);
#ifndef _WIN32
    /* Each network's own broadcast address too, since the general one leaves by one interface. */
    struct ifaddrs* interfaces = NULL;
    if(getifaddrs(&interfaces) == 0) {
        for(struct ifaddrs* entry = interfaces; entry; entry = entry->ifa_next) {
            if(!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET)
                continue;
            if(!(entry->ifa_flags & IFF_UP) || !(entry->ifa_flags & IFF_BROADCAST) || (entry->ifa_flags & IFF_LOOPBACK))
                continue;
            if(entry->ifa_broadaddr)
                udp_send_to((int64_t)s, ((struct sockaddr_in*)entry->ifa_broadaddr)->sin_addr.s_addr, port, message);
        }
        freeifaddrs(interfaces);
    }
#endif
    if(extra_host && extra_host[0] && extra_port > 0)
        udp_send_to((int64_t)s, inet_addr(extra_host), extra_port, message);

    int count = 0;
    int used = 0;
    double deadline = now_ms() + timeout_ms;
    char buffer[4096];
    for(;;) {
        double remaining = deadline - now_ms();
        if(remaining <= 0)
            break;
#ifdef _WIN32
        WSAPOLLFD poller = { s, POLLRDNORM, 0 };
        int ready = WSAPoll(&poller, 1, (int)remaining);
        if(ready <= 0)
            break;
        int got = recv(s, buffer, sizeof(buffer) - 1, 0);
#else
        struct pollfd poller = { s, POLLIN, 0 };
        int ready = poll(&poller, 1, (int)remaining);
        if(ready <= 0)
            break;
        ssize_t got = recv(s, buffer, sizeof(buffer) - 1, 0);
#endif
        if(got <= 0)
            continue;
        buffer[got] = 0;
        /* One reply per line: drop any newlines inside it. */
        for(int i = 0; i < got; i++)
            if(buffer[i] == '\n' || buffer[i] == '\r')
                buffer[i] = ' ';
        if(used + got + 2 > out_capacity)
            break;
        memcpy(out + used, buffer, (size_t)got);
        used += (int)got;
        out[used++] = '\n';
        out[used] = 0;
        count++;
    }
#ifdef _WIN32
    closesocket(s);
#else
    close(s);
#endif
    return count;
}
