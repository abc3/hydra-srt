#include <assert.h>
#include <cjson/cJSON.h>
#include <setjmp.h>
#include <stdarg.h>
#include <cmocka.h>
#include <stdlib.h>
#include <string.h>

#include "../include/gst_pipeline.h"

#if defined(__GNUC__)
#define HYDRA_UNUSED __attribute__((unused))
#else
#define HYDRA_UNUSED
#endif

static void test_create_pipeline(void **state) HYDRA_UNUSED;
static void test_create_pipeline(void **state)
{
    (void)state;

    gst_init(NULL, NULL);

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
}
