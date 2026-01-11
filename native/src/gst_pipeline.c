#include "gst_pipeline.h"

#include <gio/gio.h>
#include <gst/gst.h>
#include <pthread.h>
#include <srt/srt.h>
#include <string.h>

#include "unix_socket.h"

static gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config);
static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property);
static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc);

static pthread_t stats_thread;
static GstElement *source_element = NULL;
static gboolean running = TRUE;
static GMainLoop *loop = NULL;

typedef struct {
    char *id;
    char *name;
    char *schema;
    char *type;
    guint64 bytes_total;
    guint64 bytes_last_interval;
    guint64 bytes_per_sec;
    GstElement *sink_element; // only used for SRT sinks (stats property), may be NULL otherwise
} DestMetrics;

static GList *destinations_metrics = NULL;
static GMutex metrics_mutex;

static guint64 source_bytes_total = 0;
static guint64 source_bytes_last_interval = 0;
static guint64 source_bytes_per_sec = 0;

static void free_dest_metrics(gpointer data)
{
    DestMetrics *m = (DestMetrics *)data;
    if (!m) return;

    if (m->sink_element) {
        gst_object_unref(m->sink_element);
        m->sink_element = NULL;
    }

    g_free(m->id);
    g_free(m->name);
    g_free(m->schema);
    g_free(m->type);
    g_free(m);
}

static GstPadProbeReturn bytes_probe_cb(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;

    if (!(info->type & GST_PAD_PROBE_TYPE_BUFFER)) {
        return GST_PAD_PROBE_OK;
    }

    GstBuffer *buffer = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buffer) {
        return GST_PAD_PROBE_OK;
    }

    gsize size = gst_buffer_get_size(buffer);

    g_mutex_lock(&metrics_mutex);
    if (user_data == NULL) {
        source_bytes_total += (guint64)size;
    } else {
        DestMetrics *m = (DestMetrics *)user_data;
        m->bytes_total += (guint64)size;
    }
    g_mutex_unlock(&metrics_mutex);

    return GST_PAD_PROBE_OK;
}

static void add_numeric_fields_from_structure(cJSON *obj, const GstStructure *st)
{
    if (!obj || !st) return;

    gint n_fields = gst_structure_n_fields(st);
    for (gint i = 0; i < n_fields; i++) {
        const gchar *field_name = gst_structure_nth_field_name(st, i);
        const GValue *value = gst_structure_get_value(st, field_name);
        if (!value || !field_name) continue;

        if (G_VALUE_HOLDS(value, G_TYPE_INT64)) {
            cJSON_AddNumberToObject(obj, field_name, (double)g_value_get_int64(value));
        } else if (G_VALUE_HOLDS(value, G_TYPE_INT)) {
            cJSON_AddNumberToObject(obj, field_name, g_value_get_int(value));
        } else if (G_VALUE_HOLDS(value, G_TYPE_UINT64)) {
            cJSON_AddNumberToObject(obj, field_name, (double)g_value_get_uint64(value));
        } else if (G_VALUE_HOLDS(value, G_TYPE_UINT)) {
            cJSON_AddNumberToObject(obj, field_name, (double)g_value_get_uint(value));
        } else if (G_VALUE_HOLDS(value, G_TYPE_DOUBLE)) {
            cJSON_AddNumberToObject(obj, field_name, g_value_get_double(value));
        } else if (G_VALUE_HOLDS(value, G_TYPE_BOOLEAN)) {
            cJSON_AddBoolToObject(obj, field_name, g_value_get_boolean(value));
        }
    }
}

