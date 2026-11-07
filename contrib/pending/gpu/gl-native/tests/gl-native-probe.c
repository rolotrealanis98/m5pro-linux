/* Diagnostic probes for the two native-Gallium failures seen on the J716s:
 * blended/masked alpha (smoke scene 9) and LINEAR GBM scanout buffers that
 * stay black (gbm-scanout-test). Each probe prints PASS/FAIL with the pixel.
 *   gl-native-probe [render-node]    (default /dev/dri/renderD128)
 * Build: cc -O2 -o gl-native-probe gl-native-probe.c -lEGL -lGLESv2 -lgbm
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <drm_fourcc.h>

static int failures;
static EGLDisplay dpy;

static void
check(const char *name, uint32_t got, uint32_t want)
{
   int ok = 1;
   for (int c = 0; c < 4; ++c) {
      int a = (got >> (8 * c)) & 0xff, b = (want >> (8 * c)) & 0xff;
      if (a - b > 2 || b - a > 2)
         ok = 0;
   }
   printf("%s %s: got %08x want %08x\n", ok ? "PASS" : "FAIL", name, got, want);
   failures += !ok;
}

static uint32_t
read_rgba(int x, int y)
{
   uint8_t p[4];
   glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, p);
   return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static GLuint prog, ucol;

static void
quad(void)
{
   static const float v[] = {-1, -1, 1, -1, -1, 1, 1, 1};
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, v);
   glEnableVertexAttribArray(0);
   glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

static void
blend_probes(void)
{
   GLuint tex, fbo;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 64, 64);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          tex, 0);
   glViewport(0, 0, 64, 64);
   glUseProgram(prog);

#define RESET(r, g, b, a)                                                      \
   glDisable(GL_BLEND);                                                        \
   glColorMask(1, 1, 1, 1);                                                    \
   glClearColor(r, g, b, a);                                                   \
   glClear(GL_COLOR_BUFFER_BIT)

   RESET(0, 0, 0, 1);
   glUniform4f(ucol, 0.1f, 0.2f, 0.3f, 0.6f);
   quad();
   glFinish();
   check("B1 opaque draw writes alpha", read_rgba(32, 32), 0x994d331a);

   RESET(0, 0, 0, 1);
   glFinish();
   check("B2 clear alpha 1", read_rgba(32, 32), 0xff000000);

   RESET(0, 0, 0, 1);
   glEnable(GL_BLEND);
   glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
   glUniform4f(ucol, 1, 1, 1, 0.5f);
   quad();
   glFinish();
   check("B3 blend src_alpha/1-src_alpha (dst alpha 1)", read_rgba(32, 32),
         0xbf808080);

   RESET(0, 0, 0, 1);
   glColorMask(0, 0, 0, 0);
   glUniform4f(ucol, 1, 1, 1, 0.5f);
   quad();
   glFinish();
   glColorMask(1, 1, 1, 1);
   check("B4 colour mask all off leaves the pixel", read_rgba(32, 32),
         0xff000000);

   RESET(0.2f, 0.4f, 0.6f, 1);
   glColorMask(1, 1, 1, 0);
   glUniform4f(ucol, 1, 1, 1, 0);
   quad();
   glFinish();
   glColorMask(1, 1, 1, 1);
   check("B5 alpha masked off keeps dst alpha", read_rgba(32, 32), 0xffffffff);

   RESET(0, 0, 0, 1);
   glEnable(GL_BLEND);
   glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
   glUniform4f(ucol, 1, 1, 1, 0.5f);
   quad();
   glFinish();
   check("B6 blend keeps dst alpha (ZERO, ONE)", read_rgba(32, 32), 0xff808080);

   RESET(0, 0, 0, 1);
   glEnable(GL_BLEND);
   glBlendFuncSeparate(GL_ZERO, GL_ONE, GL_ZERO, GL_DST_ALPHA);
   glUniform4f(ucol, 1, 1, 1, 0.5f);
   quad();
   glFinish();
   check("B7 dst alpha read by blend (alpha = dstA*dstA)", read_rgba(32, 32),
         0xff000000);

   RESET(0, 0, 0, 0.5f);
   glEnable(GL_BLEND);
   glBlendFuncSeparate(GL_ZERO, GL_ONE, GL_ZERO, GL_DST_ALPHA);
   quad();
   glFinish();
   check("B8 dst alpha 0.5 read by blend (alpha = 0.25)", read_rgba(32, 32),
         0x40000000);
   glDisable(GL_BLEND);
   glDeleteFramebuffers(1, &fbo);
   glDeleteTextures(1, &tex);
}

/* Render into a GBM bo through an EGLImage renderbuffer, read it back with
 * gbm_bo_map. Two clears as gbm-scanout-test does, then a draw strip. */
