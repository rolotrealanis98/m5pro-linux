// SPDX-License-Identifier: MIT
/*
 * vrrflip: atomic KMS test for VRR_ENABLED on the internal panel.
 *
 *   vrrflip [-d /dev/dri/card1] [-m WxH@R] [-s seconds] [-o intervals.csv]
 *
 * Sets WxH@R (default 3456x2234@120) with one atomic mode set, then keeps
 * page-flipping a moving bar and walks these phases (each -s seconds,
 * default 8):
 *   fixed        VRR_ENABLED 0, flip as fast as the display allows
 *   vrr-on       VRR_ENABLED 1 set in a plain flip (no ALLOW_MODESET)
 *   vrr-on-50    VRR_ENABLED 1, flips paced at 50 fps
 *   vrr-off      VRR_ENABLED 0 set in a plain flip
 *   vrr-off-50   VRR_ENABLED 0, flips paced at 50 fps
 * A plain-flip VRR_ENABLED change that the kernel rejects is retried with
 * ALLOW_MODESET and reported. Per phase it prints the flip-event count,
 * fps and the interval spread (from the page-flip event timestamps), and
 * writes "vrrflip: phase <name>" to the ftrace trace_marker and /dev/kmsg,
 * so vrrflip-run.sh can count dcp:iomfb_swap_complete per phase.
 *
 * Expected on a working panel: fixed and vrr-on about 120 fps (p50 8.3 ms);
 * vrr-on-50 p50 about 20 ms (VRR follows the content: 20.8 ms, 5 x 4.17 ms
 * subframes) where vrr-off-50 alternates 16.7 and 25 ms (p50 16.7 or 25,
 * max - min about 8.3 ms).
 *
 * Build on the target: cc -O2 -o vrrflip vrrflip.c $(pkg-config --cflags --libs libdrm) -lm
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define MAX_IV 8192
#define BAR_W 96

struct buf {
	uint32_t handle, pitch, fb;
	uint64_t size;
	uint8_t *map;
	int bar_x;		/* bar drawn in this buffer, -1 none */
};

struct phase {
	const char *name;
	int vrr;
	int fps_cap;
};

static const struct phase phases[] = {
	{ "fixed", 0, 0 },
	{ "vrr-on", 1, 0 },
	{ "vrr-on-50", 1, 50 },
	{ "vrr-off", 0, 0 },
	{ "vrr-off-50", 0, 50 },
};

static int fd, marker_fd = -1, kmsg_fd = -1;
static uint32_t conn_id, crtc_id, plane_id;
static drmModeModeInfo mode;
static struct buf bufs[2];
static int pending;
static double last_ev, iv[MAX_IV];
static int niv;

static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, " (%s)\n", strerror(errno));
	exit(1);
}

static void mark(const char *fmt, ...)
{
	char s[160];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(s, sizeof(s), fmt, ap);
	va_end(ap);
	printf("%s\n", s);
	fflush(stdout);
	if (marker_fd >= 0 && write(marker_fd, s, n) < 0)
		;
	if (kmsg_fd >= 0 && write(kmsg_fd, s, n) < 0)
		;
}

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name)
{
	drmModeObjectProperties *p = drmModeObjectGetProperties(fd, obj, type);
	uint32_t id = 0;

	for (uint32_t i = 0; p && i < p->count_props && !id; i++) {
		drmModePropertyRes *r = drmModeGetProperty(fd, p->props[i]);

		if (r && !strcmp(r->name, name))
			id = r->prop_id;
		drmModeFreeProperty(r);
	}
	drmModeFreeObjectProperties(p);
	if (!id)
		die("object %u has no property %s", obj, name);
	return id;
}

static uint64_t prop_value(uint32_t obj, uint32_t type, const char *name, int *found)
{
	drmModeObjectProperties *p = drmModeObjectGetProperties(fd, obj, type);
	uint64_t v = 0;

	*found = 0;
	for (uint32_t i = 0; p && i < p->count_props; i++) {
		drmModePropertyRes *r = drmModeGetProperty(fd, p->props[i]);

		if (r && !strcmp(r->name, name)) {
			v = p->prop_values[i];
			*found = 1;
		}
		drmModeFreeProperty(r);
	}
	drmModeFreeObjectProperties(p);
	return v;
}