static void *print_stats(void *src)
{
    GstElement *source = (GstElement *)src;

    while (running) {
        sleep(1);

        cJSON *root = cJSON_CreateObject();

        // Compute source and destination per-second rates from byte counters.
        g_mutex_lock(&metrics_mutex);
        source_bytes_per_sec = source_bytes_total - source_bytes_last_interval;
        source_bytes_last_interval = source_bytes_total;

        for (GList *l = destinations_metrics; l != NULL; l = l->next) {
            DestMetrics *m = (DestMetrics *)l->data;
            if (!m) continue;
            m->bytes_per_sec = m->bytes_total - m->bytes_last_interval;
            m->bytes_last_interval = m->bytes_total;
        }
        g_mutex_unlock(&metrics_mutex);

        // Backward-compatible flat fields (existing UI uses these).
        // Prefer srtsrc stats if available; otherwise fall back to byte counters.
        GstStructure *stats = NULL;
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(source), "stats")) {
            g_object_get(source, "stats", &stats, NULL);
        }

        guint64 bytes_total = source_bytes_total;
        if (stats) {
            guint64 srt_bytes_total = 0;
            if (gst_structure_get_uint64(stats, "bytes-received-total", &srt_bytes_total)) {
                bytes_total = srt_bytes_total;
            }
        }
        cJSON_AddNumberToObject(root, "total-bytes-received", (double)bytes_total);

        if (stats) {
            const GValue *callers_val = gst_structure_get_value(stats, "callers");
            if (!callers_val) {
                cJSON_AddNumberToObject(root, "connected-callers", 0);
                cJSON_AddArrayToObject(root, "callers");
            } else if (G_VALUE_HOLDS(callers_val, G_TYPE_VALUE_ARRAY)) {
                GValueArray *callers_array = g_value_get_boxed(callers_val);
                gint num_callers = callers_array ? callers_array->n_values : 0;

                cJSON_AddNumberToObject(root, "connected-callers", num_callers);
                cJSON *callers = cJSON_AddArrayToObject(root, "callers");

                for (gint i = 0; i < num_callers; i++) {
                    GValue *caller_val = &callers_array->values[i];
                    if (!G_VALUE_HOLDS(caller_val, GST_TYPE_STRUCTURE)) {
                        continue;
                    }

                    const GstStructure *caller_stats = g_value_get_boxed(caller_val);
                    if (!caller_stats) {
                        continue;
                    }

                    cJSON *caller = cJSON_CreateObject();

                    gint n_fields = gst_structure_n_fields(caller_stats);
                    for (gint j = 0; j < n_fields; j++) {
                        const gchar *field_name = gst_structure_nth_field_name(caller_stats, j);
                        const GValue *value = gst_structure_get_value(caller_stats, field_name);

                        if (G_VALUE_HOLDS(value, G_TYPE_INT64)) {
                            cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_int64(value));
                        } else if (G_VALUE_HOLDS(value, G_TYPE_INT)) {
                            cJSON_AddNumberToObject(caller, field_name, g_value_get_int(value));
                        } else if (G_VALUE_HOLDS(value, G_TYPE_UINT64)) {
                            cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_uint64(value));
                        } else if (G_VALUE_HOLDS(value, G_TYPE_DOUBLE)) {
                            cJSON_AddNumberToObject(caller, field_name, g_value_get_double(value));
                        } else if (G_VALUE_HOLDS(value, G_TYPE_OBJECT) &&
                                   g_strcmp0(field_name, "caller-address") == 0) {
                            GObject *addr_obj = g_value_get_object(value);
                            if (G_IS_INET_SOCKET_ADDRESS(addr_obj)) {
                                GInetSocketAddress *addr = G_INET_SOCKET_ADDRESS(addr_obj);
                                GInetAddress *inet_addr = g_inet_socket_address_get_address(addr);
                                guint16 port = g_inet_socket_address_get_port(addr);
                                gchar *ip = g_inet_address_to_string(inet_addr);
                                gchar *addr_str = g_strdup_printf("%s:%d", ip, port);
                                cJSON_AddStringToObject(caller, field_name, addr_str);
                                g_free(ip);
                                g_free(addr_str);
                            }
                        }
                    }

                    cJSON_AddItemToArray(callers, caller);
                }
            }
        } else {
            cJSON_AddNumberToObject(root, "connected-callers", 0);
            cJSON_AddArrayToObject(root, "callers");
        }

        // New structured stats (for Overview/Statistics tabs).
        cJSON *source_obj = cJSON_AddObjectToObject(root, "source");
        cJSON_AddStringToObject(source_obj, "type", G_OBJECT_TYPE_NAME(source));
        cJSON_AddNumberToObject(source_obj, "bytes_in_total", (double)source_bytes_total);
        cJSON_AddNumberToObject(source_obj, "bytes_in_per_sec", (double)source_bytes_per_sec);
        if (stats) {
            cJSON *srt_obj = cJSON_AddObjectToObject(source_obj, "srt");
            add_numeric_fields_from_structure(srt_obj, stats);
        }

        cJSON *dests_array = cJSON_AddArrayToObject(root, "destinations");
        g_mutex_lock(&metrics_mutex);
        for (GList *l = destinations_metrics; l != NULL; l = l->next) {
            DestMetrics *m = (DestMetrics *)l->data;
            if (!m) continue;

            cJSON *d = cJSON_CreateObject();
            if (m->id) cJSON_AddStringToObject(d, "id", m->id);
            if (m->name) cJSON_AddStringToObject(d, "name", m->name);
            if (m->schema) cJSON_AddStringToObject(d, "schema", m->schema);
            if (m->type) cJSON_AddStringToObject(d, "type", m->type);
            cJSON_AddNumberToObject(d, "bytes_out_total", (double)m->bytes_total);
            cJSON_AddNumberToObject(d, "bytes_out_per_sec", (double)m->bytes_per_sec);

            if (m->sink_element && g_object_class_find_property(G_OBJECT_GET_CLASS(m->sink_element), "stats")) {
                GstStructure *sink_stats = NULL;
                g_object_get(m->sink_element, "stats", &sink_stats, NULL);
                if (sink_stats) {
                    cJSON *srt_obj = cJSON_AddObjectToObject(d, "srt");
                    add_numeric_fields_from_structure(srt_obj, sink_stats);
                    gst_structure_free(sink_stats);
                }
            }

            cJSON_AddItemToArray(dests_array, d);
        }
        g_mutex_unlock(&metrics_mutex);

        char *json_str = cJSON_PrintUnformatted(root);
        if (json_str) {
            send_message_to_unix_socket(json_str);
            free(json_str);
        }

        cJSON_Delete(root);
        if (stats) {
            gst_structure_free(stats);
        }
    }

    return NULL;
}

