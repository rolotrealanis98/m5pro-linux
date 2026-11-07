/* Headless GLES 3.1 smoke test for the native Gallium driver on the M5 Pro.
 *
 * Picks the EGL device whose render node is argv[1] (default
 * /dev/dri/renderD128; "surfaceless" uses EGL_MESA_platform_surfaceless),
 * prints the renderer, then runs short scenes into offscreen FBOs and checks
 * pixels:
 *   1 clear + triangle         (RGBA8, 256x256)
 *   2 depth test               (two overlapping quads, D32F / D24S8)
 *   3 texture sample           (2x2 texture, nearest)
 *   4 MRT                      (two RGBA8 attachments)
 *   5 MSAA 4x + resolve blit
 *   6 compute shader -> SSBO   (GLES 3.1)
 *   7 many draws in one pass   (1000 small quads)
 *   8 compute with shared memory
 *   9 stencil + blend
 *  10 geometry shader (GLES 3.2)
 *  11 glGenerateMipmap + textureLod
 *  12 2048x1536 target, scissored clear and draw
 * Exit 0 = all pass, 1 = some scene drew wrong pixels, 2 = setup failure.
 * Every scene finishes with glFinish, so a refused submission shows up as
 * wrong pixels and as "DRM_IOCTL_ASAHI_SUBMIT ... failed" on stderr.
 *
 * Build: cc -O2 -o gl-native-smoke gl-native-smoke.c -lEGL -lGLESv2
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 256
#define H 256

static int failures;

static GLuint
shader(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "shader compile failed: %s\n", log);
      exit(2);
   }
   return s;
}

static GLuint
program(const char *vs, const char *fs)
{
   GLuint p = glCreateProgram();
   glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
   glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
   glLinkProgram(p);
   GLint ok = 0;
   glGetProgramiv(p, GL_LINK_STATUS, &ok);
   if (!ok) {
      fprintf(stderr, "program link failed\n");
      exit(2);
   }
   return p;
}

static GLuint
fbo_rgba8(GLuint *tex, unsigned count, GLsizei w, GLsizei h)
{
   GLuint fbo;
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glGenTextures(count, tex);
   GLenum bufs[4];
   for (unsigned i = 0; i < count; ++i) {
      glBindTexture(GL_TEXTURE_2D, tex[i]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i,
                             GL_TEXTURE_2D, tex[i], 0);
      bufs[i] = GL_COLOR_ATTACHMENT0 + i;
   }
   glDrawBuffers(count, bufs);
   return fbo;
}

static void
expect(const char *scene, GLenum attachment, int x, int y, uint32_t want)
{
   uint8_t px[4];
   glReadBuffer(attachment);
   glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
   uint32_t got = px[0] | px[1] << 8 | px[2] << 16 | (uint32_t)px[3] << 24;
   /* Allow +-2 per channel for unorm rounding. */
   for (int c = 0; c < 4; ++c) {
      int a = (got >> (8 * c)) & 0xff, b = (want >> (8 * c)) & 0xff;
      if (a - b > 2 || b - a > 2) {
         printf("  %s: pixel (%d,%d) = %08x, expected %08x\n", scene, x, y,
                got, want);
         failures++;
         return;
      }
   }
}

static void
scene_begin(const char *name)
{
   printf("scene %s\n", name);
   fflush(stdout);
}

static void
scene_end(const char *name, int before)
{
   GLenum err = glGetError();
   if (err) {
      printf("  %s: GL error 0x%x\n", name, err);
      failures++;
   }
   printf("  %s: %s\n", name, failures == before ? "PASS" : "FAIL");
   fflush(stdout);
}

static const char *vs_pos =
   "#version 310 es\n"
   "layout(location=0) in vec4 p;\n"
   "void main() { gl_Position = p; }\n";

static const char *fs_uniform =
   "#version 310 es\nprecision mediump float;\n"
   "uniform vec4 c; layout(location=0) out vec4 o;\n"
   "void main() { o = c; }\n";

