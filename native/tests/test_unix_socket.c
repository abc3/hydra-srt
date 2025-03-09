#include <assert.h>
#include <cJSON.h>
#include <cmocka.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "../include/gst_pipeline.h"
#include "../include/unix_socket.h"

static void test_init_unix_socket(void **state)
{
    (void)state;

    init_unix_socket("/tmp/hydra_unix_sock");
    assert_int_not_equal(sock, -1);
}

static void test_send_message_to_unix_socket(void **state)
{
    (void)state;

    init_unix_socket("/tmp/hydra_unix_sock");
    send_message_to_unix_socket("Test message");
}

static void test_cleanup_socket(void **state)
{
    (void)state;

    init_unix_socket("/tmp/hydra_unix_sock");
    cleanup_socket();
    assert_int_equal(sock, -1);
}

static void test_create_pipeline(void **state)
{
    (void)state;

    const char *json_str =
        "{\"source\":{\"type\":\"srtsrc\",\"localaddress\":\"127.0.0.1\",\"localport\":8000,\"auto-reconnect\":true,"
        "\"keep-listening\":false,\"mode\":\"listener\"},\"sinks\":[{\"type\":\"srtsink\",\"localaddress\":\"127.0.0."
        "1\",\"localport\":8002,"
        "\"mode\":\"listener\"},{\"type\":\"udpsink\",\"host\":\"127.0.0.1\",\"port\":8003}]}";
    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);

    GstElement *pipeline = create_pipeline(json);
    assert_non_null(pipeline);

    cleanup_pipeline(pipeline);
    cJSON_Delete(json);
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
