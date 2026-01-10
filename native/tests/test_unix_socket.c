#include <assert.h>
#include <cjson/cJSON.h>
#include <errno.h>
#include <stdio.h>
#include <setjmp.h>
#include <stdarg.h>
#include <cmocka.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../include/gst_pipeline.h"
#include "../include/unix_socket.h"

static void make_socket_path(char *buf, size_t size)
{
    snprintf(buf, size, "/tmp/hydra_unix_sock_test_%d", getpid());
}

static int start_unix_server(const char *path)
{
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert_int_not_equal(server_fd, -1);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    // Ensure path is free
    unlink(path);

    int rc = bind(server_fd, (struct sockaddr *)&addr, sizeof(addr));
    assert_int_equal(rc, 0);

    rc = listen(server_fd, 1);
    assert_int_equal(rc, 0);

    return server_fd;
}

static int accept_one(int server_fd)
{
    int client_fd = accept(server_fd, NULL, NULL);
    assert_int_not_equal(client_fd, -1);
    return client_fd;
}

static void test_init_unix_socket(void **state)
{
    (void)state;

    char path[108];
    make_socket_path(path, sizeof(path));
    int server_fd = start_unix_server(path);

    init_unix_socket(path);
    int client_fd = accept_one(server_fd);

    assert_int_not_equal(sock, -1);

    close(client_fd);
    close(server_fd);
    cleanup_socket();
    unlink(path);
}

static void test_send_message_to_unix_socket(void **state)
{
    (void)state;

    char path[108];
    make_socket_path(path, sizeof(path));
    int server_fd = start_unix_server(path);

    init_unix_socket(path);
    int client_fd = accept_one(server_fd);

    send_message_to_unix_socket("Test message");

    close(client_fd);
    close(server_fd);
    cleanup_socket();
    unlink(path);
}

static void test_cleanup_socket(void **state)
{
    (void)state;

    char path[108];
    make_socket_path(path, sizeof(path));
    int server_fd = start_unix_server(path);

    init_unix_socket(path);
    int client_fd = accept_one(server_fd);

    cleanup_socket();
    assert_int_equal(sock, -1);

    close(client_fd);
    close(server_fd);
    unlink(path);
}

static void test_create_pipeline(void **state)
{
    (void)state;

    char path[108];
    make_socket_path(path, sizeof(path));
    int server_fd = start_unix_server(path);

    init_unix_socket(path);
    int client_fd = accept_one(server_fd);

    const char *json_str =
        "{\"source\":{\"type\":\"fakesrc\"},\"sinks\":["
        "{\"type\":\"fakesink\",\"hydra_destination_id\":\"dest1\",\"hydra_destination_name\":\"Destination 1\","
        "\"hydra_destination_schema\":\"SRT\"},"
        "{\"type\":\"fakesink\",\"hydra_destination_id\":\"dest2\",\"hydra_destination_name\":\"Destination 2\","
        "\"hydra_destination_schema\":\"UDP\"}]}";
    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);

    GstElement *pipeline = create_pipeline(json);
    assert_non_null(pipeline);

    cleanup_pipeline(pipeline);
    cJSON_Delete(json);

    close(client_fd);
    close(server_fd);
    cleanup_socket();
    unlink(path);
}

int main(void)
{
    gst_init(NULL, NULL);

    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_init_unix_socket),
        cmocka_unit_test(test_send_message_to_unix_socket),
        cmocka_unit_test(test_cleanup_socket),
        cmocka_unit_test(test_create_pipeline),
    };
    return cmocka_run_group_tests(tests, NULL, NULL);
}