static void pick_objects(const char *want)
{
	drmModeRes *res = drmModeGetResources(fd);
	drmModePlaneRes *pres;
	unsigned int w = 3456, h = 2234, r = 120;
	int found;

	if (!res)
		die("drmModeGetResources");
	if (want && sscanf(want, "%ux%u@%u", &w, &h, &r) != 3)
		die("bad -m %s", want);
	for (int i = 0; i < res->count_connectors && !conn_id; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);

		if (c && c->connection == DRM_MODE_CONNECTED &&
		    c->connector_type == DRM_MODE_CONNECTOR_eDP) {
			for (int m = 0; m < c->count_modes; m++) {
				drmModeModeInfo *mi = &c->modes[m];

				printf("mode %d: %s %u Hz clock %u vtotal %u%s\n", m, mi->name,
				       mi->vrefresh, mi->clock, mi->vtotal,
				       mi->type & DRM_MODE_TYPE_PREFERRED ? " preferred" : "");
				if (!conn_id && mi->hdisplay == w && mi->vdisplay == h &&
				    mi->vrefresh == r) {
					mode = *mi;
					conn_id = c->connector_id;
				}
			}
			if (conn_id) {
				drmModeEncoder *e = drmModeGetEncoder(fd, c->encoders[0]);

				for (int k = 0; e && k < res->count_crtcs; k++)
					if (e->possible_crtcs & (1u << k)) {
						crtc_id = res->crtcs[k];
						break;
					}
				drmModeFreeEncoder(e);
			}
		}
		drmModeFreeConnector(c);
	}
	if (!conn_id || !crtc_id)
		die("no connected eDP connector with %ux%u@%u", w, h, r);

	pres = drmModeGetPlaneResources(fd);
	for (uint32_t i = 0; pres && i < pres->count_planes && !plane_id; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pres->planes[i]);
		int crtc_idx = -1;

		for (int k = 0; k < res->count_crtcs; k++)
			if (res->crtcs[k] == crtc_id)
				crtc_idx = k;
		if (p && crtc_idx >= 0 && (p->possible_crtcs & (1u << crtc_idx)) &&
		    prop_value(p->plane_id, DRM_MODE_OBJECT_PLANE, "type", &found) ==
		    DRM_PLANE_TYPE_PRIMARY && found)
			plane_id = p->plane_id;
		drmModeFreePlane(p);
	}
	drmModeFreePlaneResources(pres);
	drmModeFreeResources(res);
	if (!plane_id)
		die("no primary plane for CRTC %u", crtc_id);
	printf("connector %u crtc %u plane %u mode %s@%u vrr_capable %llu\n",
	       conn_id, crtc_id, plane_id, mode.name, mode.vrefresh,
	       (unsigned long long)prop_value(conn_id, DRM_MODE_OBJECT_CONNECTOR,
					      "vrr_capable", &found));
}

static void make_buf(struct buf *b)
{
	struct drm_mode_create_dumb cd = { .width = mode.hdisplay,
					   .height = mode.vdisplay, .bpp = 32 };
	struct drm_mode_map_dumb md = { 0 };
	uint32_t handles[4] = { 0 }, pitches[4] = { 0 }, offsets[4] = { 0 };

	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd))
		die("CREATE_DUMB");
	b->handle = cd.handle;
	b->pitch = cd.pitch;
	b->size = cd.size;
	md.handle = cd.handle;
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md))
		die("MAP_DUMB");
	b->map = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
	if (b->map == MAP_FAILED)
		die("mmap");
	for (uint32_t y = 0; y < mode.vdisplay; y++)
		for (uint32_t x = 0; x < mode.hdisplay; x++)
			((uint32_t *)(b->map + y * b->pitch))[x] = 0xff202020 | ((x / 256) & 1) * 0x101010;
	b->bar_x = -1;
	handles[0] = b->handle;
	pitches[0] = b->pitch;
	if (drmModeAddFB2(fd, mode.hdisplay, mode.vdisplay, DRM_FORMAT_XRGB8888,
			  handles, pitches, offsets, &b->fb, 0))
		die("AddFB2");
}

