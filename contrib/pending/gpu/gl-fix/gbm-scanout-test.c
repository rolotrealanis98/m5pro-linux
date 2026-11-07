/* GBM/EGL on the display card (simpledrm) with rendering on the GPU: the path
 * Hyprland and kmscube take. Mesa's kmsro layer pairs the display-only card
 * with the "aurora" render node, renders with the GPU into a LINEAR scanout
 * buffer and imports it into the display card. This test:
 *   1. opens the card (default: the one whose driver is simpledrm),
 *   2. creates a GBM device + EGL display on it and prints GL_RENDERER,
 *   3. renders one frame (clear to a known colour) into a GBM scanout surface,
 *   4. makes it a KMS framebuffer on the display card (drmModeAddFB2: PRIME
 *      import into simpledrm) without a modeset, so the screen is untouched,
 *   The buffer is the display's size: simpledrm refuses framebuffers smaller
 *   than its mode (mode_config.min_width/min_height).
 *   5. reads the buffer back through gbm_bo_map and checks the colour.
 * With --show SECONDS it also puts the frame on the panel (left half green,
 * right half orange) with a legacy modeset, then restores the previous CRTC.
 * That needs DRM master: no compositor may hold the card (stop Hyprland).
 * With GBM_TEST_RENDER_NODE=/dev/dri/renderD128 the GBM device and EGL display
 * are created on the GPU's render node instead, and the finished buffer is
 * PRIME-imported into the display card (dma-buf fd -> drmPrimeFDToHandle),
 * which is what Hyprland (aquamarine) does and what works when GL runs on
 * zink: zink renders only through a render node, never through kmsro.
 * Exit 0 = pass, 1 = wrong pixels or no framebuffer, 2 = setup failure.
 * Build: cc -O2 -o gbm-scanout-test gbm-scanout-test.c $(pkg-config --cflags --libs gbm egl glesv2 libdrm)
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <dirent.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

static unsigned W = 512, H = 256;

static int open_card(const char *path, char *name, size_t len)
{
   if (path) {
      snprintf(name, len, "%s", path);
      return open(path, O_RDWR | O_CLOEXEC);
   }
   for (int i = 0; i < 8; i++) {
      char p[64];
      snprintf(p, sizeof(p), "/dev/dri/card%d", i);
      int fd = open(p, O_RDWR | O_CLOEXEC);
      if (fd < 0)
         continue;
      drmVersionPtr v = drmGetVersion(fd);
      int match = v && !strcmp(v->name, "simpledrm");
      drmFreeVersion(v);
      if (match) {
         snprintf(name, len, "%s", p);
         return fd;
      }
      close(fd);
   }
   return -1;
}

static int show(int fd, uint32_t fb, int seconds)
{
   drmModeResPtr res = drmModeGetResources(fd);
   if (!res)
      return -1;
   int ret = -1;
   for (int i = 0; i < res->count_connectors && ret; i++) {
      drmModeConnectorPtr c = drmModeGetConnector(fd, res->connectors[i]);
      if (!c)
         continue;
      if (c->connection == DRM_MODE_CONNECTED && c->count_modes && res->count_crtcs) {
         uint32_t crtc_id = res->crtcs[0];
         if (c->encoder_id) {
            drmModeEncoderPtr e = drmModeGetEncoder(fd, c->encoder_id);
            if (e && e->crtc_id)
               crtc_id = e->crtc_id;
            drmModeFreeEncoder(e);
         }
         drmModeCrtcPtr old = drmModeGetCrtc(fd, crtc_id);
         if (drmSetMaster(fd))
            fprintf(stderr, "drmSetMaster failed (a compositor holds the card?)\n");
         ret = drmModeSetCrtc(fd, crtc_id, fb, 0, 0, &c->connector_id, 1, &c->modes[0]);
         printf("modeset %s on connector %u crtc %u: %s\n", c->modes[0].name, c->connector_id,
                crtc_id, ret ? strerror(-ret) : "ok, frame on screen");
         if (!ret) {
            sleep(seconds);
            if (old && old->mode_valid)
               drmModeSetCrtc(fd, crtc_id, old->buffer_id, old->x, old->y, &c->connector_id, 1,
                              &old->mode);
         }
         drmModeFreeCrtc(old);
         drmDropMaster(fd);
      }
      drmModeFreeConnector(c);
   }
   drmModeFreeResources(res);
   return ret;
}

int main(int argc, char **argv)
{
   char card[64];
   int show_s = 0;
   if (argc > 2 && !strcmp(argv[1], "--show")) {
      show_s = atoi(argv[2]);
      argc -= 2;
      argv += 2;
   }
   int fd = open_card(argc > 1 ? argv[1] : NULL, card, sizeof(card));
   if (fd < 0) {
      fprintf(stderr, "no display card (simpledrm) found\n");
      return 2;
   }
   drmVersionPtr v = drmGetVersion(fd);
   printf("display card: %s (driver %s)\n", card, v ? v->name : "?");
   drmFreeVersion(v);
   drmModeResPtr res = drmModeGetResources(fd);
   if (res) {
      if (res->min_width > W) W = res->min_width;
      if (res->min_height > H) H = res->min_height;
      drmModeFreeResources(res);
   }
   printf("buffer size: %ux%u\n", W, H);

   const char *render_node = getenv("GBM_TEST_RENDER_NODE");
   int gfd = fd;
   if (render_node && *render_node) {
      gfd = open(render_node, O_RDWR | O_CLOEXEC);
      if (gfd < 0) {
         fprintf(stderr, "cannot open %s\n", render_node);
         return 2;
      }
      printf("render node: %s (GBM and EGL there, PRIME into the display card)\n",
             render_node);
   }
   struct gbm_device *gbm = gbm_create_device(gfd);
   if (!gbm) {
      fprintf(stderr, "gbm_create_device failed\n");
      return 2;
   }
   printf("GBM backend: %s\n", gbm_device_get_backend_name(gbm));
   PFNEGLGETPLATFORMDISPLAYEXTPROC gpd =
      (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   EGLDisplay dpy = gpd(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   EGLint maj, min;
   if (!eglInitialize(dpy, &maj, &min)) {
      fprintf(stderr, "eglInitialize failed: 0x%x\n", eglGetError());
      return 2;
   }
   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cattr[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8,
                           EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0,
                           EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
   EGLConfig cfgs[64], cfg = NULL;
   EGLint n = 0;
   eglChooseConfig(dpy, cattr, cfgs, 64, &n);
   for (int i = 0; i < n; i++) {
      EGLint id;
      eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &id);
      if (id == GBM_FORMAT_XRGB8888) {
         cfg = cfgs[i];
         break;
      }
   }
   if (!cfg) {
      fprintf(stderr, "no XRGB8888 EGL config\n");
      return 2;
   }
   const EGLint xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr);
   uint64_t linear = DRM_FORMAT_MOD_LINEAR;
   struct gbm_surface *gs = getenv("GBM_TEST_NO_MODIFIERS")
      ? gbm_surface_create(gbm, W, H, GBM_FORMAT_XRGB8888,
                           GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR)
      : gbm_surface_create_with_modifiers2(gbm, W, H, GBM_FORMAT_XRGB8888, &linear, 1,
                                           GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
   if (!gs) {
      fprintf(stderr, "gbm_surface_create failed\n");
      return 2;
   }
   EGLSurface es = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)gs, NULL);
   if (es == EGL_NO_SURFACE || !eglMakeCurrent(dpy, es, es, ctx)) {
      fprintf(stderr, "EGL surface/context failed: 0x%x\n", eglGetError());
      return 2;
   }
   printf("GL_RENDERER: %s\nGL_VERSION:  %s\n", glGetString(GL_RENDERER),
          glGetString(GL_VERSION));

   glViewport(0, 0, W, H);
   glClearColor(1.0f, 0.5f, 0.0f, 1.0f); /* orange: R=255 G=128 B=0 */
   glClear(GL_COLOR_BUFFER_BIT);
   glScissor(0, 0, W / 2, H);           /* left half green */
   glEnable(GL_SCISSOR_TEST);
   glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
   glClear(GL_COLOR_BUFFER_BIT);
   glDisable(GL_SCISSOR_TEST);
   if (!eglSwapBuffers(dpy, es)) {
      fprintf(stderr, "eglSwapBuffers failed: 0x%x\n", eglGetError());
      return 1;
   }
   struct gbm_bo *bo = gbm_surface_lock_front_buffer(gs);
   if (!bo) {
      fprintf(stderr, "lock_front_buffer failed\n");
      return 1;
   }
   uint64_t mod = gbm_bo_get_modifier(bo);
   printf("scanout bo: %ux%u stride %u modifier 0x%llx%s\n", gbm_bo_get_width(bo),
          gbm_bo_get_height(bo), gbm_bo_get_stride(bo), (unsigned long long)mod,
          mod == DRM_FORMAT_MOD_LINEAR ? " (LINEAR)" : "");

   uint32_t handles[4] = {gbm_bo_get_handle(bo).u32}, pitches[4] = {gbm_bo_get_stride(bo)},
            offsets[4] = {0}, fb = 0;
   int r = 0;
   if (gfd != fd) {
      int dmabuf = gbm_bo_get_fd(bo);
      r = dmabuf < 0 ? -1 : drmPrimeFDToHandle(fd, dmabuf, &handles[0]);
      printf("PRIME import into %s: %s\n", card, r ? "failed" : "ok");
      if (dmabuf >= 0)
         close(dmabuf);
   }
   if (!r)
      r = drmModeAddFB2(fd, W, H, GBM_FORMAT_XRGB8888, handles, pitches, offsets, &fb, 0);
   printf("drmModeAddFB2 on %s: %s (fb %u)\n", card, r ? strerror(-r) : "ok", fb);

   uint32_t stride = 0;
   void *map_data = NULL;
   uint8_t *px = gbm_bo_map(bo, 0, 0, W, H, GBM_BO_TRANSFER_READ, &stride, &map_data);
   int bad = 1;
   if (px) {
      uint8_t *l = px + (H / 2) * stride + (W / 4) * 4;     /* B G R X */
      uint8_t *rr = px + (H / 2) * stride + (3 * W / 4) * 4;
      printf("left  pixel BGRX = %3u %3u %3u (want   0 255   0)\n", l[0], l[1], l[2]);
      printf("right pixel BGRX = %3u %3u %3u (want   0 127/128 255)\n", rr[0], rr[1], rr[2]);
      bad = !(l[0] == 0 && l[1] == 255 && l[2] == 0 && rr[0] == 0 &&
              (rr[1] == 127 || rr[1] == 128) && rr[2] == 255);
      gbm_bo_unmap(bo, map_data);
   } else {
      fprintf(stderr, "gbm_bo_map failed\n");
   }
   int shown = 0;
   if (fb && show_s > 0 && !bad)
      shown = show(fd, fb, show_s) ? -1 : 1;
   if (fb)
      drmModeRmFB(fd, fb);
   gbm_surface_release_buffer(gs, bo);
   int fail = bad || r || shown < 0;
   printf(fail ? "RESULT: FAIL\n" : "RESULT: PASS\n");
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   gbm_device_destroy(gbm);
   if (gfd != fd)
      close(gfd);
   close(fd);
   return fail ? 1 : 0;
}
