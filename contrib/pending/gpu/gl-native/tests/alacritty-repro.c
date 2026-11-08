/* Replay Alacritty's GL 3.3 core renderer (glsl3 text + rect programs) on a
 * surfaceless EGL context, with the exact shader sources and GL state
 * Alacritty uses (alacritty/src/renderer/{text/glsl3.rs,rects.rs,mod.rs}),
 * plus variants that remove one feature at a time, so the first Mesa
 * refusal can be tied to a feature. Step markers go to stderr, interleaved
 * with Mesa's own messages; each step ends with the centre pixel.
 *
 *   alacritty-repro <res-dir> [step...]      (default: every step)
 *   res-dir holds alacritty/res: glsl3/text.{v,f}.glsl, rect.{v,f}.glsl
 *
 * Build: cc -O2 -o alacritty-repro alacritty-repro.c -lEGL -lOpenGL
 * Offline: tests/run-shim.sh g17s-kernel ./alacritty-repro <res-dir>
 */
#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/glcorearb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *res;
static int W = 256, H = 128;

static char *
slurp(const char *name)
{
   char path[1024];
   snprintf(path, sizeof(path), "%s/%s", res, name);
   FILE *f = fopen(path, "rb");
   if (!f) {
      perror(path);
      exit(2);
   }
   fseek(f, 0, SEEK_END);
   long n = ftell(f);
   fseek(f, 0, SEEK_SET);
   char *s = calloc(1, n + 1);
   if (fread(s, 1, n, f) != (size_t)n)
      exit(2);
   fclose(f);
   return s;
}

/* Text substitution, for the one-feature-removed variants. */
static char *
replace(const char *s, const char *from, const char *to)
{
   const char *p = strstr(s, from);
   if (!p) {
      fprintf(stderr, "REPRO: variant pattern not found: %s\n", from);
      exit(2);
   }
   size_t a = p - s, fl = strlen(from), tl = strlen(to);
   char *r = malloc(strlen(s) - fl + tl + 1);
   memcpy(r, s, a);
   memcpy(r + a, to, tl);
   strcpy(r + a + tl, p + fl);
   return r;
}

static GLuint
shader(GLenum type, const char *header, const char *src)
{
   const char *parts[3] = {"#version 330 core\n", header ? header : "", src};
   GLuint s = glCreateShader(type);
   glShaderSource(s, 3, parts, NULL);
   glCompileShader(s);
   GLint ok;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[4096];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "REPRO: compile failed: %s\n", log);
      exit(3);
   }
   return s;
}

static GLuint
program(const char *header, const char *vs, const char *fs)
{
   GLuint p = glCreateProgram();
   glAttachShader(p, shader(GL_VERTEX_SHADER, header, vs));
   glAttachShader(p, shader(GL_FRAGMENT_SHADER, header, fs));
   glLinkProgram(p);
   GLint ok;
   glGetProgramiv(p, GL_LINK_STATUS, &ok);
   if (!ok) {
      char log[4096];
      glGetProgramInfoLog(p, sizeof(log), NULL, log);
      fprintf(stderr, "REPRO: link failed: %s\n", log);
      exit(3);
   }
   return p;
}

static void
finish(const char *step)
{
   glFinish();
   uint8_t px[4] = {0};
   glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
   GLenum e = glGetError();
   fprintf(stderr, "REPRO: end %s pixel=%02x%02x%02x%02x glerror=%#x\n", step,
           px[0], px[1], px[2], px[3], e);
}

/* Alacritty's InstanceData (text/glsl3.rs), 28 bytes. */
struct instance {
   uint16_t col, row;
   int16_t left, top, width, height;
   float uv_left, uv_bot, uv_width, uv_height;
   uint8_t r, g, b, flags;
   uint8_t bg_r, bg_g, bg_b, bg_a;
};

static GLuint atlas;

static void
make_atlas(void)
{
   /* text/atlas.rs: RGBA8 1024x1024, CLAMP_TO_EDGE, LINEAR. One glyph. */
   glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
   glGenTextures(1, &atlas);
   glBindTexture(GL_TEXTURE_2D, atlas);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1024, 1024, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, NULL);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
   static uint8_t glyph[16 * 16 * 4];
   memset(glyph, 0xff, sizeof(glyph));
   glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE,
                   glyph);
   glBindTexture(GL_TEXTURE_2D, 0);
}

