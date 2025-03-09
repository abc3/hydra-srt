#ifndef UNIX_SOCKET_H
#define UNIX_SOCKET_H

#include <sys/socket.h>
#include <sys/un.h>

extern int sock;

void init_unix_socket(const char *socket_path);
void send_message_to_unix_socket(const char *message);
void cleanup_socket(void);

#endif
