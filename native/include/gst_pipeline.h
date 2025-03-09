#ifndef GST_PIPELINE_H
#define GST_PIPELINE_H

#include <cJSON.h>
#include <gst/gst.h>
#include <pthread.h>
#include <unistd.h>

GstElement *create_pipeline(cJSON *json);
void cleanup_pipeline(GstElement *pipeline);
void print_srt_stats(GstElement *source);

#endif