/* One text batch exactly as Glsl3Renderer::new + render_batch issue it. */
static void
text_batch(const char *step, const char *vs, const char *fs, int dual_blend)
{
   fprintf(stderr, "REPRO: begin %s\n", step);
   GLuint prog = program(NULL, vs, fs);
   GLint u_proj = glGetUniformLocation(prog, "projection");
   GLint u_cell = glGetUniformLocation(prog, "cellDim");
   GLint u_pass = glGetUniformLocation(prog, "renderingPass");

   glEnable(GL_BLEND);
   if (dual_blend == 1)
      glBlendFunc(GL_SRC1_COLOR, GL_ONE_MINUS_SRC1_COLOR);
   else if (dual_blend == 2)
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
   else
      glDisable(GL_BLEND);
   glDepthMask(GL_FALSE);

   GLuint vao, ebo, vbo;
   glGenVertexArrays(1, &vao);
   glGenBuffers(1, &ebo);
   glGenBuffers(1, &vbo);
   glBindVertexArray(vao);
   static const uint32_t idx[6] = {0, 1, 3, 1, 2, 3};
   glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
   glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(idx), idx, GL_STATIC_DRAW);
   glBindBuffer(GL_ARRAY_BUFFER, vbo);
   glBufferData(GL_ARRAY_BUFFER, 0x10000 * sizeof(struct instance), NULL,
                GL_STREAM_DRAW);
   const struct {
      GLint n;
      GLenum type;
      unsigned size;
   } attr[5] = {{2, GL_UNSIGNED_SHORT, 2}, {4, GL_SHORT, 2}, {4, GL_FLOAT, 4},
                {4, GL_UNSIGNED_BYTE, 1}, {4, GL_UNSIGNED_BYTE, 1}};
   uintptr_t off = 0;
   for (unsigned i = 0; i < 5; ++i) {
      glVertexAttribPointer(i, attr[i].n, attr[i].type, GL_FALSE,
                            sizeof(struct instance), (void *)off);
      glEnableVertexAttribArray(i);
      glVertexAttribDivisor(i, 1);
      off += attr[i].n * attr[i].size;
   }

   /* set_viewport + update_projection (padding 0 here). */
   glViewport(0, 0, W, H);
   glUseProgram(prog);
   glUniform4f(u_proj, -1.0f, 1.0f, 2.0f / W, -2.0f / H);
   glUniform2f(u_cell, 16.0f, 32.0f);

   /* clear(): premultiplied background. */
   glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
   glClear(GL_COLOR_BUFFER_BIT);

   struct instance in[64];
   unsigned n = 0;
   for (unsigned row = 0; row < 4; ++row)
      for (unsigned col = 0; col < 16; ++col)
         in[n++] = (struct instance){
            .col = col, .row = row, .left = 2, .top = 28, .width = 12,
            .height = 24, .uv_left = 0, .uv_bot = 0,
            .uv_width = 16.0f / 1024, .uv_height = 16.0f / 1024,
            .r = 0xe0, .g = 0xc0, .b = 0x40, .flags = 0,
            .bg_r = 0x20, .bg_g = 0x40, .bg_b = 0x80, .bg_a = 0xff};
   glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(in), in);
   glActiveTexture(GL_TEXTURE0);
   glBindTexture(GL_TEXTURE_2D, atlas);

   glUniform1i(u_pass, 0); /* RenderingPass::Background */
   glDrawElementsInstanced(GL_TRIANGLES, 6, GL_UNSIGNED_INT, NULL, n);
   glUniform1i(u_pass, 1); /* RenderingPass::SubpixelPass1 */
   glDrawElementsInstanced(GL_TRIANGLES, 6, GL_UNSIGNED_INT, NULL, n);
   finish(step);

   glBindVertexArray(0);
   glDeleteVertexArrays(1, &vao);
   glDeleteBuffers(1, &ebo);
   glDeleteBuffers(1, &vbo);
   glDeleteProgram(prog);
}

/* RectRenderer::draw for one rect kind, under draw_rects' blend state. */
static void
rect_batch(const char *step, const char *header, const char *vs,
           const char *fs)
{
   fprintf(stderr, "REPRO: begin %s\n", step);
   GLuint prog = program(header, vs, fs);
   glEnable(GL_BLEND);
   glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA,
                       GL_ONE);
   glViewport(0, 0, W, H);
   GLuint vao, vbo;
   glGenVertexArrays(1, &vao);
   glGenBuffers(1, &vbo);
   glBindVertexArray(vao);
   glBindBuffer(GL_ARRAY_BUFFER, vbo);
   struct {
      float x, y;
      uint8_t c[4];
   } v[6] = {{-1, -1, {0xff, 0, 0, 0xc0}}, {1, -1, {0xff, 0, 0, 0xc0}},
             {-1, 1, {0xff, 0, 0, 0xc0}},  {1, -1, {0xff, 0, 0, 0xc0}},
             {1, 1, {0xff, 0, 0, 0xc0}},   {-1, 1, {0xff, 0, 0, 0xc0}}};
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(v[0]), (void *)0);
   glEnableVertexAttribArray(0);
   glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(v[0]),
                         (void *)8);
   glEnableVertexAttribArray(1);
   glUseProgram(prog);
   const char *names[] = {"cellWidth", "cellHeight", "paddingY", "paddingX",
                          "underlinePosition", "underlineThickness",
                          "undercurlPosition"};
   const float vals[] = {16, 32, 0, 0, 3, 1, 2};
   for (unsigned i = 0; i < 7; ++i) {
      GLint l = glGetUniformLocation(prog, names[i]);
      if (l >= 0)
         glUniform1f(l, vals[i]);
   }
   glClearColor(0, 0, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
   glDrawArrays(GL_TRIANGLES, 0, 6);
   finish(step);
   glUseProgram(0);
   glBindVertexArray(0);
   glDeleteVertexArrays(1, &vao);
   glDeleteBuffers(1, &vbo);
   glDeleteProgram(prog);
}

