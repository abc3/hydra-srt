#include "unix_socket.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int sock = -1;

void init_unix_socket(const char* socket_path)
{
    struct sockaddr_un addr;

    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        exit(1);
    }

    memset(&addr, 0, sizeof(struct sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(struct sockaddr_un)) < 0) {
        perror("connect");
        cleanup_socket();
        exit(1);
    }
    printf("Connected to the socket.\n");
}

void send_message_to_unix_socket(const char* message)
{
    uint32_t len = strlen(message);
    uint32_t net_len = htonl(len);

    char* buf = malloc(sizeof(uint32_t) + len);
    if (!buf) {
        perror("malloc");
        return;
    }

    memcpy(buf, &net_len, sizeof(uint32_t));
    memcpy(buf + sizeof(uint32_t), message, len);

    if (send(sock, buf, sizeof(uint32_t) + len, 0) < 0) {
        perror("send");
    }

    free(buf);
}

void cleanup_socket()
{
    if (sock >= 0) {
        close(sock);
        sock = -1;
        printf("Socket closed.\n");
    }
}
