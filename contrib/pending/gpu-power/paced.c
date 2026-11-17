// Headless, frame-paced GLES load for GPU power A/B (no window, no display, no sound).
//   paced [-f FPS] [-q QUADS] [-i ITERS] [-s SECONDS] [-m finish|flush] [-w WIDTH] [-h HEIGHT]
// Each frame draws QUADS full-target quads into a WIDTHxHEIGHT texture with a fragment shader of
// ITERS loop iterations, then:
//   finish: glFinish(), so a thread waits on the GPU every frame (the M5 driver's full effort);
//   flush:  glFlush() and a fence that is waited for only at the next frame (no waiter normally).
// FPS 0 runs uncapped (throughput). Prints per-second and total: frames, fps, and in finish mode
// the submit-to-done time (avg, p95) in microseconds; in flush mode the frames whose fence was
// still pending at the next frame ("late").
// Build: cc -O2 -o paced paced.c -lEGL -lGLESv2
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok;
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "shader: %s\n", log);
		exit(2);
	}
	return s;
}

int main(int argc, char **argv)
{
	double fps = 60, seconds = 20;
	int quads = 4, iters = 64, w = 1920, h = 1080, finish = 1;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "-f")) fps = atof(argv[i + 1]);
		else if (!strcmp(argv[i], "-q")) quads = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "-i")) iters = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "-s")) seconds = atof(argv[i + 1]);
		else if (!strcmp(argv[i], "-w")) w = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "-h")) h = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "-m")) finish = !strcmp(argv[i + 1], "finish");
	}

	PFNEGLGETPLATFORMDISPLAYEXTPROC gpd =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	EGLDisplay dpy = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	if (!eglInitialize(dpy, NULL, NULL)) { fprintf(stderr, "eglInitialize failed\n"); return 2; }
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cattr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, cattr);
	if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
		fprintf(stderr, "context failed\n");
		return 2;
	}
	fprintf(stderr, "renderer: %s\n", glGetString(GL_RENDERER));

	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	glViewport(0, 0, w, h);

	char fs[1024];
	snprintf(fs, sizeof(fs),
		 "precision highp float; uniform float t; varying vec2 uv;\n"
		 "void main() { vec2 p = uv; float a = t;\n"
		 "  for (int i = 0; i < %d; i++) { p = vec2(p.x * p.x - p.y * p.y, 2.0 * p.x * p.y) * 0.5 + uv; a += p.x; }\n"
		 "  gl_FragColor = vec4(fract(a), p, 1.0); }\n", iters);
	const char *vs = "attribute vec2 pos; varying vec2 uv;\n"
			 "void main() { uv = pos; gl_Position = vec4(pos, 0.0, 1.0); }\n";
	GLuint prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(prog, 0, "pos");
	glLinkProgram(prog);
	glUseProgram(prog);
	GLint tl = glGetUniformLocation(prog, "t");
	static const float quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
	glEnableVertexAttribArray(0);
	glEnable(GL_BLEND);
	glBlendFunc(GL_ONE, GL_ONE);

	PFNEGLCREATESYNCKHRPROC create_sync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
	PFNEGLCLIENTWAITSYNCKHRPROC wait_sync = (PFNEGLCLIENTWAITSYNCKHRPROC)eglGetProcAddress("eglClientWaitSyncKHR");
	PFNEGLDESTROYSYNCKHRPROC destroy_sync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
	EGLSyncKHR prev = EGL_NO_SYNC_KHR;

	size_t cap = (size_t)((fps > 0 ? fps : 2000) * seconds) + 16, n = 0;
	double *lat = calloc(cap, sizeof(*lat));
	double t0 = now(), next = t0, sec = t0 + 1;
	long frames = 0, sec_frames = 0, late = 0, sec_late = 0;
	double sec_lat = 0;
	while (now() - t0 < seconds) {
		if (fps > 0) {
			double d = next - now();
			if (d > 0) {
				struct timespec ts = { (time_t)d, (long)((d - (time_t)d) * 1e9) };
				nanosleep(&ts, NULL);
			}
			next += 1.0 / fps;
		}
		if (prev != EGL_NO_SYNC_KHR) {
			if (wait_sync(dpy, prev, 0, 0) == EGL_TIMEOUT_EXPIRED_KHR) {
				late++;
				sec_late++;
				wait_sync(dpy, prev, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);
			}
			destroy_sync(dpy, prev);
			prev = EGL_NO_SYNC_KHR;
		}
		double s = now();
		glClear(GL_COLOR_BUFFER_BIT);
		glUniform1f(tl, (float)(s - t0));
		for (int q = 0; q < quads; q++)
			glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		if (finish) {
			glFinish();
			double l = (now() - s) * 1e6;
			if (n < cap)
				lat[n++] = l;
			sec_lat += l;
		} else {
			prev = create_sync(dpy, EGL_SYNC_FENCE_KHR, NULL);
			glFlush();
		}
		frames++;
		sec_frames++;
		if (now() >= sec) {
			if (finish)
				printf("sec frames %ld lat_avg_us %.0f\n", sec_frames, sec_lat / (sec_frames ? sec_frames : 1));
			else
				printf("sec frames %ld late %ld\n", sec_frames, sec_late);
			fflush(stdout);
			sec_frames = 0;
			sec_late = 0;
			sec_lat = 0;
			sec += 1;
		}
	}
	double wall = now() - t0;
	if (finish && n) {
		double sum = 0;
		for (size_t i = 0; i < n; i++)
			sum += lat[i];
		qsort(lat, n, sizeof(*lat), cmp);
		printf("total frames %ld fps %.1f lat_avg_us %.0f lat_p50_us %.0f lat_p95_us %.0f\n", frames,
		       frames / wall, sum / n, lat[n / 2], lat[n * 95 / 100]);
	} else {
		printf("total frames %ld fps %.1f late %ld\n", frames, frames / wall, late);
	}
	return 0;
}