static int
want(int argc, char **argv, const char *step)
{
   if (argc <= 2)
      return 1;
   for (int i = 2; i < argc; ++i)
      if (!strcmp(argv[i], step))
         return 1;
   return 0;
}

int
main(int argc, char **argv)
{
   if (argc < 2) {
      fprintf(stderr, "usage: %s <alacritty/res> [step...]\n", argv[0]);
      return 2;
   }
   res = argv[1];
   setvbuf(stderr, NULL, _IONBF, 0);

   EGLDisplay dpy =
      eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY,
                            NULL);
   if (!eglInitialize(dpy, NULL, NULL) || !eglBindAPI(EGL_OPENGL_API)) {
      fprintf(stderr, "REPRO: EGL init failed\n");
      return 1;
   }
   static const EGLint ctx_attr[] = {
      EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
      EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
      EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT,
                                     ctx_attr);
   if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      fprintf(stderr, "REPRO: GL 3.3 core context failed\n");
      return 1;
   }
   fprintf(stderr, "REPRO: renderer %s / %s\n", glGetString(GL_RENDERER),
           glGetString(GL_VERSION));

   /* Renderer::supports_robustness -> GlExtensions::load_extensions. */
   const GLubyte *ext = glGetString(GL_EXTENSIONS);
   fprintf(stderr, "REPRO: glGetString(GL_EXTENSIONS) = %p, error %#x\n",
           (void *)ext, glGetError());

   /* The default framebuffer of a window: an RGBA8 colour attachment, no
    * depth (Alacritty asks for no depth/stencil buffer). */
   GLuint rb, fbo;
   glGenRenderbuffers(1, &rb);
   glBindRenderbuffer(GL_RENDERBUFFER, rb);
   glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_RENDERBUFFER, rb);
   make_atlas();

   char *tv = slurp("glsl3/text.v.glsl"), *tf = slurp("glsl3/text.f.glsl");
   char *rv = slurp("rect.v.glsl"), *rf = slurp("rect.f.glsl");

   /* 1. Verbatim: what Alacritty draws every frame. */
   if (want(argc, argv, "text"))
      text_batch("text", tv, tf, 1);

   /* 2. Same program, ordinary alpha blending (no SRC1 factors). */
   if (want(argc, argv, "text-alpha-blend"))
      text_batch("text-alpha-blend", tv, tf, 2);

   /* 3. Same program, blending off. */
   if (want(argc, argv, "text-noblend"))
      text_batch("text-noblend", tv, tf, 0);

   /* 4. No second (index 1) output in the shader, alpha blending. */
   char *tf_single =
      replace(tf, "layout(location = 0, index = 1) out vec4 alphaMask;",
              "vec4 alphaMask;");
   if (want(argc, argv, "text-single-output"))
      text_batch("text-single-output", tv, tf_single, 2);

   /* 5. No discard (background pass), single output. */
   char *tf_nodiscard = replace(tf_single, "discard;", "");
   if (want(argc, argv, "text-nodiscard"))
      text_batch("text-nodiscard", tv, tf_nodiscard, 2);

   /* 6. Flat fg/bg made smooth (no flat + smooth mix), single output. */
   char *tv_smooth = replace(replace(tv, "flat out vec4 fg;", "out vec4 fg;"),
                             "flat out vec4 bg;", "out vec4 bg;");
   char *tf_smooth = replace(replace(tf_nodiscard, "flat in vec4 fg;",
                                     "in vec4 fg;"),
                             "flat in vec4 bg;", "in vec4 bg;");
   if (want(argc, argv, "text-all-smooth"))
      text_batch("text-all-smooth", tv_smooth, tf_smooth, 2);

   /* 7. Rect programs, verbatim (RectRenderer::new headers). */
   if (want(argc, argv, "rect"))
      rect_batch("rect", NULL, rv, rf);
   if (want(argc, argv, "rect-undercurl"))
      rect_batch("rect-undercurl", "#define DRAW_UNDERCURL\n", rv, rf);
   if (want(argc, argv, "rect-dotted"))
      rect_batch("rect-dotted", "#define DRAW_DOTTED\n", rv, rf);
   if (want(argc, argv, "rect-dashed"))
      rect_batch("rect-dashed", "#define DRAW_DASHED\n", rv, rf);

   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   return 0;
}
