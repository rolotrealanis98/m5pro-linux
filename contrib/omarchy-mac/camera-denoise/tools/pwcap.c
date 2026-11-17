/* pwcap TARGET N: N NV12 1920x1080 frames from a PipeWire video node to stdout (memory only). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spa/param/video/format-utils.h>
#include <spa/debug/types.h>
#include <pipewire/pipewire.h>

struct data {
	struct pw_main_loop *loop;
	struct pw_stream *stream;
	int left;
	struct spa_video_info format;
};

static void on_process(void *userdata)
{
	struct data *d = userdata;
	struct pw_buffer *b = pw_stream_dequeue_buffer(d->stream);
	if (!b)
		return;
	struct spa_buffer *buf = b->buffer;
	int w = d->format.info.raw.size.width, h = d->format.info.raw.size.height;
	if (buf->datas[0].data && w == 1920 && h == 1080 && d->left > 0) {
		/* NV12: Y then UV, possibly in one or two datas */
		struct spa_data *y = &buf->datas[0];
		int sy = y->chunk->stride ? y->chunk->stride : w;
		uint8_t *py = (uint8_t *)y->data + y->chunk->offset;
		for (int r = 0; r < h; r++)
			fwrite(py + (size_t)r * sy, 1, w, stdout);
		uint8_t *puv; int suv;
		if (buf->n_datas > 1 && buf->datas[1].data) {
			puv = (uint8_t *)buf->datas[1].data + buf->datas[1].chunk->offset;
			suv = buf->datas[1].chunk->stride ? buf->datas[1].chunk->stride : w;
		} else {
			puv = py + (size_t)sy * h; suv = sy;
		}
		for (int r = 0; r < h / 2; r++)
			fwrite(puv + (size_t)r * suv, 1, w, stdout);
		d->left--;
	}
	pw_stream_queue_buffer(d->stream, b);
	if (d->left <= 0)
		pw_main_loop_quit(d->loop);
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param)
{
	struct data *d = userdata;
	if (!param || id != SPA_PARAM_Format)
		return;
	spa_format_parse(param, &d->format.media_type, &d->format.media_subtype);
	spa_format_video_raw_parse(param, &d->format.info.raw);
	fprintf(stderr, "format %s %dx%d\n",
		spa_debug_type_find_name(spa_type_video_format, d->format.info.raw.format),
		d->format.info.raw.size.width, d->format.info.raw.size.height);
}

static const struct pw_stream_events events = {
	PW_VERSION_STREAM_EVENTS,
	.param_changed = on_param_changed,
	.process = on_process,
};

int main(int argc, char **argv)
{
	struct data d = { 0 };
	uint8_t buffer[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	const struct spa_pod *params[1];

	pw_init(&argc, &argv);
	d.left = argc > 2 ? atoi(argv[2]) : 90;
	d.loop = pw_main_loop_new(NULL);
	d.stream = pw_stream_new_simple(pw_main_loop_get_loop(d.loop), "noise-probe",
		pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
				  PW_KEY_MEDIA_ROLE, "Camera", PW_KEY_TARGET_OBJECT, argv[1], NULL),
		&events, &d);
	params[0] = spa_pod_builder_add_object(&bld, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
		SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
		SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
		SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_NV12),
		SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(1920, 1080)),
		SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(30, 1)));
	pw_stream_connect(d.stream, PW_DIRECTION_INPUT, PW_ID_ANY,
			  PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
	pw_main_loop_run(d.loop);
	pw_stream_destroy(d.stream);
	pw_main_loop_destroy(d.loop);
	return 0;
}
