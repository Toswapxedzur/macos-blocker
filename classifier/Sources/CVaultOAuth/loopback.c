#include "CVaultOAuth.h"
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET vault_socket;
#define INVALID INVALID_SOCKET
#define close_socket closesocket
#else
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <unistd.h>
typedef int vault_socket;
#define INVALID (-1)
#define close_socket close
#endif

intptr_t vault_oauth_listen(uint16_t *port) {
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2,2), &data)) return -1;
#endif
    vault_socket descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (descriptor == INVALID) goto failed;
#ifndef _WIN32
    if (descriptor >= FD_SETSIZE) goto close_failed;
#endif
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) || listen(descriptor, 4)) goto close_failed;
#ifdef _WIN32
    int length = sizeof(address);
#else
    socklen_t length = sizeof(address);
#endif
    if (getsockname(descriptor, (struct sockaddr *)&address, &length)) goto close_failed;
    *port = ntohs(address.sin_port);
    return (intptr_t)descriptor;
close_failed:
    close_socket(descriptor);
failed:
#ifdef _WIN32
    WSACleanup();
#endif
    return -1;
}

intptr_t vault_oauth_accept(intptr_t listener, int timeout_ms) {
    vault_socket descriptor = (vault_socket)listener;
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(descriptor, &readable);
    struct timeval wait = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    int ready = select((int)descriptor + 1, &readable, NULL, NULL, &wait);
    if (ready == 0) return -2;
    if (ready < 0) return -1;
    vault_socket client = accept(descriptor, NULL, NULL);
    if (client == INVALID) return -1;
#ifdef _WIN32
    DWORD timeout = 500;
#else
    struct timeval timeout = {0, 500000};
    int no_sigpipe = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
#endif
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout));
    return (intptr_t)client;
}

int vault_oauth_read(intptr_t client, char *buffer, size_t capacity) {
    size_t used = 0;
    // Loopback callback headers have no request body. Bound total work even if
    // a local peer keeps trickling bytes before completing the headers.
    for (int round = 0; round < 16 && used + 1 < capacity; ++round) {
        int count = (int)recv((vault_socket)client, buffer + used, (int)(capacity - used - 1), 0);
        if (count <= 0) return -1;
        used += (size_t)count;
        buffer[used] = 0;
        if (strstr(buffer, "\r\n\r\n")) return (int)used;
    }
    return -1;
}

void vault_oauth_reply(intptr_t client, int success) {
    const char *reply = success
      ? "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\nReturn to Vault to finish connecting ChatGPT."
      : "HTTP/1.1 400 Bad Request\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nThis sign-in callback could not be accepted.";
    send((vault_socket)client, reply, (int)strlen(reply), 0);
}

void vault_oauth_close(intptr_t descriptor) { if (descriptor >= 0) close_socket((vault_socket)descriptor); }
void vault_oauth_close_listener(intptr_t descriptor) {
    vault_oauth_close(descriptor);
#ifdef _WIN32
    WSACleanup();
#endif
}