static void
linear_probe(struct gbm_device *gbm, unsigned w, unsigned h, uint32_t format,
             int linear)
{
   char name[96];
   snprintf(name, sizeof(name), "L %ux%u %s %s", w, h,
            format == GBM_FORMAT_XRGB8888 ? "XRGB8888" : "ARGB8888",
            linear ? "LINEAR" : "default");
   uint64_t mod = DRM_FORMAT_MOD_LINEAR;
   struct gbm_bo *bo =
      linear ? gbm_bo_create_with_modifiers2(gbm, w, h, format, &mod, 1,
                                             GBM_BO_USE_RENDERING |
                                                GBM_BO_USE_SCANOUT)
             : gbm_bo_create(gbm, w, h, format, GBM_BO_USE_RENDERING);
   if (!bo) {
      printf("FAIL %s: gbm_bo_create\n", name);
      failures++;
      return;
   }
   PFNEGLCREATEIMAGEKHRPROC create_image =
      (void *)eglGetProcAddress("eglCreateImageKHR");
   PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC target =
      (void *)eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");
   EGLImageKHR img = create_image(dpy, EGL_NO_CONTEXT, EGL_NATIVE_PIXMAP_KHR,
                                  (EGLClientBuffer)bo, NULL);
   if (img == EGL_NO_IMAGE_KHR) {
      printf("FAIL %s: eglCreateImage 0x%x\n", name, eglGetError());
      failures++;
      gbm_bo_destroy(bo);
      return;
   }
   GLuint rb, fbo;
   glGenRenderbuffers(1, &rb);
   glBindRenderbuffer(GL_RENDERBUFFER, rb);
   target(GL_RENDERBUFFER, img);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_RENDERBUFFER, rb);
   glViewport(0, 0, w, h);
   glClearColor(1.0f, 0.5f, 0.0f, 1.0f);
   glClear(GL_COLOR_BUFFER_BIT);
   glEnable(GL_SCISSOR_TEST);
   glScissor(0, 0, w / 2, h);
   glClearColor(0, 1, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glScissor(0, 0, w, 8);
   glUseProgram(prog);
   glUniform4f(ucol, 0, 0, 1, 1);
   quad();
   glDisable(GL_SCISSOR_TEST);
   glFinish();

   /* GL readback first (goes through the driver), then the CPU mapping. */
   char sub[128];
   snprintf(sub, sizeof(sub), "%s glReadPixels left", name);
   check(sub, read_rgba(w / 4, h / 2), 0xff00ff00);
   snprintf(sub, sizeof(sub), "%s glReadPixels right", name);
   check(sub, read_rgba(3 * w / 4, h / 2), 0xff0080ff);
   snprintf(sub, sizeof(sub), "%s glReadPixels draw strip", name);
   check(sub, read_rgba(w / 2, 2), 0xffff0000);

   uint32_t stride = 0;
   void *map_data = NULL;
   uint8_t *px = gbm_bo_map(bo, 0, 0, w, h, GBM_BO_TRANSFER_READ, &stride,
                            &map_data);
   if (!px) {
      printf("FAIL %s: gbm_bo_map\n", name);
      failures++;
   } else {
      /* Memory is B,G,R,X; an FBO on an EGLImage is not flipped: GL row y
       * is memory row y. */
      const uint8_t *l = px + (size_t)(h / 2) * stride + (w / 4) * 4;
      const uint8_t *r = px + (size_t)(h / 2) * stride + (3 * w / 4) * 4;
      const uint8_t *s = px + (size_t)2 * stride + (w / 2) * 4;
      const uint32_t mask = format == GBM_FORMAT_XRGB8888 ? 0x00ffffff : ~0u;
      uint32_t lv, rv, sv;
      memcpy(&lv, l, 4);
      memcpy(&rv, r, 4);
      memcpy(&sv, s, 4);
      snprintf(sub, sizeof(sub), "%s gbm_bo_map left (BGRX)", name);
      check(sub, lv & mask, 0xff00ff00 & mask);
      snprintf(sub, sizeof(sub), "%s gbm_bo_map right (BGRX)", name);
      check(sub, rv & mask, 0xffff8000 & mask);
      snprintf(sub, sizeof(sub), "%s gbm_bo_map strip (BGRX)", name);
      check(sub, sv & mask, 0xff0000ff & mask);
      gbm_bo_unmap(bo, map_data);
   }
   glDeleteFramebuffers(1, &fbo);
   glDeleteRenderbuffers(1, &rb);
   gbm_bo_destroy(bo);
}

/* The gbm-scanout-test path: a GBM window surface, two clears, swap, lock the
 * front buffer, read it with gbm_bo_map. finish: glFinish before the swap. */