static gboolean bus_callback(GstBus *bus, GstMessage *msg, gpointer data)
{
    GstElement *pipeline = GST_ELEMENT(data);

    switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_ERROR: {
            GError *err;
            gchar *debug;
            gst_message_parse_error(msg, &err, &debug);
            g_print("Error: %s\n", err->message);
            g_error_free(err);
            g_free(debug);
            if (loop) g_main_loop_quit(loop);
            break;
        }
        case GST_MESSAGE_STATE_CHANGED: {
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(pipeline)) {
                GstState old_state, new_state, pending_state;
                gst_message_parse_state_changed(msg, &old_state, &new_state, &pending_state);
                g_print("Pipeline state changed from %s to %s\n", gst_element_state_get_name(old_state),
                        gst_element_state_get_name(new_state));
            }
            break;
        }
        case GST_MESSAGE_ELEMENT: {
            const GstStructure *s = gst_message_get_structure(msg);
            if (s && gst_structure_has_name(s, "GstSRTObject")) {
                g_print("SRT Event: %s\n", gst_structure_to_string(s));
            }
            break;
        }
        default:
            break;
    }
    return TRUE;
}

static void on_caller_connecting(GstElement *element, GSocketAddress *addr, const gchar *stream_id,
                                 gboolean *authenticated, gpointer user_data)
{
    g_print("\nIncoming SRT Connection1:\n");

    if (addr && G_IS_INET_SOCKET_ADDRESS(addr)) {
        GInetSocketAddress *inet_addr = G_INET_SOCKET_ADDRESS(addr);
        GInetAddress *address = g_inet_socket_address_get_address(inet_addr);
        guint16 port = g_inet_socket_address_get_port(inet_addr);
        gchar *ip = g_inet_address_to_string(address);
        g_print("  From: %s:%d\n", ip, port);
        g_free(ip);
    }

    if (stream_id) {
        g_print("  Stream ID: '%s'\n", stream_id);
    } else {
        g_print("  Stream ID: (none)\n");
    }

    if (authenticated) {
        *authenticated = TRUE;
    }

    if (stream_id) {
        gchar *msg = g_strdup_printf("stats_source_stream_id:%s", stream_id);
        send_message_to_unix_socket(msg);
        g_free(msg);
    }
}

static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc)
{
    if (strcmp(mode_str, "listener") == 0) {
        g_print("Set mode=listener (2) for %s\n", element_desc);
    } else if (strcmp(mode_str, "caller") == 0) {
        g_print("Set mode=caller (1) for %s\n", element_desc);
    } else if (strcmp(mode_str, "rendezvous") == 0) {
        g_print("Set mode=rendezvous (3) for %s\n", element_desc);
    } else {
        g_printerr("Unknown SRT mode: %s\n", mode_str);
    }
}

