// SPDX-License-Identifier: MIT
/*
 * kms-flip: set a mode on one connector with the atomic API (or legacy
 * SETCRTC with --legacy) and page-flip two dumb XRGB8888 buffers for N
 * seconds, printing the real errno of every failing ioctl and the flip
 * cadence from the kernel's page-flip event timestamps.
 *
 *   kms-flip [-d /dev/dri/card1] [-c CONNECTOR_ID] [-m MODE_INDEX] [-t SECONDS] [--legacy] [--test-only]
 *
 * Mode index as in `modetest -c` (#0 = first). No libdrm: kernel uapi only,
 * so it builds static: gcc -O2 -static -o kms-flip kms-flip.c
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

static int fd;

static int xioctl(unsigned long req, void *arg, const char *what)
{
	int ret;

	do
		ret = ioctl(fd, req, arg);
	while (ret == -1 && (errno == EINTR || errno == EAGAIN));
	if (ret)
		fprintf(stderr, "%s: %s (errno %d)\n", what, strerror(errno), errno);
	return ret;
}

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name, uint64_t *value)
{
	struct drm_mode_obj_get_properties gp = { .obj_id = obj, .obj_type = type };
	uint32_t *ids;
	uint64_t *vals;
	uint32_t found = 0;

	if (xioctl(DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &gp, "OBJ_GETPROPERTIES"))
		exit(1);
	ids = calloc(gp.count_props, 4);
	vals = calloc(gp.count_props, 8);
	gp.props_ptr = (uintptr_t)ids;
	gp.prop_values_ptr = (uintptr_t)vals;
	if (xioctl(DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &gp, "OBJ_GETPROPERTIES"))
		exit(1);
	for (uint32_t i = 0; i < gp.count_props && !found; i++) {
		struct drm_mode_get_property p = { .prop_id = ids[i] };

		if (!xioctl(DRM_IOCTL_MODE_GETPROPERTY, &p, "GETPROPERTY") &&
		    !strcmp(p.name, name)) {
			found = ids[i];
			if (value)
				*value = vals[i];
		}
	}
	free(ids);
	free(vals);
	return found;
}

struct fb { uint32_t id, handle, pitch; uint64_t size; uint8_t *map; };

static void make_fb(struct fb *f, uint32_t w, uint32_t h, uint32_t color)
{
	struct drm_mode_create_dumb c = { .width = w, .height = h, .bpp = 32 };
	struct drm_mode_map_dumb m = { 0 };
	struct drm_mode_fb_cmd2 a = { .width = w, .height = h,
				      .pixel_format = 0x34325258 /* XR24 */ };

	if (xioctl(DRM_IOCTL_MODE_CREATE_DUMB, &c, "CREATE_DUMB"))
		exit(1);
	f->handle = c.handle;
	f->pitch = c.pitch;
	f->size = c.size;
	m.handle = c.handle;
	if (xioctl(DRM_IOCTL_MODE_MAP_DUMB, &m, "MAP_DUMB"))
		exit(1);
	f->map = mmap(NULL, c.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
	if (f->map == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	for (uint64_t i = 0; i < c.size / 4; i++)
		((uint32_t *)f->map)[i] = color;
	a.handles[0] = c.handle;
	a.pitches[0] = c.pitch;
	if (xioctl(DRM_IOCTL_MODE_ADDFB2, &a, "ADDFB2"))
		exit(1);
	f->id = a.fb_id;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/dri/card1";
	uint32_t conn_id = 0, mode_idx = 0, crtc_id = 0, plane_id = 0;
	int secs = 8, legacy = 0, test_only = 0;
	struct drm_mode_card_res res = { 0 };
	struct drm_mode_get_connector gc = { 0 };
	struct drm_mode_modeinfo *modes;
	struct drm_mode_get_encoder enc = { 0 };
	struct fb fbs[2];
	double *iv;
	unsigned int flips = 0, cap;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-d") && i + 1 < argc) dev = argv[++i];
		else if (!strcmp(argv[i], "-c") && i + 1 < argc) conn_id = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-m") && i + 1 < argc) mode_idx = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-t") && i + 1 < argc) secs = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--legacy")) legacy = 1;
		else if (!strcmp(argv[i], "--test-only")) test_only = 1;
		else { fprintf(stderr, "usage: see the source header\n"); return 2; }
	}
	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror(dev); return 1; }
	if (!legacy) {
		struct drm_set_client_cap cc = { DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1 };

		xioctl(DRM_IOCTL_SET_CLIENT_CAP, &cc, "CAP_UNIVERSAL_PLANES");
		cc.capability = DRM_CLIENT_CAP_ATOMIC;
		if (xioctl(DRM_IOCTL_SET_CLIENT_CAP, &cc, "CAP_ATOMIC"))
			return 1;
	}
	if (xioctl(DRM_IOCTL_MODE_GETRESOURCES, &res, "GETRESOURCES"))
		return 1;
	{
		uint32_t *conns = calloc(res.count_connectors, 4), *crtcs = calloc(res.count_crtcs, 4);

		res.connector_id_ptr = (uintptr_t)conns;
		res.crtc_id_ptr = (uintptr_t)crtcs;
		res.count_fbs = res.count_encoders = 0;
		if (xioctl(DRM_IOCTL_MODE_GETRESOURCES, &res, "GETRESOURCES"))
			return 1;
		if (!conn_id)
			conn_id = conns[0];
		crtc_id = crtcs[0];
	}
	gc.connector_id = conn_id;
	if (xioctl(DRM_IOCTL_MODE_GETCONNECTOR, &gc, "GETCONNECTOR"))
		return 1;
	modes = calloc(gc.count_modes, sizeof(*modes));
	gc.modes_ptr = (uintptr_t)modes;
	gc.count_props = gc.count_encoders = 0;
	if (xioctl(DRM_IOCTL_MODE_GETCONNECTOR, &gc, "GETCONNECTOR"))
		return 1;
	if (mode_idx >= gc.count_modes) {
		fprintf(stderr, "connector %u has %u modes\n", conn_id, gc.count_modes);
		return 1;
	}
	if (gc.encoder_id) {
		enc.encoder_id = gc.encoder_id;
		if (!xioctl(DRM_IOCTL_MODE_GETENCODER, &enc, "GETENCODER") && enc.crtc_id)
			crtc_id = enc.crtc_id;
	}
	{
		struct drm_mode_modeinfo *m = &modes[mode_idx];

		printf("connector %u crtc %u mode #%u %s %ux%u clock %u kHz totals %ux%u = %.3f Hz\n",
		       conn_id, crtc_id, mode_idx, m->name, m->hdisplay, m->vdisplay, m->clock,
		       m->htotal, m->vtotal, m->clock * 1000.0 / ((double)m->htotal * m->vtotal));
	}
	make_fb(&fbs[0], modes[mode_idx].hdisplay, modes[mode_idx].vdisplay, 0xff202040);
	make_fb(&fbs[1], modes[mode_idx].hdisplay, modes[mode_idx].vdisplay, 0xff402020);

	if (legacy) {
		struct drm_mode_crtc sc = { .crtc_id = crtc_id, .fb_id = fbs[0].id,
					    .set_connectors_ptr = (uintptr_t)&conn_id,
					    .count_connectors = 1, .mode_valid = 1,
					    .mode = modes[mode_idx] };

		if (xioctl(DRM_IOCTL_MODE_SETCRTC, &sc, "SETCRTC"))
			return 1;
	} else {
		struct drm_mode_get_plane_res pr = { 0 };
		struct drm_mode_create_blob blob = { .data = (uintptr_t)&modes[mode_idx],
						     .length = sizeof(modes[0]) };
		uint32_t objs[3], counts[3], props[16];
		uint64_t vals[16];
		uint32_t *planes, w = modes[mode_idx].hdisplay, h = modes[mode_idx].vdisplay;
		struct drm_mode_atomic at = { 0 };
		int n = 0;

		if (xioctl(DRM_IOCTL_MODE_GETPLANERESOURCES, &pr, "GETPLANERESOURCES"))
			return 1;
		planes = calloc(pr.count_planes, 4);
		pr.plane_id_ptr = (uintptr_t)planes;
		if (xioctl(DRM_IOCTL_MODE_GETPLANERESOURCES, &pr, "GETPLANERESOURCES"))
			return 1;
		for (uint32_t i = 0; i < pr.count_planes && !plane_id; i++) {
			uint64_t type = 0;

			if (prop_id(planes[i], DRM_MODE_OBJECT_PLANE, "type", &type) &&
			    type == 1 /* DRM_PLANE_TYPE_PRIMARY */)
				plane_id = planes[i];
		}
		if (xioctl(DRM_IOCTL_MODE_CREATEPROPBLOB, &blob, "CREATEPROPBLOB"))
			return 1;
		objs[0] = conn_id; counts[0] = 1;
		props[n] = prop_id(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", NULL); vals[n++] = crtc_id;
		objs[1] = crtc_id; counts[1] = 2;
		props[n] = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID", NULL); vals[n++] = blob.blob_id;
		props[n] = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE", NULL); vals[n++] = 1;
		objs[2] = plane_id; counts[2] = 9;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", NULL); vals[n++] = fbs[0].id;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", NULL); vals[n++] = crtc_id;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X", NULL); vals[n++] = 0;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y", NULL); vals[n++] = 0;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W", NULL); vals[n++] = (uint64_t)w << 16;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H", NULL); vals[n++] = (uint64_t)h << 16;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X", NULL); vals[n++] = 0;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W", NULL); vals[n++] = w;
		props[n] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H", NULL); vals[n++] = h;
		/* CRTC_Y stays at its current value (0). */
		printf("primary plane %u, mode blob %u\n", plane_id, blob.blob_id);
		at.flags = DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_ATOMIC_TEST_ONLY;
		at.count_objs = 3;
		at.objs_ptr = (uintptr_t)objs;
		at.count_props_ptr = (uintptr_t)counts;
		at.props_ptr = (uintptr_t)props;
		at.prop_values_ptr = (uintptr_t)vals;
		if (xioctl(DRM_IOCTL_MODE_ATOMIC, &at, "ATOMIC test-only modeset"))
			return 1;
		printf("test-only modeset accepted\n");
		if (test_only)
			return 0;
		at.flags = DRM_MODE_ATOMIC_ALLOW_MODESET;
		if (xioctl(DRM_IOCTL_MODE_ATOMIC, &at, "ATOMIC modeset"))
			return 1;
		/* Flips below change only FB_ID. */
		objs[0] = plane_id; counts[0] = 1;
		props[0] = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", NULL);
		at.count_objs = 1;
		at.flags = DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK;
		cap = (unsigned int)secs * 1000;
		iv = calloc(cap, sizeof(*iv));
		{
			double end = now() + secs, last = 0;
			unsigned int cur = 1;

			while (now() < end && flips < cap) {
				struct pollfd p = { .fd = fd, .events = POLLIN };
				char buf[256];

				vals[0] = fbs[cur].id;
				if (xioctl(DRM_IOCTL_MODE_ATOMIC, &at, "ATOMIC flip"))
					return 1;
				if (poll(&p, 1, 1000) != 1) {
					fprintf(stderr, "no flip event within 1 s after %u flips\n", flips);
					return 1;
				}
				if (read(fd, buf, sizeof(buf)) >= (ssize_t)sizeof(struct drm_event_vblank)) {
					struct drm_event_vblank *e = (void *)buf;
					double t = e->tv_sec + e->tv_usec / 1e6;

					if (last)
						iv[flips - 1] = (t - last) * 1000;
					last = t;
					flips++;
				}
				cur ^= 1;
			}
		}
		if (flips > 2) {
			unsigned int k = flips - 1;

			qsort(iv, k, sizeof(*iv), cmp);
			printf("%u flips in %d s = %.2f fps; event interval ms p1 %.3f p50 %.3f p99 %.3f max %.3f\n",
			       flips, secs, flips / (double)secs, iv[k / 100], iv[k / 2],
			       iv[k * 99 / 100], iv[k - 1]);
		}
		return 0;
	}
	printf("legacy SETCRTC accepted; holding %d s\n", secs);
	sleep(secs);
	return 0;
}
