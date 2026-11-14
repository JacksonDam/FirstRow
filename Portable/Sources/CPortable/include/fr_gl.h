#ifndef FR_GL_H
#define FR_GL_H

/* OpenGL 3.3 core entry points, loaded at run time so the same code works with Windows' opengl32. */

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define FRGL_APIENTRY __stdcall
#else
#define FRGL_APIENTRY
#endif

typedef unsigned int GLenum;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef int GLint;
typedef unsigned int GLuint;
typedef int GLsizei;
typedef float GLfloat;
typedef char GLchar;
typedef unsigned char GLubyte;
typedef ptrdiff_t GLsizeiptr;
typedef ptrdiff_t GLintptr;

static const GLboolean GL_FALSE = 0;
static const GLboolean GL_TRUE = 1;
static const GLenum GL_ZERO = 0;
static const GLenum GL_ONE = 1;
static const GLenum GL_SRC_ALPHA = 0x0302;
static const GLenum GL_ONE_MINUS_SRC_ALPHA = 0x0303;
static const GLenum GL_DST_ALPHA = 0x0304;
static const GLenum GL_ONE_MINUS_DST_ALPHA = 0x0305;
static const GLenum GL_DST_COLOR = 0x0306;
static const GLenum GL_FUNC_ADD = 0x8006;
static const GLenum GL_BLEND = 0x0BE2;
static const GLenum GL_SCISSOR_TEST = 0x0C11;
static const GLenum GL_STENCIL_TEST = 0x0B90;
static const GLenum GL_DEPTH_TEST = 0x0B71;
static const GLenum GL_CULL_FACE = 0x0B44;
static const GLenum GL_MULTISAMPLE = 0x809D;
static const GLenum GL_COLOR_BUFFER_BIT = 0x00004000;
static const GLenum GL_STENCIL_BUFFER_BIT = 0x00000400;
static const GLenum GL_DEPTH_BUFFER_BIT = 0x00000100;
static const GLenum GL_NEVER = 0x0200;
static const GLenum GL_LESS = 0x0201;
static const GLenum GL_EQUAL = 0x0202;
static const GLenum GL_LEQUAL = 0x0203;
static const GLenum GL_GREATER = 0x0204;
static const GLenum GL_NOTEQUAL = 0x0205;
static const GLenum GL_GEQUAL = 0x0206;
static const GLenum GL_ALWAYS = 0x0207;
static const GLenum GL_KEEP = 0x1E00;
static const GLenum GL_REPLACE = 0x1E01;
static const GLenum GL_INCR = 0x1E02;
static const GLenum GL_DECR = 0x1E03;
static const GLenum GL_TEXTURE_2D = 0x0DE1;
static const GLenum GL_TEXTURE0 = 0x84C0;
static const GLenum GL_TEXTURE1 = 0x84C1;
static const GLenum GL_TEXTURE2 = 0x84C2;
static const GLenum GL_TEXTURE_MIN_FILTER = 0x2801;
static const GLenum GL_TEXTURE_MAG_FILTER = 0x2800;
static const GLenum GL_TEXTURE_WRAP_S = 0x2802;
static const GLenum GL_TEXTURE_WRAP_T = 0x2803;
static const GLenum GL_TEXTURE_MAX_LEVEL = 0x813D;
static const GLenum GL_TEXTURE_SWIZZLE_R = 0x8E42;
static const GLenum GL_TEXTURE_SWIZZLE_B = 0x8E44;
static const GLenum GL_TEXTURE_MAX_ANISOTROPY = 0x84FE;
static const GLenum GL_CLAMP_TO_EDGE = 0x812F;
static const GLenum GL_REPEAT = 0x2901;
static const GLenum GL_NEAREST = 0x2600;
static const GLenum GL_LINEAR = 0x2601;
static const GLenum GL_LINEAR_MIPMAP_LINEAR = 0x2703;
static const GLenum GL_RGBA = 0x1908;
static const GLenum GL_BGRA = 0x80E1;
static const GLenum GL_RGBA8 = 0x8058;
static const GLenum GL_RED = 0x1903;
static const GLenum GL_UNSIGNED_BYTE = 0x1401;
static const GLenum GL_FLOAT = 0x1406;
static const GLenum GL_UNPACK_ALIGNMENT = 0x0CF5;
static const GLenum GL_UNPACK_ROW_LENGTH = 0x0CF2;
static const GLenum GL_PACK_ALIGNMENT = 0x0D05;
static const GLenum GL_PACK_ROW_LENGTH = 0x0D02;
static const GLenum GL_TRIANGLES = 0x0004;
static const GLenum GL_TRIANGLE_STRIP = 0x0005;
static const GLenum GL_TRIANGLE_FAN = 0x0006;
static const GLenum GL_ARRAY_BUFFER = 0x8892;
static const GLenum GL_STATIC_DRAW = 0x88E4;
static const GLenum GL_DYNAMIC_DRAW = 0x88E8;
static const GLenum GL_STREAM_DRAW = 0x88E0;
static const GLenum GL_VERTEX_SHADER = 0x8B31;
static const GLenum GL_FRAGMENT_SHADER = 0x8B30;
static const GLenum GL_COMPILE_STATUS = 0x8B81;
static const GLenum GL_LINK_STATUS = 0x8B82;
static const GLenum GL_INFO_LOG_LENGTH = 0x8B84;
static const GLenum GL_FRAMEBUFFER = 0x8D40;
static const GLenum GL_READ_FRAMEBUFFER = 0x8CA8;
static const GLenum GL_DRAW_FRAMEBUFFER = 0x8CA9;
static const GLenum GL_RENDERBUFFER = 0x8D41;
static const GLenum GL_COLOR_ATTACHMENT0 = 0x8CE0;
static const GLenum GL_STENCIL_ATTACHMENT = 0x8D20;
static const GLenum GL_DEPTH_STENCIL_ATTACHMENT = 0x821A;
static const GLenum GL_DEPTH24_STENCIL8 = 0x88F0;
static const GLenum GL_STENCIL_INDEX8 = 0x8D48;
static const GLenum GL_FRAMEBUFFER_COMPLETE = 0x8CD5;
static const GLenum GL_FRAMEBUFFER_BINDING = 0x8CA6;
static const GLenum GL_VIEWPORT = 0x0BA2;
static const GLenum GL_MAX_TEXTURE_SIZE = 0x0D33;
static const GLenum GL_VERSION = 0x1F02;
static const GLenum GL_RENDERER = 0x1F01;
static const GLenum GL_VENDOR = 0x1F00;
static const GLenum GL_NO_ERROR = 0;