static void draw_bar(struct buf *b, int x, uint32_t color)
{
	for (uint32_t y = 0; y < mode.vdisplay; y++) {
		uint32_t *row = (uint32_t *)(b->map + y * b->pitch);

		for (int i = 0; i < BAR_W && x + i < mode.hdisplay; i++)
			row[x + i] = color;
	}
}

static void paint(struct buf *b, int frame)
{
	int x = (frame * 24) % (mode.hdisplay - BAR_W);

	if (b->bar_x >= 0)
		for (uint32_t y = 0; y < mode.vdisplay; y++) {
			uint32_t *row = (uint32_t *)(b->map + y * b->pitch);

			for (int i = 0; i < BAR_W; i++)
				row[b->bar_x + i] = 0xff202020 | (((b->bar_x + i) / 256) & 1) * 0x101010;
		}
	draw_bar(b, x, 0xffe0e0e0);
	b->bar_x = x;
}

static void on_flip(int f, unsigned int seq, unsigned int sec, unsigned int usec,
		    unsigned int crtc, void *data)
{
	double t = sec + usec / 1e6;

	(void)f; (void)seq; (void)crtc; (void)data;
	if (last_ev > 0 && niv < MAX_IV)
		iv[niv++] = (t - last_ev) * 1e3;
	last_ev = t;
	pending = 0;
}

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int commit_flip(struct buf *b, int set_vrr, int vrr, uint32_t p_fb, uint32_t p_vrr,
		       uint32_t flags)
{
	drmModeAtomicReq *req = drmModeAtomicAlloc();
	int ret;

	drmModeAtomicAddProperty(req, plane_id, p_fb, b->fb);
	if (set_vrr)
		drmModeAtomicAddProperty(req, crtc_id, p_vrr, vrr);
	ret = drmModeAtomicCommit(fd, req, flags, NULL);
	drmModeAtomicFree(req);
	return ret ? -errno : 0;
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/dri/card1", *want = NULL, *csv = NULL;
	drmEventContext ev = { .version = 3, .page_flip_handler2 = on_flip };
	uint32_t p_fb, p_crtc, p_mode, p_active, p_vrr, p_conn_crtc, blob;
	int secs = 8, opt, frame = 0, cur = 0, vrr_now = 0, rc = 0;
	FILE *out = NULL;

	while ((opt = getopt(argc, argv, "d:m:s:o:")) != -1) {
		if (opt == 'd')
			dev = optarg;
		else if (opt == 'm')
			want = optarg;
		else if (opt == 's')
			secs = atoi(optarg);
		else if (opt == 'o')
			csv = optarg;
		else
			return 2;
	}
	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		die("open %s", dev);
	if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
	    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1))
		die("atomic client caps");
	if (drmSetMaster(fd))
		die("drmSetMaster (stop the compositor first)");
	marker_fd = open("/sys/kernel/tracing/trace_marker", O_WRONLY | O_CLOEXEC);
	kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (csv && !(out = fopen(csv, "w")))
		die("open %s", csv);

	pick_objects(want);
	make_buf(&bufs[0]);
	make_buf(&bufs[1]);
	p_fb = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID");
	p_crtc = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
	p_mode = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
	p_active = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
	p_vrr = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "VRR_ENABLED");
	p_conn_crtc = prop_id(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
	if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &blob))
		die("mode blob");

	/* One blocking mode set: mode, connector, primary plane, VRR off. */
	{
		drmModeAtomicReq *req = drmModeAtomicAlloc();
		struct { const char *n; uint64_t v; } pl[] = {
			{ "SRC_X", 0 }, { "SRC_Y", 0 },
			{ "SRC_W", (uint64_t)mode.hdisplay << 16 },
			{ "SRC_H", (uint64_t)mode.vdisplay << 16 },
			{ "CRTC_X", 0 }, { "CRTC_Y", 0 },
			{ "CRTC_W", mode.hdisplay }, { "CRTC_H", mode.vdisplay },
		};

		paint(&bufs[0], frame++);
		drmModeAtomicAddProperty(req, crtc_id, p_mode, blob);
		drmModeAtomicAddProperty(req, crtc_id, p_active, 1);
		drmModeAtomicAddProperty(req, crtc_id, p_vrr, 0);
		drmModeAtomicAddProperty(req, conn_id, p_conn_crtc, crtc_id);
		drmModeAtomicAddProperty(req, plane_id, p_crtc, crtc_id);
		drmModeAtomicAddProperty(req, plane_id, p_fb, bufs[0].fb);
		for (unsigned int i = 0; i < sizeof(pl) / sizeof(pl[0]); i++)
			drmModeAtomicAddProperty(req, plane_id,
						 prop_id(plane_id, DRM_MODE_OBJECT_PLANE, pl[i].n),
						 pl[i].v);
		mark("vrrflip: modeset %s@%u", mode.name, mode.vrefresh);
		if (drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL))
			die("mode set commit failed (check dmesg: 'IOMFB transaction timed out' latches the DCP as crashed)");
		drmModeAtomicFree(req);
	}

	for (unsigned int ph = 0; ph < sizeof(phases) / sizeof(phases[0]); ph++) {
		const struct phase *p = &phases[ph];
		double t0 = now(), next = t0, p50, mn, mx, sum = 0;
		int set_vrr = p->vrr != vrr_now, flips = 0;

		niv = 0;
		last_ev = 0;
		mark("vrrflip: phase %s", p->name);
		while (now() - t0 < secs) {
			struct buf *b = &bufs[cur ^ 1];
			uint32_t flags = DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK;
			int ret;

			if (p->fps_cap) {
				struct timespec ts;

				next += 1.0 / p->fps_cap;
				ts.tv_sec = (time_t)next;
				ts.tv_nsec = (long)((next - ts.tv_sec) * 1e9);
				clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
			}
			paint(b, frame++);
			ret = commit_flip(b, set_vrr, p->vrr, p_fb, p_vrr, flags);
			if (ret && set_vrr) {
				mark("vrrflip: plain-flip VRR_ENABLED %d rejected (%s), retrying with ALLOW_MODESET",
				     p->vrr, strerror(-ret));
				ret = commit_flip(b, 1, p->vrr, p_fb, p_vrr,
						  DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_ALLOW_MODESET);
				rc = 1;
			}
			if (ret) {
				mark("vrrflip: flip commit failed: %s", strerror(-ret));
				return 1;
			}
			if (set_vrr) {
				mark("vrrflip: VRR_ENABLED %d committed", p->vrr);
				vrr_now = p->vrr;
				set_vrr = 0;
			}
			pending = 1;
			flips++;
			while (pending) {
				struct pollfd pfd = { .fd = fd, .events = POLLIN };

				if (poll(&pfd, 1, 1000) <= 0) {
					mark("vrrflip: no flip event within 1 s (phase %s)", p->name);
					return 1;
				}
				drmHandleEvent(fd, &ev);
			}
			cur ^= 1;
		}
		if (!niv) {
			mark("vrrflip: phase %s: no intervals", p->name);
			continue;
		}
		if (out)
			for (int i = 0; i < niv; i++)
				fprintf(out, "%s,%.3f\n", p->name, iv[i]);
		qsort(iv, niv, sizeof(iv[0]), cmp_d);
		for (int i = 0; i < niv; i++)
			sum += iv[i];
		p50 = iv[niv / 2];
		mn = iv[0];
		mx = iv[niv - 1];
		mark("vrrflip: result %s flips %d fps %.2f p50 %.2f ms p5 %.2f p95 %.2f min %.2f max %.2f",
		     p->name, flips, 1e3 * niv / sum, p50, iv[niv / 20], iv[niv * 19 / 20], mn, mx);
	}
	if (out)
		fclose(out);
	return rc;
}
