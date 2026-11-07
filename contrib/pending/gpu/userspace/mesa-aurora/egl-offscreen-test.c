/* Headless GLES2 render test: picks the EGL device whose DRM render node is
 * the requested one (default /dev/dri/renderD128), renders a red triangle on
 * blue into a 256x256 FBO, reads it back and checks four pixels.
 * Exit 0 = pass, 1 = wrong pixels, 2 = setup failure.
 * Build: cc -O2 -o egl-offscreen-test egl-offscreen-test.c -lEGL -lGLESv2
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 256
#define H 256

static PFNEGLQUERYDEVICESEXTPROC queryDevices;
static PFNEGLQUERYDEVICESTRINGEXTPROC queryDeviceString;
static PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay;

static GLuint shader(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[1024];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "shader compile failed: %s\n", log);
      exit(2);
   }
   return s;
}

int main(int argc, char **argv)
{
   const char *want = argc > 1 ? argv[1] : "/dev/dri/renderD128";
   queryDevices = (void *)eglGetProcAddress("eglQueryDevicesEXT");
   queryDeviceString = (void *)eglGetProcAddress("eglQueryDeviceStringEXT");
   getPlatformDisplay = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   if (!queryDevices || !queryDeviceString || !getPlatformDisplay) {
      fprintf(stderr, "EGL_EXT_device_enumeration/platform_device missing\n");
      return 2;
   }
   EGLDeviceEXT devs[16];
   EGLint n = 0;
   queryDevices(16, devs, &n);
   EGLDeviceEXT dev = EGL_NO_DEVICE_EXT;
   for (int i = 0; i < n; i++) {
      const char *exts = queryDeviceString(devs[i], EGL_EXTENSIONS);
      const char *node = NULL;
      if (exts && strstr(exts, "EGL_EXT_device_drm_render_node"))
         node = queryDeviceString(devs[i], EGL_DRM_RENDER_NODE_FILE_EXT);
      printf("EGL device %d: render node %s\n", i, node ? node : "(none, software)");
      if (node && !strcmp(node, want))
         dev = devs[i];
   }
   if (dev == EGL_NO_DEVICE_EXT) {
      fprintf(stderr, "no EGL device for %s\n", want);
      return 2;
   }
   EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, dev, NULL);
   EGLint maj, min;
   if (!eglInitialize(dpy, &maj, &min)) {
      fprintf(stderr, "eglInitialize failed: 0x%x\n", eglGetError());
      return 2;
   }
   printf("EGL %d.%d vendor: %s\n", maj, min, eglQueryString(dpy, EGL_VENDOR));
   eglBindAPI(EGL_OPENGL_ES_API);
   static const EGLint cfg_attr[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                     EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
   EGLConfig cfg = NULL;
   EGLint ncfg = 0;
   eglChooseConfig(dpy, cfg_attr, &cfg, 1, &ncfg);
   static const EGLint ctx_attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, ncfg ? cfg : EGL_NO_CONFIG_KHR,
                                     EGL_NO_CONTEXT, ctx_attr);
   if (ctx == EGL_NO_CONTEXT ||
       !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      fprintf(stderr, "context failed: 0x%x\n", eglGetError());
      return 2;
   }
   printf("GL_VENDOR:   %s\nGL_RENDERER: %s\nGL_VERSION:  %s\n",
          glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));

   GLuint tex, fbo;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
   if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      fprintf(stderr, "FBO incomplete\n");
      return 2;
   }
   GLuint prog = glCreateProgram();
   glAttachShader(prog, shader(GL_VERTEX_SHADER,
      "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"));
   glAttachShader(prog, shader(GL_FRAGMENT_SHADER,
      "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }"));
   glBindAttribLocation(prog, 0, "p");
   glLinkProgram(prog);
   glUseProgram(prog);
   /* Triangle covering the lower-left half of the viewport. */
   static const GLfloat tri[] = {-1, -1, 1, -1, -1, 1};
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
   glEnableVertexAttribArray(0);
   glViewport(0, 0, W, H);
   glClearColor(0, 0, 1, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glDrawArrays(GL_TRIANGLES, 0, 3);
   glFinish();

   static unsigned char px[W * H * 4];
   glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
   GLenum err = glGetError();
   struct { int x, y; unsigned char r, g, b; } checks[] = {
      {16, 16, 255, 0, 0},     /* inside the triangle */
      {64, 100, 255, 0, 0},
      {240, 240, 0, 0, 255},   /* outside: clear colour */
      {200, 180, 0, 0, 255},
   };
   int bad = 0;
   for (unsigned i = 0; i < sizeof(checks) / sizeof(checks[0]); i++) {
      unsigned char *p = &px[(checks[i].y * W + checks[i].x) * 4];
      int ok = p[0] == checks[i].r && p[1] == checks[i].g && p[2] == checks[i].b;
      printf("pixel (%3d,%3d) = %3u %3u %3u, want %3u %3u %3u %s\n", checks[i].x,
             checks[i].y, p[0], p[1], p[2], checks[i].r, checks[i].g, checks[i].b,
             ok ? "ok" : "WRONG");
      bad += !ok;
   }
   printf("glGetError: 0x%x\n", err);
   printf(bad || err ? "RESULT: FAIL\n" : "RESULT: PASS\n");
   eglTerminate(dpy);
   return bad || err ? 1 : 0;
}