static void
window_probe(struct gbm_device *gbm, unsigned w, unsigned h, int finish)
{
   char name[96];
   snprintf(name, sizeof(name), "W %ux%u XRGB8888 LINEAR window%s", w, h,
            finish ? " +glFinish" : "");
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
   uint64_t mod = DRM_FORMAT_MOD_LINEAR;
   struct gbm_surface *gs = gbm_surface_create_with_modifiers2(
      gbm, w, h, GBM_FORMAT_XRGB8888, &mod, 1,
      GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
   EGLSurface es = cfg && gs ? eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)gs, NULL)
                             : EGL_NO_SURFACE;
   EGLContext prev = eglGetCurrentContext();
   const EGLint xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
   EGLContext ctx = cfg ? eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr) : EGL_NO_CONTEXT;
   if (es == EGL_NO_SURFACE || !eglMakeCurrent(dpy, es, es, ctx)) {
      printf("FAIL %s: surface/context 0x%x\n", name, eglGetError());
      failures++;
      return;
   }
   glViewport(0, 0, w, h);
   glClearColor(1.0f, 0.5f, 0.0f, 1.0f);
   glClear(GL_COLOR_BUFFER_BIT);
   glScissor(0, 0, w / 2, h);
   glEnable(GL_SCISSOR_TEST);
   glClearColor(0, 1, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glDisable(GL_SCISSOR_TEST);
   char sub[160];
   if (finish) {
      glFinish();
      snprintf(sub, sizeof(sub), "%s glReadPixels left before swap", name);
      check(sub, read_rgba(w / 4, h / 2) | 0xff000000, 0xff00ff00);
      snprintf(sub, sizeof(sub), "%s glReadPixels right before swap", name);
      check(sub, read_rgba(3 * w / 4, h / 2) | 0xff000000, 0xff0080ff);
   }
   eglSwapBuffers(dpy, es);
   struct gbm_bo *bo = gbm_surface_lock_front_buffer(gs);
   uint32_t stride = 0;
   void *map_data = NULL;
   uint8_t *px = bo ? gbm_bo_map(bo, 0, 0, w, h, GBM_BO_TRANSFER_READ, &stride,
                                 &map_data) : NULL;
   if (!px) {
      printf("FAIL %s: lock/map\n", name);
      failures++;
   } else {
      uint32_t lv, rv;
      memcpy(&lv, px + (size_t)(h / 2) * stride + (w / 4) * 4, 4);
      memcpy(&rv, px + (size_t)(h / 2) * stride + (3 * w / 4) * 4, 4);
      snprintf(sub, sizeof(sub), "%s gbm_bo_map left (BGRX)", name);
      check(sub, lv & 0xffffff, 0x00ff00);
      snprintf(sub, sizeof(sub), "%s gbm_bo_map right (BGRX)", name);
      check(sub, rv & 0xffffff, 0xff8000);
      gbm_bo_unmap(bo, map_data);
   }
   if (bo)
      gbm_surface_release_buffer(gs, bo);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, prev);
   eglDestroyContext(dpy, ctx);
   eglDestroySurface(dpy, es);
   gbm_surface_destroy(gs);
}

int
main(int argc, char **argv)
{
   const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
   int fd = open(node, O_RDWR | O_CLOEXEC);
   if (fd < 0) {
      fprintf(stderr, "cannot open %s\n", node);
      return 2;
   }
   struct gbm_device *gbm = gbm_create_device(fd);
   PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
      (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   dpy = get_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   if (!gbm || dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL)) {
      fprintf(stderr, "no GBM EGL display on %s\n", node);
      return 2;
   }
   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cattr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT,
                                     cattr);
   if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      fprintf(stderr, "no context (0x%x)\n", eglGetError());
      return 2;
   }
   printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
   const char *vs = "#version 300 es\nlayout(location=0) in vec2 p;\n"
                    "void main() { gl_Position = vec4(p, 0, 1); }\n";
   const char *fs = "#version 300 es\nprecision mediump float;\n"
                    "uniform vec4 c; out vec4 o; void main() { o = c; }\n";
   prog = glCreateProgram();
   GLuint s = glCreateShader(GL_VERTEX_SHADER);
   glShaderSource(s, 1, &vs, NULL);
   glCompileShader(s);
   glAttachShader(prog, s);
   s = glCreateShader(GL_FRAGMENT_SHADER);
   glShaderSource(s, 1, &fs, NULL);
   glCompileShader(s);
   glAttachShader(prog, s);
   glLinkProgram(prog);
   ucol = glGetUniformLocation(prog, "c");

   const char *only = getenv("PROBE_ONLY");
   if (!only || strchr(only, 'B'))
      blend_probes();
   if (!only || strchr(only, 'L')) {
      linear_probe(gbm, 256, 256, GBM_FORMAT_ARGB8888, 0);
      linear_probe(gbm, 256, 256, GBM_FORMAT_ARGB8888, 1);
      linear_probe(gbm, 256, 256, GBM_FORMAT_XRGB8888, 1);
      linear_probe(gbm, 3456, 2234, GBM_FORMAT_XRGB8888, 1);
   }
   if (!only || strchr(only, 'W')) {
      window_probe(gbm, 256, 256, 1);
      window_probe(gbm, 256, 256, 0);
      window_probe(gbm, 3456, 2234, 0);
   }
   printf("RESULT: %s (%d failed)\n", failures ? "FAIL" : "PASS", failures);
   return failures ? 1 : 0;
}