static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property)
{
    cJSON *property;
    cJSON_ArrayForEach(property, config)
    {
        if (strcmp(property->string, skip_property) == 0) {
            continue;
        }

        // Ignore unknown keys (e.g. Hydra metadata) to avoid g_object_set warnings/errors.
        // This also makes the pipeline tolerant to config keys that don't map to GObject properties.
        if (!g_object_class_find_property(G_OBJECT_GET_CLASS(element), property->string)) {
            continue;
        }

        if ((strcmp(element_type, "srtsrc") == 0 || strcmp(element_type, "srtsink") == 0) &&
            strcmp(property->string, "mode") == 0 && cJSON_IsString(property)) {
            set_srt_mode_property(element, property->valuestring, element_type);
            continue;
        }

        if (strcmp(element_type, "udpsink") == 0 && strcmp(property->string, "address") == 0 &&
            cJSON_IsString(property)) {
            g_object_set(element, "host", property->valuestring, NULL);
            g_print("Set host=%s for %s element\n", property->valuestring, element_type);
            continue;
        }

        if (cJSON_IsBool(property)) {
            g_object_set(element, property->string, property->valueint, NULL);
            g_print("Set %s=%s for %s element\n", property->string, property->valueint ? "true" : "false",
                    element_type);
        } else if (cJSON_IsNumber(property)) {
            g_object_set(element, property->string, property->valueint, NULL);
            g_print("Set %s=%d for %s element\n", property->string, property->valueint, element_type);
        } else if (cJSON_IsString(property)) {
            g_object_set(element, property->string, property->valuestring, NULL);
            g_print("Set %s=%s for %s element\n", property->string, property->valuestring, element_type);
        }
    }
}

GstElement *create_pipeline(cJSON *json)
{
    GstElement *pipeline, *source, *tee;

    cJSON *source_obj = cJSON_GetObjectItem(json, "source");
    cJSON *sinks_array = cJSON_GetObjectItem(json, "sinks");

    if (!cJSON_IsObject(source_obj) || !cJSON_IsArray(sinks_array)) {
        g_printerr("Invalid JSON format: missing 'source' object or 'sinks' array\n");
        return NULL;
    }

    cJSON *source_type = cJSON_GetObjectItem(source_obj, "type");
    if (!cJSON_IsString(source_type)) {
        g_printerr("Invalid JSON format: missing or invalid 'type' in source\n");
        return NULL;
    }

    pipeline = gst_pipeline_new("test-pipeline");
    source = gst_element_factory_make(source_type->valuestring, "source");
    tee = gst_element_factory_make("tee", "tee");

    if (!pipeline || !source || !tee) {
        g_printerr("Failed to create elements\n");
        return NULL;
    }

    g_object_set(tee, "allow-not-linked", TRUE, NULL);
    g_print("Set allow-not-linked=TRUE for tee element\n");

    g_print("Created source element: %s (type: %s)\n", GST_ELEMENT_NAME(source), G_OBJECT_TYPE_NAME(source));

    set_element_properties(source, source_obj, source_type->valuestring, "type");

    if (g_object_class_find_property(G_OBJECT_GET_CLASS(source), "do-timestamp")) {
        g_object_set(source, "do-timestamp", TRUE, NULL);
        g_print("Set do-timestamp=TRUE for source element\n");
    }

    if (g_strcmp0(source_type->valuestring, "srtsrc") == 0) {
        // Only enable authentication when streamid is provided. Enabling it unconditionally
        // causes some callers (e.g. ffmpeg) to be rejected when streamid is empty.
        cJSON *streamid = cJSON_GetObjectItem(source_obj, "streamid");
        gboolean auth = (cJSON_IsString(streamid) && streamid->valuestring && strlen(streamid->valuestring) > 0);
        g_object_set(source, "authentication", auth, NULL);
        g_signal_connect(source, "caller-connecting", G_CALLBACK(on_caller_connecting), NULL);
    }

    gst_bin_add_many(GST_BIN(pipeline), source, tee, NULL);
    if (!gst_element_link(source, tee)) {
        g_printerr("Elements could not be linked.\n");
        gst_object_unref(pipeline);
        return NULL;
    }

    // Track incoming bytes for any source type (SRT/UDP/...)
    GstPad *srcpad = gst_element_get_static_pad(source, "src");
    if (srcpad) {
        gst_pad_add_probe(srcpad, GST_PAD_PROBE_TYPE_BUFFER, bytes_probe_cb, NULL, NULL);
        gst_object_unref(srcpad);
    }

    cJSON *sink;
    cJSON_ArrayForEach(sink, sinks_array)
    {
        if (!add_sink_to_pipeline(pipeline, tee, sink)) {
            gst_object_unref(pipeline);
            return NULL;
        }
    }

    loop = g_main_loop_new(NULL, FALSE);

    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, bus_callback, pipeline);
    gst_object_unref(bus);

    source_element = source;

    running = TRUE;
    if (pthread_create(&stats_thread, NULL, print_stats, source) != 0) {
        g_printerr("Failed to create stats thread\n");
    }

    return pipeline;
}

gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config)
{
    cJSON *sink_type = cJSON_GetObjectItem(sink_config, "type");

    if (!cJSON_IsString(sink_type)) {
        g_printerr("Invalid sink format: missing or invalid 'type'\n");
        return FALSE;
    }

    GstElement *queue = gst_element_factory_make("queue", NULL);
    GstElement *sink_element = gst_element_factory_make(sink_type->valuestring, NULL);

    if (!queue || !sink_element) {
        g_printerr("Could not create sink elements.\n");
        return FALSE;
    }

    g_object_set(queue, "max-size-buffers", 200, NULL);
    g_object_set(queue, "max-size-time", 0, NULL);

    set_element_properties(sink_element, sink_config, sink_type->valuestring, "type");

    if (strcmp(sink_type->valuestring, "udpsink") == 0) {
        g_object_set(sink_element, "sync", FALSE, NULL);
        g_object_set(sink_element, "async", FALSE, NULL);
        g_print("Configured UDP sink with sync=FALSE, async=FALSE\n");
    }

    if (strcmp(sink_type->valuestring, "srtsink") == 0) {
        g_object_set(sink_element, "async", FALSE, NULL);
        g_object_set(sink_element, "sync", FALSE, NULL);
        g_object_set(sink_element, "wait-for-connection", TRUE, NULL);
        g_print("Configured SRT sink with async=FALSE, sync=FALSE, wait-for-connection=TRUE\n");
    }

    gst_bin_add_many(GST_BIN(pipeline), queue, sink_element, NULL);
    if (!gst_element_link_many(tee, queue, sink_element, NULL)) {
        g_printerr("Could not link sink elements.\n");
        return FALSE;
    }

    // Create per-destination metrics entry for this sink
    DestMetrics *m = (DestMetrics *)g_malloc0(sizeof(DestMetrics));
    cJSON *dest_id = cJSON_GetObjectItem(sink_config, "hydra_destination_id");
    cJSON *dest_name = cJSON_GetObjectItem(sink_config, "hydra_destination_name");
    cJSON *dest_schema = cJSON_GetObjectItem(sink_config, "hydra_destination_schema");
    if (cJSON_IsString(dest_id)) m->id = g_strdup(dest_id->valuestring);
    if (cJSON_IsString(dest_name)) m->name = g_strdup(dest_name->valuestring);
    if (cJSON_IsString(dest_schema)) m->schema = g_strdup(dest_schema->valuestring);
    m->type = g_strdup(sink_type->valuestring);
    m->bytes_total = 0;
    m->bytes_last_interval = 0;
    m->bytes_per_sec = 0;

    if (strcmp(sink_type->valuestring, "srtsink") == 0) {
        m->sink_element = gst_object_ref(sink_element);
    }

    // Track outgoing bytes for this sink using queue src pad probe
    GstPad *qsrcpad = gst_element_get_static_pad(queue, "src");
    if (qsrcpad) {
        gst_pad_add_probe(qsrcpad, GST_PAD_PROBE_TYPE_BUFFER, bytes_probe_cb, m, NULL);
        gst_object_unref(qsrcpad);
    }

    g_mutex_lock(&metrics_mutex);
    destinations_metrics = g_list_append(destinations_metrics, m);
    g_mutex_unlock(&metrics_mutex);

    return TRUE;
}

void cleanup_pipeline(GstElement *pipeline)
{
    running = FALSE;
    pthread_join(stats_thread, NULL);

    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);

    if (loop) {
        g_main_loop_unref(loop);
        loop = NULL;
    }

    g_mutex_lock(&metrics_mutex);
    if (destinations_metrics) {
        g_list_free_full(destinations_metrics, free_dest_metrics);
        destinations_metrics = NULL;
    }
    source_bytes_total = 0;
    source_bytes_last_interval = 0;
    source_bytes_per_sec = 0;
    g_mutex_unlock(&metrics_mutex);
}
