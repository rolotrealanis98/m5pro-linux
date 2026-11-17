import ctypes as C, sys
egl=C.CDLL("libEGL.so.1"); api=sys.argv[1] if len(sys.argv)>1 else "gles"
gl=C.CDLL("libGLESv2.so.2" if api=="gles" else "libOpenGL.so.0")
egl.eglGetProcAddress.restype=C.c_void_p
gpd=C.CFUNCTYPE(C.c_void_p,C.c_uint,C.c_void_p,C.c_void_p)(egl.eglGetProcAddress(b"eglGetPlatformDisplayEXT"))
d=C.c_void_p(gpd(0x31DD,None,None))  # EGL_PLATFORM_SURFACELESS_MESA
ma,mi=C.c_int(),C.c_int(); assert egl.eglInitialize(d,C.byref(ma),C.byref(mi))
egl.eglBindAPI(0x30A0 if api=="gles" else 0x30A2)
attrs=(C.c_int*3)(0x3098,3,0x3038) if api=="gles" else (C.c_int*7)(0x3098,4,0x30FB,5,0x30FD,1,0x3038)
egl.eglCreateContext.restype=C.c_void_p
ctx=C.c_void_p(egl.eglCreateContext(d,None,None,attrs)); assert ctx.value
assert egl.eglMakeCurrent(d,None,None,ctx)
gl.glGetString.restype=C.c_char_p
print(gl.glGetString(0x1F01).decode(), "|", gl.glGetString(0x1F02).decode())
for n,e,k in [("MAX_TEXTURE_SIZE",0x0D33,1),("MAX_VIEWPORT_DIMS",0x0D3A,2),("MAX_RENDERBUFFER_SIZE",0x84E8,1),
              ("MAX_FRAMEBUFFER_WIDTH",0x9315,1),("MAX_FRAMEBUFFER_HEIGHT",0x9316,1),("MAX_SAMPLES",0x8D57,1),
              ("MAX_3D_TEXTURE_SIZE",0x8073,1),("MAX_ARRAY_TEXTURE_LAYERS",0x88FF,1),("MAX_CUBE_MAP_TEXTURE_SIZE",0x851C,1)]:
    v=(C.c_int*2)(-1,-1); gl.glGetIntegerv(e,v); print(n, list(v)[:k])
