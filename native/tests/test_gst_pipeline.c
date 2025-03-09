#include <assert.h>
#include <cJSON.h>
#include <cmocka.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "../include/gst_pipeline.h"

static void test_create_pipeline(void **state)
{
    (void)state;

    gst_init(NULL, NULL);

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