static void
draw_quad(GLuint vbo, float x0, float y0, float x1, float y1, float z)
{
   const float v[] = {x0, y0, z, 1, x1, y0, z, 1, x0, y1, z, 1,
                      x1, y0, z, 1, x1, y1, z, 1, x0, y1, z, 1};
   glBindBuffer(GL_ARRAY_BUFFER, vbo);
   glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
   glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
   glEnableVertexAttribArray(0);
   glDrawArrays(GL_TRIANGLES, 0, 6);
}

int
main(int argc, char **argv)
{
   const char *want = argc > 1 ? argv[1] : "/dev/dri/renderD128";
   EGLDisplay dpy = EGL_NO_DISPLAY;
   PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
      (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   if (!getPlatformDisplay)
      return 2;

   if (!strcmp(want, "surfaceless")) {
      dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                               EGL_DEFAULT_DISPLAY, NULL);
   } else {
      PFNEGLQUERYDEVICESEXTPROC queryDevices =
         (void *)eglGetProcAddress("eglQueryDevicesEXT");
      PFNEGLQUERYDEVICESTRINGEXTPROC queryDeviceString =
         (void *)eglGetProcAddress("eglQueryDeviceStringEXT");
      EGLDeviceEXT devs[16];
      EGLint n = 0;
      if (!queryDevices || !queryDeviceString)
         return 2;
      queryDevices(16, devs, &n);
      for (int i = 0; i < n; i++) {
         const char *exts = queryDeviceString(devs[i], EGL_EXTENSIONS);
         const char *node = NULL;
         if (exts && strstr(exts, "EGL_EXT_device_drm_render_node"))
            node = queryDeviceString(devs[i], EGL_DRM_RENDER_NODE_FILE_EXT);
         if (node && !strcmp(node, want))
            dpy = getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, devs[i], NULL);
      }
   }
   if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL)) {
      fprintf(stderr, "no EGL display for %s (0x%x)\n", want, eglGetError());
      return 2;
   }
   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cattr[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                           EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT,
                                     cattr);
   if (ctx == EGL_NO_CONTEXT ||
       !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      fprintf(stderr, "no GLES 3.1 context (0x%x)\n", eglGetError());
      return 2;
   }
   printf("GL_RENDERER: %s\nGL_VERSION:  %s\n", glGetString(GL_RENDERER),
          glGetString(GL_VERSION));

   GLuint vao, vbo;
   glGenVertexArrays(1, &vao);
   glBindVertexArray(vao);
   glGenBuffers(1, &vbo);
   GLuint flat = program(vs_pos, fs_uniform);
   GLint flat_c = glGetUniformLocation(flat, "c");
   int before;

   /* 1 clear + triangle */
   before = failures;
   scene_begin("1-triangle");
   {
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 1, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      const float v[] = {-0.5f, -0.5f, 0, 1, 0.5f, -0.5f, 0, 1, 0, 0.5f, 0, 1};
      glBindBuffer(GL_ARRAY_BUFFER, vbo);
      glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
      glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
      glEnableVertexAttribArray(0);
      glUseProgram(flat);
      glUniform4f(flat_c, 1, 0, 0, 1);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      glFinish();
      expect("1-triangle", GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xff0000ff);
      expect("1-triangle", GL_COLOR_ATTACHMENT0, 2, 2, 0xffff0000);
      expect("1-triangle", GL_COLOR_ATTACHMENT0, W - 3, H - 3, 0xffff0000);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
   }
   scene_end("1-triangle", before);

   /* 2 depth test: far green quad drawn after near red quad must lose */
   const GLenum depth_formats[] = {GL_DEPTH_COMPONENT32F, GL_DEPTH24_STENCIL8};
   for (unsigned f = 0; f < 2; ++f) {
      const char *name = f ? "2-depth-d24s8" : "2-depth-d32f";
      before = failures;
      scene_begin(name);
      GLuint tex, rb;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glGenRenderbuffers(1, &rb);
      glBindRenderbuffer(GL_RENDERBUFFER, rb);
      glRenderbufferStorage(GL_RENDERBUFFER, depth_formats[f], W, H);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER,
                                f ? GL_DEPTH_STENCIL_ATTACHMENT
                                  : GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, rb);
      if (glCheckFramebufferStatus(GL_FRAMEBUFFER) !=
          GL_FRAMEBUFFER_COMPLETE) {
         printf("  %s: incomplete FBO\n", name);
         failures++;
      }
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 0, 1);
      glClearDepthf(1.0f);
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
      glEnable(GL_DEPTH_TEST);
      glDepthFunc(GL_LESS);
      glUseProgram(flat);
      glUniform4f(flat_c, 1, 0, 0, 1);
      draw_quad(vbo, -0.5f, -0.5f, 0.5f, 0.5f, -0.5f);
      glUniform4f(flat_c, 0, 1, 0, 1);
      draw_quad(vbo, -1, -1, 1, 1, 0.5f);
      glFinish();
      glDisable(GL_DEPTH_TEST);
      expect(name, GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xff0000ff);
      expect(name, GL_COLOR_ATTACHMENT0, 4, 4, 0xff00ff00);
      glDeleteFramebuffers(1, &fbo);
      glDeleteRenderbuffers(1, &rb);
      glDeleteTextures(1, &tex);
      scene_end(name, before);
   }

   /* 3 texture sample */
   before = failures;
   scene_begin("3-texture");
   {
      const char *fs =
         "#version 310 es\nprecision mediump float;\n"
         "uniform sampler2D t; layout(location=0) out vec4 o;\n"
         "void main() { o = texture(t, gl_FragCoord.xy / 256.0); }\n";
      GLuint p = program(vs_pos, fs);
      const uint32_t texels[4] = {0xff0000ff, 0xff00ff00, 0xffff0000,
                                  0xffffffff};
      GLuint src;
      glGenTextures(1, &src);
      glBindTexture(GL_TEXTURE_2D, src);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, texels);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glViewport(0, 0, W, H);
      glUseProgram(p);
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, src);
      glUniform1i(glGetUniformLocation(p, "t"), 0);
      draw_quad(vbo, -1, -1, 1, 1, 0);
      glFinish();
      expect("3-texture", GL_COLOR_ATTACHMENT0, 10, 10, texels[0]);
      expect("3-texture", GL_COLOR_ATTACHMENT0, W - 10, 10, texels[1]);
      expect("3-texture", GL_COLOR_ATTACHMENT0, 10, H - 10, texels[2]);
      expect("3-texture", GL_COLOR_ATTACHMENT0, W - 10, H - 10, texels[3]);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
      glDeleteTextures(1, &src);
   }
   scene_end("3-texture", before);

   /* 4 MRT */
   before = failures;
   scene_begin("4-mrt");
   {
      const char *fs =
         "#version 310 es\nprecision mediump float;\n"
         "layout(location=0) out vec4 a; layout(location=1) out vec4 b;\n"
         "void main() { a = vec4(1,0,0,1); b = vec4(0,1,0,1); }\n";
      GLuint p = program(vs_pos, fs);
      GLuint tex[2];
      GLuint fbo = fbo_rgba8(tex, 2, W, H);
      glViewport(0, 0, W, H);
      glUseProgram(p);
      draw_quad(vbo, -1, -1, 1, 1, 0);
      glFinish();
      expect("4-mrt", GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xff0000ff);
      expect("4-mrt", GL_COLOR_ATTACHMENT1, W / 2, H / 2, 0xff00ff00);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(2, tex);
   }
   scene_end("4-mrt", before);

   /* 5 MSAA 4x + resolve */
   before = failures;
   scene_begin("5-msaa-resolve");
   {
      GLuint ms_fbo, ms_rb;
      glGenFramebuffers(1, &ms_fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, ms_fbo);
      glGenRenderbuffers(1, &ms_rb);
      glBindRenderbuffer(GL_RENDERBUFFER, ms_rb);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, W, H);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                GL_RENDERBUFFER, ms_rb);
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 1, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      glUseProgram(flat);
      glUniform4f(flat_c, 1, 1, 0, 1);
      draw_quad(vbo, -0.5f, -0.5f, 0.5f, 0.5f, 0);
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glBindFramebuffer(GL_READ_FRAMEBUFFER, ms_fbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
      glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT,
                        GL_NEAREST);
      glBindFramebuffer(GL_FRAMEBUFFER, fbo);
      glFinish();
      expect("5-msaa-resolve", GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xff00ffff);
      expect("5-msaa-resolve", GL_COLOR_ATTACHMENT0, 3, 3, 0xffff0000);
      glDeleteFramebuffers(1, &fbo);
      glDeleteFramebuffers(1, &ms_fbo);
      glDeleteRenderbuffers(1, &ms_rb);
      glDeleteTextures(1, &tex);
   }
   scene_end("5-msaa-resolve", before);

   /* 6 compute -> SSBO */
   before = failures;
   scene_begin("6-compute");
   {
      const char *cs =
         "#version 310 es\nlayout(local_size_x=64) in;\n"
         "layout(std430, binding=0) buffer B { uint v[]; };\n"
         "uniform uint base;\n"
         "void main() { uint i = gl_GlobalInvocationID.x + base;\n"
         "  v[i] = i * 3u + 7u; }\n";
      GLuint p = glCreateProgram();
      glAttachShader(p, shader(GL_COMPUTE_SHADER, cs));
      glLinkProgram(p);
      GLuint ssbo;
      glGenBuffers(1, &ssbo);
      glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
      glBufferData(GL_SHADER_STORAGE_BUFFER, 1024 * 4, NULL, GL_DYNAMIC_READ);
      glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
      glUseProgram(p);
      /* Two halves: two dispatches in one compute batch, which the M5 path
       * submits as two compute commands. */
      glUniform1ui(glGetUniformLocation(p, "base"), 0u);
      glDispatchCompute(8, 1, 1);
      glUniform1ui(glGetUniformLocation(p, "base"), 512u);
      glDispatchCompute(8, 1, 1);
      glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
      glFinish();
      const uint32_t *v = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0,
                                           1024 * 4, GL_MAP_READ_BIT);
      if (!v) {
         printf("  6-compute: map failed\n");
         failures++;
      } else {
         for (unsigned i = 0; i < 1024; ++i) {
            if (v[i] != i * 3 + 7) {
               printf("  6-compute: v[%u] = %u, expected %u\n", i, v[i],
                      i * 3 + 7);
               failures++;
               break;
            }
         }
         glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
      }
      glDeleteBuffers(1, &ssbo);
   }
   scene_end("6-compute", before);

   /* 7 many draws in one render */
   before = failures;
   scene_begin("7-many-draws");
   {
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      glUseProgram(flat);
      for (int i = 0; i < 1000; ++i) {
         const float x = -1 + 2.0f * (i % 32) / 32, y = -1 + 2.0f * (i / 32) / 32;
         glUniform4f(flat_c, (i & 1) ? 1 : 0, (i & 2) ? 1 : 0, 1, 1);
         draw_quad(vbo, x, y, x + 2.0f / 32, y + 2.0f / 32, 0);
      }
      glFinish();
      expect("7-many-draws", GL_COLOR_ATTACHMENT0, 4, 4, 0xffff0000);
      expect("7-many-draws", GL_COLOR_ATTACHMENT0, 12, 4, 0xffff00ff);
      expect("7-many-draws", GL_COLOR_ATTACHMENT0, W - 4, H - 4, 0xff000000);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
   }
   scene_end("7-many-draws", before);

   /* 8 compute with shared memory (threadgroup storage in the dispatch's
    * program list) */
   before = failures;
   scene_begin("8-compute-shared");
   {
      const char *cs =
         "#version 310 es\nlayout(local_size_x=128) in;\n"
         "shared uint s[128];\n"
         "layout(std430, binding=0) buffer B { uint v[]; };\n"
         "void main() { uint l = gl_LocalInvocationID.x;\n"
         "  s[l] = l; barrier();\n"
         "  v[gl_GlobalInvocationID.x] = s[127u - l] + gl_WorkGroupID.x; }\n";
      GLuint p = glCreateProgram();
      glAttachShader(p, shader(GL_COMPUTE_SHADER, cs));
      glLinkProgram(p);
      GLuint ssbo;
      glGenBuffers(1, &ssbo);
      glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
      glBufferData(GL_SHADER_STORAGE_BUFFER, 512 * 4, NULL, GL_DYNAMIC_READ);
      glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
      glUseProgram(p);
      glDispatchCompute(4, 1, 1);
      glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
      glFinish();
      const uint32_t *v = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0,
                                           512 * 4, GL_MAP_READ_BIT);
      if (!v) {
         printf("  8-compute-shared: map failed\n");
         failures++;
      } else {
         for (unsigned i = 0; i < 512; ++i) {
            const uint32_t e = 127 - (i % 128) + i / 128;
            if (v[i] != e) {
               printf("  8-compute-shared: v[%u] = %u, expected %u\n", i, v[i],
                      e);
               failures++;
               break;
            }
         }
         glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
      }
      glDeleteBuffers(1, &ssbo);
   }
   scene_end("8-compute-shared", before);

   /* 9 stencil + blend */
   before = failures;
   scene_begin("9-stencil-blend");
   {
      GLuint tex, rb;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glGenRenderbuffers(1, &rb);
      glBindRenderbuffer(GL_RENDERBUFFER, rb);
      glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, W, H);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                GL_RENDERBUFFER, rb);
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 0, 1);
      glClearStencil(0);
      glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
      glUseProgram(flat);
      glEnable(GL_STENCIL_TEST);
      /* Mark the left half in stencil without writing colour. */
      glStencilFunc(GL_ALWAYS, 1, 0xff);
      glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
      glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
      draw_quad(vbo, -1, -1, 0, 1, 0);
      glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
      /* Draw half-transparent white only where stencil == 1, blended. */
      glStencilFunc(GL_EQUAL, 1, 0xff);
      glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      glUniform4f(flat_c, 1, 1, 1, 0.5f);
      draw_quad(vbo, -1, -1, 1, 1, 0);
      glDisable(GL_BLEND);
      glDisable(GL_STENCIL_TEST);
      glFinish();
      /* Blending applies to alpha too: 0.5 * 0.5 + 1 * (1 - 0.5) = 0.75. */
      expect("9-stencil-blend", GL_COLOR_ATTACHMENT0, W / 4, H / 2, 0xbf808080);
      expect("9-stencil-blend", GL_COLOR_ATTACHMENT0, 3 * W / 4, H / 2,
             0xff000000);
      glDeleteFramebuffers(1, &fbo);
      glDeleteRenderbuffers(1, &rb);
      glDeleteTextures(1, &tex);
   }
   scene_end("9-stencil-blend", before);

   /* 10 geometry shader (GLES 3.2: a compute prepass on the M5 path) */
   before = failures;
   scene_begin("10-geometry");
   {
      const char *vs = "#version 320 es\nvoid main() { gl_Position = vec4(0); }\n";
      const char *gs =
         "#version 320 es\nlayout(points) in;\n"
         "layout(triangle_strip, max_vertices=4) out;\n"
         "void main() {\n"
         "  gl_Position = vec4(-1,-1,0,1); EmitVertex();\n"
         "  gl_Position = vec4( 1,-1,0,1); EmitVertex();\n"
         "  gl_Position = vec4(-1, 1,0,1); EmitVertex();\n"
         "  gl_Position = vec4( 1, 1,0,1); EmitVertex(); EndPrimitive(); }\n";
      const char *fs =
         "#version 320 es\nprecision mediump float;\n"
         "layout(location=0) out vec4 o; void main() { o = vec4(0,1,1,1); }\n";
      GLuint p = glCreateProgram();
      glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
      glAttachShader(p, shader(GL_GEOMETRY_SHADER, gs));
      glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
      glLinkProgram(p);
      GLint ok = 0;
      glGetProgramiv(p, GL_LINK_STATUS, &ok);
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glViewport(0, 0, W, H);
      glClearColor(0, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      if (ok) {
         glUseProgram(p);
         glDrawArrays(GL_POINTS, 0, 1);
      }
      glFinish();
      if (!ok) {
         printf("  10-geometry: program link failed\n");
         failures++;
      }
      expect("10-geometry", GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xffffff00);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
   }
   scene_end("10-geometry", before);

   /* 11 mipmap generation + sampling level 1 */
   before = failures;
   scene_begin("11-mipmap");
   {
      uint32_t *texels = malloc(64 * 64 * 4);
      for (unsigned i = 0; i < 64 * 64; ++i)
         texels[i] = 0xff00ff00;
      GLuint src;
      glGenTextures(1, &src);
      glBindTexture(GL_TEXTURE_2D, src);
      glTexStorage2D(GL_TEXTURE_2D, 7, GL_RGBA8, 64, 64);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 64, 64, GL_RGBA,
                      GL_UNSIGNED_BYTE, texels);
      free(texels);
      glGenerateMipmap(GL_TEXTURE_2D);
      const char *fs =
         "#version 310 es\nprecision mediump float;\n"
         "uniform sampler2D t; layout(location=0) out vec4 o;\n"
         "void main() { o = textureLod(t, vec2(0.5), 3.0); }\n";
      GLuint p = program(vs_pos, fs);
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, W, H);
      glViewport(0, 0, W, H);
      glUseProgram(p);
      glBindTexture(GL_TEXTURE_2D, src);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                      GL_NEAREST_MIPMAP_NEAREST);
      glUniform1i(glGetUniformLocation(p, "t"), 0);
      draw_quad(vbo, -1, -1, 1, 1, 0);
      glFinish();
      expect("11-mipmap", GL_COLOR_ATTACHMENT0, W / 2, H / 2, 0xff00ff00);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
      glDeleteTextures(1, &src);
   }
   scene_end("11-mipmap", before);

   /* 12 large target, scissored clear and draw */
   before = failures;
   scene_begin("12-large-scissor");
   {
      const int LW = 2048, LH = 1536;
      GLuint tex;
      GLuint fbo = fbo_rgba8(&tex, 1, LW, LH);
      glViewport(0, 0, LW, LH);
      glClearColor(0, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      glEnable(GL_SCISSOR_TEST);
      glScissor(LW - 64, LH - 64, 64, 64);
      glClearColor(1, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
      glScissor(0, 0, 64, 64);
      glUseProgram(flat);
      glUniform4f(flat_c, 0, 0, 1, 1);
      draw_quad(vbo, -1, -1, 1, 1, 0);
      glDisable(GL_SCISSOR_TEST);
      glFinish();
      expect("12-large-scissor", GL_COLOR_ATTACHMENT0, LW - 10, LH - 10,
             0xff0000ff);
      expect("12-large-scissor", GL_COLOR_ATTACHMENT0, 10, 10, 0xffff0000);
      expect("12-large-scissor", GL_COLOR_ATTACHMENT0, LW / 2, LH / 2,
             0xff000000);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &tex);
   }
   scene_end("12-large-scissor", before);

   printf("RESULT: %s (%d failed checks)\n", failures ? "FAIL" : "PASS",
          failures);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   return failures ? 1 : 0;
}
