/* Replay glmark2-es2's default "build" scene shader pair (light-basic.vert /
 * light-basic.frag with glmark2's precision header: mediump float in the
 * fragment shader) under a perspective projection, then the same pair with a
 * highp fragment shader, to tie the persp_mul_agx3 refusal to a precision.
 *
 *   glmark2-build-repro [mediump|highp][-tex]...  (default: all four)
 *   -tex uses light-basic-tex.frag (the "texture" scene) with a bound texture
 * Build: cc -O2 -o glmark2-build-repro glmark2-build-repro.c -lEGL -lGLESv2
 * Offline: tests/run-shim.sh g17s-kernel ./glmark2-build-repro
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* glmark2 ShaderSource::str() header, vertex shader, default precision. */
static const char *vs_src =
   "#if defined(GL_ES)\n#define HIGHP_OR_DEFAULT highp\n#else\n"
   "#define HIGHP_OR_DEFAULT\n#endif\n"
   "#if defined(GL_ES)\n#define MEDIUMP_OR_DEFAULT mediump\n#else\n"
   "#define MEDIUMP_OR_DEFAULT\n#endif\n"
   "const vec4 LightSourcePosition = vec4(20.0, 20.0, 10.0, 1.0);\n"
   "const vec4 MaterialDiffuse = vec4(0.7, 0.7, 0.7, 1.0);\n"
   "attribute vec3 position;\nattribute vec3 normal;\nattribute vec2 texcoord;\n"
   "uniform mat4 ModelViewProjectionMatrix;\nuniform mat4 NormalMatrix;\n"
   "varying vec4 Color;\nvarying vec2 TextureCoord;\n"
   "void main(void)\n{\n"
   "    vec3 N = normalize(vec3(NormalMatrix * vec4(normal, 1.0)));\n"
   "    vec3 L = normalize(LightSourcePosition.xyz);\n"
   "    float diffuse = max(dot(N, L), 0.0);\n"
   "    Color = vec4(diffuse * MaterialDiffuse.rgb, MaterialDiffuse.a);\n"
   "    TextureCoord = texcoord;\n"
   "    gl_Position = ModelViewProjectionMatrix * vec4(position, 1.0);\n}\n";

static const char *fs_body =
   "varying vec4 Color;\nvarying vec2 TextureCoord;\n"
   "void main(void)\n{\n    gl_FragColor = Color;\n}\n";

/* light-basic-tex.frag (the "texture" scene). */
static const char *fs_tex_body =
   "uniform sampler2D MaterialTexture0;\n"
   "varying vec4 Color;\nvarying vec2 TextureCoord;\n"
   "void main(void)\n{\n"
   "    vec4 texel = texture2D(MaterialTexture0, TextureCoord);\n"
   "    gl_FragColor = texel * Color;\n}\n";

static GLuint
compile(GLenum type, const char *a, const char *b)
{
   const char *src[2] = {a, b};
   GLuint s = glCreateShader(type);
   glShaderSource(s, 2, src, NULL);
   glCompileShader(s);
   GLint ok;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "REPRO: compile failed: %s\n", log);
   }
   return s;
}

static void
run(const char *mode)
{
   /* mode: mediump | highp, optionally suffixed -tex for the texture scene */
   char precision[16];
   const int tex = strstr(mode, "-tex") != NULL;
   snprintf(precision, sizeof(precision), "%.*s",
            (int)strcspn(mode, "-"), mode);
   char header[512];
   /* emit_precision(): Default -> mediump float in the fragment shader;
    * High -> highp under GL_FRAGMENT_PRECISION_HIGH. */
   snprintf(header, sizeof(header),
            "#if defined(GL_ES) && defined(GL_FRAGMENT_PRECISION_HIGH)\n"
            "#define HIGHP_OR_DEFAULT highp\n#else\n#define HIGHP_OR_DEFAULT\n"
            "#endif\n#ifdef GL_ES\nprecision %s float;\n#endif\n",
            precision);
   fprintf(stderr, "REPRO: begin %s\n", mode);
   GLuint p = glCreateProgram();
   glAttachShader(p, compile(GL_VERTEX_SHADER, "", vs_src));
   glAttachShader(p, compile(GL_FRAGMENT_SHADER, header,
                                  tex ? fs_tex_body : fs_body));
   glBindAttribLocation(p, 0, "position");
   glBindAttribLocation(p, 1, "normal");
   glBindAttribLocation(p, 2, "texcoord");
   glLinkProgram(p);
   glUseProgram(p);

   /* A perspective projection: w varies per vertex. */
   static const float mvp[16] = {1.2f, 0, 0, 0, 0, 1.2f, 0, 0,
                                 0, 0, -1.02f, -1, 0, 0, -0.2f, 0};
   static const float id[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
   glUniformMatrix4fv(glGetUniformLocation(p, "ModelViewProjectionMatrix"), 1,
                      GL_FALSE, mvp);
   glUniformMatrix4fv(glGetUniformLocation(p, "NormalMatrix"), 1, GL_FALSE, id);
   static const float pos[] = {-1, -1, -2, 1, -1, -4, 0, 1, -3};
   static const float nrm[] = {0, 0, 1, 0, 0, 1, 0, 0, 1};
   static const float tc[] = {0, 0, 1, 0, 0.5f, 1};
   glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, pos);
   glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 0, nrm);
   glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0, tc);
   for (int i = 0; i < 3; ++i)
      glEnableVertexAttribArray(i);
   if (tex) {
      static const uint8_t texels[4 * 4 * 4] = {255, 255, 255, 255};
      GLuint t;
      glGenTextures(1, &t);
      glBindTexture(GL_TEXTURE_2D, t);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, texels);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glUniform1i(glGetUniformLocation(p, "MaterialTexture0"), 0);
   }
   glClearColor(0, 0, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glDrawArrays(GL_TRIANGLES, 0, 3);
   glFinish();
   fprintf(stderr, "REPRO: end %s glerror=%#x\n", mode, glGetError());
   glDeleteProgram(p);
}

int
main(int argc, char **argv)
{
   setvbuf(stderr, NULL, _IONBF, 0);
   EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                          EGL_DEFAULT_DISPLAY, NULL);
   if (!eglInitialize(dpy, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API))
      return 1;
   static const EGLint attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
   EGLContext ctx =
      eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
   if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
      return 1;
   GLuint rb, fbo;
   glGenRenderbuffers(1, &rb);
   glBindRenderbuffer(GL_RENDERBUFFER, rb);
   glRenderbufferStorage(GL_RENDERBUFFER, 0x8058 /* GL_RGBA8_OES */, 128, 128);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_RENDERBUFFER, rb);
   glViewport(0, 0, 128, 128);
   if (argc < 2) {
      run("mediump");
      run("highp");
      run("mediump-tex");
      run("highp-tex");
   }
   for (int i = 1; i < argc; ++i)
      run(argv[i]);
   return 0;
}