#ifdef __cplusplus
extern "C" {
#endif

typedef void* (*frgl_loader_t)(const char* name);
/* Loads every entry point; returns the number that could not be found. */
int frgl_load(frgl_loader_t loader);

typedef void (FRGL_APIENTRY *PFN_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);
extern PFN_glViewport frgl_glViewport;
static inline void glViewport(GLint x, GLint y, GLsizei width, GLsizei height) { frgl_glViewport(x, y, width, height); }
typedef void (FRGL_APIENTRY *PFN_glScissor)(GLint x, GLint y, GLsizei width, GLsizei height);
extern PFN_glScissor frgl_glScissor;
static inline void glScissor(GLint x, GLint y, GLsizei width, GLsizei height) { frgl_glScissor(x, y, width, height); }
typedef void (FRGL_APIENTRY *PFN_glClearColor)(GLfloat r, GLfloat g, GLfloat b, GLfloat a);
extern PFN_glClearColor frgl_glClearColor;
static inline void glClearColor(GLfloat r, GLfloat g, GLfloat b, GLfloat a) { frgl_glClearColor(r, g, b, a); }
typedef void (FRGL_APIENTRY *PFN_glClear)(GLbitfield mask);
extern PFN_glClear frgl_glClear;
static inline void glClear(GLbitfield mask) { frgl_glClear(mask); }
typedef void (FRGL_APIENTRY *PFN_glClearStencil)(GLint s);
extern PFN_glClearStencil frgl_glClearStencil;
static inline void glClearStencil(GLint s) { frgl_glClearStencil(s); }
typedef void (FRGL_APIENTRY *PFN_glEnable)(GLenum cap);
extern PFN_glEnable frgl_glEnable;
static inline void glEnable(GLenum cap) { frgl_glEnable(cap); }
typedef void (FRGL_APIENTRY *PFN_glDisable)(GLenum cap);
extern PFN_glDisable frgl_glDisable;
static inline void glDisable(GLenum cap) { frgl_glDisable(cap); }
typedef void (FRGL_APIENTRY *PFN_glBlendFunc)(GLenum sfactor, GLenum dfactor);
extern PFN_glBlendFunc frgl_glBlendFunc;
static inline void glBlendFunc(GLenum sfactor, GLenum dfactor) { frgl_glBlendFunc(sfactor, dfactor); }
typedef void (FRGL_APIENTRY *PFN_glBlendFuncSeparate)(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
extern PFN_glBlendFuncSeparate frgl_glBlendFuncSeparate;
static inline void glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) { frgl_glBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha); }
typedef void (FRGL_APIENTRY *PFN_glBlendEquation)(GLenum mode);
extern PFN_glBlendEquation frgl_glBlendEquation;
static inline void glBlendEquation(GLenum mode) { frgl_glBlendEquation(mode); }
typedef void (FRGL_APIENTRY *PFN_glColorMask)(GLboolean r, GLboolean g, GLboolean b, GLboolean a);
extern PFN_glColorMask frgl_glColorMask;
static inline void glColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a) { frgl_glColorMask(r, g, b, a); }
typedef void (FRGL_APIENTRY *PFN_glStencilFunc)(GLenum func, GLint ref, GLuint mask);
extern PFN_glStencilFunc frgl_glStencilFunc;
static inline void glStencilFunc(GLenum func, GLint ref, GLuint mask) { frgl_glStencilFunc(func, ref, mask); }
typedef void (FRGL_APIENTRY *PFN_glStencilOp)(GLenum sfail, GLenum dpfail, GLenum dppass);
extern PFN_glStencilOp frgl_glStencilOp;
static inline void glStencilOp(GLenum sfail, GLenum dpfail, GLenum dppass) { frgl_glStencilOp(sfail, dpfail, dppass); }
typedef void (FRGL_APIENTRY *PFN_glStencilMask)(GLuint mask);
extern PFN_glStencilMask frgl_glStencilMask;
static inline void glStencilMask(GLuint mask) { frgl_glStencilMask(mask); }
typedef GLenum (FRGL_APIENTRY *PFN_glGetError)(void);
extern PFN_glGetError frgl_glGetError;
static inline GLenum glGetError(void) { return frgl_glGetError(); }
typedef const GLubyte* (FRGL_APIENTRY *PFN_glGetString)(GLenum name);
extern PFN_glGetString frgl_glGetString;
static inline const GLubyte* glGetString(GLenum name) { return frgl_glGetString(name); }
typedef void (FRGL_APIENTRY *PFN_glGetIntegerv)(GLenum pname, GLint* data);
extern PFN_glGetIntegerv frgl_glGetIntegerv;
static inline void glGetIntegerv(GLenum pname, GLint* data) { frgl_glGetIntegerv(pname, data); }
typedef void (FRGL_APIENTRY *PFN_glPixelStorei)(GLenum pname, GLint param);
extern PFN_glPixelStorei frgl_glPixelStorei;
static inline void glPixelStorei(GLenum pname, GLint param) { frgl_glPixelStorei(pname, param); }
typedef void (FRGL_APIENTRY *PFN_glReadPixels)(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
extern PFN_glReadPixels frgl_glReadPixels;
static inline void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) { frgl_glReadPixels(x, y, width, height, format, type, pixels); }
typedef void (FRGL_APIENTRY *PFN_glFinish)(void);
extern PFN_glFinish frgl_glFinish;
static inline void glFinish(void) { frgl_glFinish(); }
typedef void (FRGL_APIENTRY *PFN_glFlush)(void);
extern PFN_glFlush frgl_glFlush;
static inline void glFlush(void) { frgl_glFlush(); }
typedef void (FRGL_APIENTRY *PFN_glGenTextures)(GLsizei n, GLuint* textures);
extern PFN_glGenTextures frgl_glGenTextures;
static inline void glGenTextures(GLsizei n, GLuint* textures) { frgl_glGenTextures(n, textures); }
typedef void (FRGL_APIENTRY *PFN_glDeleteTextures)(GLsizei n, const GLuint* textures);
extern PFN_glDeleteTextures frgl_glDeleteTextures;
static inline void glDeleteTextures(GLsizei n, const GLuint* textures) { frgl_glDeleteTextures(n, textures); }
typedef void (FRGL_APIENTRY *PFN_glBindTexture)(GLenum target, GLuint texture);
extern PFN_glBindTexture frgl_glBindTexture;
static inline void glBindTexture(GLenum target, GLuint texture) { frgl_glBindTexture(target, texture); }
typedef void (FRGL_APIENTRY *PFN_glActiveTexture)(GLenum texture);
extern PFN_glActiveTexture frgl_glActiveTexture;
static inline void glActiveTexture(GLenum texture) { frgl_glActiveTexture(texture); }
typedef void (FRGL_APIENTRY *PFN_glTexImage2D)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void* pixels);
extern PFN_glTexImage2D frgl_glTexImage2D;
static inline void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void* pixels) { frgl_glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels); }
typedef void (FRGL_APIENTRY *PFN_glTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels);
extern PFN_glTexSubImage2D frgl_glTexSubImage2D;
static inline void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels) { frgl_glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels); }
typedef void (FRGL_APIENTRY *PFN_glTexParameteri)(GLenum target, GLenum pname, GLint param);
extern PFN_glTexParameteri frgl_glTexParameteri;
static inline void glTexParameteri(GLenum target, GLenum pname, GLint param) { frgl_glTexParameteri(target, pname, param); }
typedef void (FRGL_APIENTRY *PFN_glTexParameterf)(GLenum target, GLenum pname, GLfloat param);
extern PFN_glTexParameterf frgl_glTexParameterf;
static inline void glTexParameterf(GLenum target, GLenum pname, GLfloat param) { frgl_glTexParameterf(target, pname, param); }
typedef void (FRGL_APIENTRY *PFN_glGenerateMipmap)(GLenum target);
extern PFN_glGenerateMipmap frgl_glGenerateMipmap;
static inline void glGenerateMipmap(GLenum target) { frgl_glGenerateMipmap(target); }
typedef GLuint (FRGL_APIENTRY *PFN_glCreateShader)(GLenum type);
extern PFN_glCreateShader frgl_glCreateShader;
static inline GLuint glCreateShader(GLenum type) { return frgl_glCreateShader(type); }
typedef void (FRGL_APIENTRY *PFN_glShaderSource)(GLuint shader, GLsizei count, const GLchar* const* string, const GLint* length);
extern PFN_glShaderSource frgl_glShaderSource;
static inline void glShaderSource(GLuint shader, GLsizei count, const GLchar* const* string, const GLint* length) { frgl_glShaderSource(shader, count, string, length); }
typedef void (FRGL_APIENTRY *PFN_glCompileShader)(GLuint shader);
extern PFN_glCompileShader frgl_glCompileShader;
static inline void glCompileShader(GLuint shader) { frgl_glCompileShader(shader); }
typedef void (FRGL_APIENTRY *PFN_glGetShaderiv)(GLuint shader, GLenum pname, GLint* params);
extern PFN_glGetShaderiv frgl_glGetShaderiv;
static inline void glGetShaderiv(GLuint shader, GLenum pname, GLint* params) { frgl_glGetShaderiv(shader, pname, params); }
typedef void (FRGL_APIENTRY *PFN_glGetShaderInfoLog)(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
extern PFN_glGetShaderInfoLog frgl_glGetShaderInfoLog;
static inline void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) { frgl_glGetShaderInfoLog(shader, bufSize, length, infoLog); }
typedef void (FRGL_APIENTRY *PFN_glDeleteShader)(GLuint shader);
extern PFN_glDeleteShader frgl_glDeleteShader;
static inline void glDeleteShader(GLuint shader) { frgl_glDeleteShader(shader); }
typedef GLuint (FRGL_APIENTRY *PFN_glCreateProgram)(void);
extern PFN_glCreateProgram frgl_glCreateProgram;
static inline GLuint glCreateProgram(void) { return frgl_glCreateProgram(); }
typedef void (FRGL_APIENTRY *PFN_glAttachShader)(GLuint program, GLuint shader);
extern PFN_glAttachShader frgl_glAttachShader;
static inline void glAttachShader(GLuint program, GLuint shader) { frgl_glAttachShader(program, shader); }
typedef void (FRGL_APIENTRY *PFN_glBindAttribLocation)(GLuint program, GLuint index, const GLchar* name);
extern PFN_glBindAttribLocation frgl_glBindAttribLocation;
static inline void glBindAttribLocation(GLuint program, GLuint index, const GLchar* name) { frgl_glBindAttribLocation(program, index, name); }
typedef void (FRGL_APIENTRY *PFN_glLinkProgram)(GLuint program);
extern PFN_glLinkProgram frgl_glLinkProgram;
static inline void glLinkProgram(GLuint program) { frgl_glLinkProgram(program); }
typedef void (FRGL_APIENTRY *PFN_glGetProgramiv)(GLuint program, GLenum pname, GLint* params);
extern PFN_glGetProgramiv frgl_glGetProgramiv;
static inline void glGetProgramiv(GLuint program, GLenum pname, GLint* params) { frgl_glGetProgramiv(program, pname, params); }
typedef void (FRGL_APIENTRY *PFN_glGetProgramInfoLog)(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
extern PFN_glGetProgramInfoLog frgl_glGetProgramInfoLog;
static inline void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) { frgl_glGetProgramInfoLog(program, bufSize, length, infoLog); }
typedef void (FRGL_APIENTRY *PFN_glUseProgram)(GLuint program);
extern PFN_glUseProgram frgl_glUseProgram;
static inline void glUseProgram(GLuint program) { frgl_glUseProgram(program); }
typedef void (FRGL_APIENTRY *PFN_glDeleteProgram)(GLuint program);
extern PFN_glDeleteProgram frgl_glDeleteProgram;
static inline void glDeleteProgram(GLuint program) { frgl_glDeleteProgram(program); }
typedef GLint (FRGL_APIENTRY *PFN_glGetUniformLocation)(GLuint program, const GLchar* name);
extern PFN_glGetUniformLocation frgl_glGetUniformLocation;
static inline GLint glGetUniformLocation(GLuint program, const GLchar* name) { return frgl_glGetUniformLocation(program, name); }
typedef void (FRGL_APIENTRY *PFN_glUniform1i)(GLint location, GLint v0);
extern PFN_glUniform1i frgl_glUniform1i;
static inline void glUniform1i(GLint location, GLint v0) { frgl_glUniform1i(location, v0); }
typedef void (FRGL_APIENTRY *PFN_glUniform1f)(GLint location, GLfloat v0);
extern PFN_glUniform1f frgl_glUniform1f;
static inline void glUniform1f(GLint location, GLfloat v0) { frgl_glUniform1f(location, v0); }
typedef void (FRGL_APIENTRY *PFN_glUniform2f)(GLint location, GLfloat v0, GLfloat v1);
extern PFN_glUniform2f frgl_glUniform2f;
static inline void glUniform2f(GLint location, GLfloat v0, GLfloat v1) { frgl_glUniform2f(location, v0, v1); }
typedef void (FRGL_APIENTRY *PFN_glUniform3f)(GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
extern PFN_glUniform3f frgl_glUniform3f;
static inline void glUniform3f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2) { frgl_glUniform3f(location, v0, v1, v2); }
typedef void (FRGL_APIENTRY *PFN_glUniform4f)(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
extern PFN_glUniform4f frgl_glUniform4f;
static inline void glUniform4f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) { frgl_glUniform4f(location, v0, v1, v2, v3); }
typedef void (FRGL_APIENTRY *PFN_glUniform4fv)(GLint location, GLsizei count, const GLfloat* value);
extern PFN_glUniform4fv frgl_glUniform4fv;
static inline void glUniform4fv(GLint location, GLsizei count, const GLfloat* value) { frgl_glUniform4fv(location, count, value); }
typedef void (FRGL_APIENTRY *PFN_glUniformMatrix4fv)(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
extern PFN_glUniformMatrix4fv frgl_glUniformMatrix4fv;
static inline void glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) { frgl_glUniformMatrix4fv(location, count, transpose, value); }
typedef void (FRGL_APIENTRY *PFN_glGenVertexArrays)(GLsizei n, GLuint* arrays);
extern PFN_glGenVertexArrays frgl_glGenVertexArrays;
static inline void glGenVertexArrays(GLsizei n, GLuint* arrays) { frgl_glGenVertexArrays(n, arrays); }
typedef void (FRGL_APIENTRY *PFN_glDeleteVertexArrays)(GLsizei n, const GLuint* arrays);
extern PFN_glDeleteVertexArrays frgl_glDeleteVertexArrays;
static inline void glDeleteVertexArrays(GLsizei n, const GLuint* arrays) { frgl_glDeleteVertexArrays(n, arrays); }
typedef void (FRGL_APIENTRY *PFN_glBindVertexArray)(GLuint array);
extern PFN_glBindVertexArray frgl_glBindVertexArray;
static inline void glBindVertexArray(GLuint array) { frgl_glBindVertexArray(array); }
typedef void (FRGL_APIENTRY *PFN_glGenBuffers)(GLsizei n, GLuint* buffers);
extern PFN_glGenBuffers frgl_glGenBuffers;
static inline void glGenBuffers(GLsizei n, GLuint* buffers) { frgl_glGenBuffers(n, buffers); }
typedef void (FRGL_APIENTRY *PFN_glDeleteBuffers)(GLsizei n, const GLuint* buffers);
extern PFN_glDeleteBuffers frgl_glDeleteBuffers;
static inline void glDeleteBuffers(GLsizei n, const GLuint* buffers) { frgl_glDeleteBuffers(n, buffers); }
typedef void (FRGL_APIENTRY *PFN_glBindBuffer)(GLenum target, GLuint buffer);
extern PFN_glBindBuffer frgl_glBindBuffer;
static inline void glBindBuffer(GLenum target, GLuint buffer) { frgl_glBindBuffer(target, buffer); }
typedef void (FRGL_APIENTRY *PFN_glBufferData)(GLenum target, GLsizeiptr size, const void* data, GLenum usage);
extern PFN_glBufferData frgl_glBufferData;
static inline void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) { frgl_glBufferData(target, size, data, usage); }
typedef void (FRGL_APIENTRY *PFN_glBufferSubData)(GLenum target, GLintptr offset, GLsizeiptr size, const void* data);
extern PFN_glBufferSubData frgl_glBufferSubData;
static inline void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) { frgl_glBufferSubData(target, offset, size, data); }
typedef void (FRGL_APIENTRY *PFN_glVertexAttribPointer)(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void* pointer);
extern PFN_glVertexAttribPointer frgl_glVertexAttribPointer;
static inline void glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void* pointer) { frgl_glVertexAttribPointer(index, size, type, normalized, stride, pointer); }
typedef void (FRGL_APIENTRY *PFN_glEnableVertexAttribArray)(GLuint index);
extern PFN_glEnableVertexAttribArray frgl_glEnableVertexAttribArray;
static inline void glEnableVertexAttribArray(GLuint index) { frgl_glEnableVertexAttribArray(index); }
typedef void (FRGL_APIENTRY *PFN_glDrawArrays)(GLenum mode, GLint first, GLsizei count);
extern PFN_glDrawArrays frgl_glDrawArrays;
static inline void glDrawArrays(GLenum mode, GLint first, GLsizei count) { frgl_glDrawArrays(mode, first, count); }
typedef void (FRGL_APIENTRY *PFN_glGenFramebuffers)(GLsizei n, GLuint* framebuffers);
extern PFN_glGenFramebuffers frgl_glGenFramebuffers;
static inline void glGenFramebuffers(GLsizei n, GLuint* framebuffers) { frgl_glGenFramebuffers(n, framebuffers); }
typedef void (FRGL_APIENTRY *PFN_glDeleteFramebuffers)(GLsizei n, const GLuint* framebuffers);
extern PFN_glDeleteFramebuffers frgl_glDeleteFramebuffers;
static inline void glDeleteFramebuffers(GLsizei n, const GLuint* framebuffers) { frgl_glDeleteFramebuffers(n, framebuffers); }
typedef void (FRGL_APIENTRY *PFN_glBindFramebuffer)(GLenum target, GLuint framebuffer);
extern PFN_glBindFramebuffer frgl_glBindFramebuffer;
static inline void glBindFramebuffer(GLenum target, GLuint framebuffer) { frgl_glBindFramebuffer(target, framebuffer); }
typedef void (FRGL_APIENTRY *PFN_glFramebufferTexture2D)(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
extern PFN_glFramebufferTexture2D frgl_glFramebufferTexture2D;
static inline void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level) { frgl_glFramebufferTexture2D(target, attachment, textarget, texture, level); }
typedef GLenum (FRGL_APIENTRY *PFN_glCheckFramebufferStatus)(GLenum target);
extern PFN_glCheckFramebufferStatus frgl_glCheckFramebufferStatus;
static inline GLenum glCheckFramebufferStatus(GLenum target) { return frgl_glCheckFramebufferStatus(target); }
typedef void (FRGL_APIENTRY *PFN_glGenRenderbuffers)(GLsizei n, GLuint* renderbuffers);
extern PFN_glGenRenderbuffers frgl_glGenRenderbuffers;
static inline void glGenRenderbuffers(GLsizei n, GLuint* renderbuffers) { frgl_glGenRenderbuffers(n, renderbuffers); }
typedef void (FRGL_APIENTRY *PFN_glDeleteRenderbuffers)(GLsizei n, const GLuint* renderbuffers);
extern PFN_glDeleteRenderbuffers frgl_glDeleteRenderbuffers;
static inline void glDeleteRenderbuffers(GLsizei n, const GLuint* renderbuffers) { frgl_glDeleteRenderbuffers(n, renderbuffers); }
typedef void (FRGL_APIENTRY *PFN_glBindRenderbuffer)(GLenum target, GLuint renderbuffer);
extern PFN_glBindRenderbuffer frgl_glBindRenderbuffer;
static inline void glBindRenderbuffer(GLenum target, GLuint renderbuffer) { frgl_glBindRenderbuffer(target, renderbuffer); }
typedef void (FRGL_APIENTRY *PFN_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
extern PFN_glRenderbufferStorage frgl_glRenderbufferStorage;
static inline void glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) { frgl_glRenderbufferStorage(target, internalformat, width, height); }
typedef void (FRGL_APIENTRY *PFN_glFramebufferRenderbuffer)(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
extern PFN_glFramebufferRenderbuffer frgl_glFramebufferRenderbuffer;
static inline void glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) { frgl_glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }
typedef void (FRGL_APIENTRY *PFN_glBlitFramebuffer)(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter);
extern PFN_glBlitFramebuffer frgl_glBlitFramebuffer;
static inline void glBlitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter) { frgl_glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter); }

#ifdef __cplusplus
}
#endif

#endif
