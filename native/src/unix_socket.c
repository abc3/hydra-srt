#include "unix_socket.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int sock;

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
    if (send(sock, message, strlen(message), 0) < 0) {
        perror("send");
    }
}

void cleanup_socket()
{
    if (sock >= 0) {
        close(sock);
        sock = -1;
        printf("Socket closed.\n");
    }
}
