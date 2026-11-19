#version 440

// A window's picture, drawn smaller than it is: Catmull-Rom (bicubic) in
// place of the GPU's bilinear filter, and rounded corners, in one pass.
//
// Bilinear takes the two nearest texels each way with weights that depend on
// where between them the pixel lands. Shrinking a window to 80 % puts every
// pixel at a different place between texels, so neighbouring letters come
// out sharp, soft, sharp, and the pattern slides across the text while the
// window moves. Catmull-Rom weighs four texels each way and passes through
// the texels themselves, so text keeps its edges and looks the same at every
// position. The nine taps below are the usual way to get the sixteen-texel
// sum from bilinear lookups. At exactly full size it returns the texel.
//
// Build: /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" -o picture.frag.qsb picture.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
  mat4 qt_Matrix;
  float qt_Opacity;
  float radius;    // corner radius, in item units
  float px;        // item units covered by one screen pixel
  float zoom;      // screen pixels per texel
  vec2 itemSize;   // the item's size, in item units
  vec2 texSize;    // the picture's size, in texels
};

layout(binding = 1) uniform sampler2D source;

vec4 catmullRom(vec2 uv) {
  vec2 pos = uv * texSize;
  vec2 tc1 = floor(pos - 0.5) + 0.5;
  vec2 f = pos - tc1;

  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
  vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
  vec2 w3 = f * f * (-0.5 + 0.5 * f);

  vec2 w12 = w1 + w2;
  vec2 tc0 = (tc1 - 1.0) / texSize;
  vec2 tc3 = (tc1 + 2.0) / texSize;
  vec2 tc12 = (tc1 + w2 / w12) / texSize;

  vec4 c = vec4(0.0);
  c += texture(source, vec2(tc0.x, tc0.y)) * (w0.x * w0.y);
  c += texture(source, vec2(tc12.x, tc0.y)) * (w12.x * w0.y);
  c += texture(source, vec2(tc3.x, tc0.y)) * (w3.x * w0.y);
  c += texture(source, vec2(tc0.x, tc12.y)) * (w0.x * w12.y);
  c += texture(source, vec2(tc12.x, tc12.y)) * (w12.x * w12.y);
  c += texture(source, vec2(tc3.x, tc12.y)) * (w3.x * w12.y);
  c += texture(source, vec2(tc0.x, tc3.y)) * (w0.x * w3.y);
  c += texture(source, vec2(tc12.x, tc3.y)) * (w12.x * w3.y);
  c += texture(source, vec2(tc3.x, tc3.y)) * (w3.x * w3.y);
  return c;
}

void main() {
  // Far below half size four texels are too few and the result would sparkle;
  // there the plain filter is the better of the two.
  vec4 soft = texture(source, qt_TexCoord0);
  float sharpness = smoothstep(0.5, 0.62, zoom);
  vec4 c = soft;
  if (sharpness > 0.0) c = mix(soft, clamp(catmullRom(qt_TexCoord0), 0.0, 1.0), sharpness);

  // Rounded corners: distance to a rounded box, one screen pixel of edge.
  vec2 half_size = itemSize * 0.5;
  vec2 q = abs(qt_TexCoord0 * itemSize - half_size) - (half_size - vec2(radius));
  float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
  float cover = clamp(0.5 - dist / max(px, 0.0001), 0.0, 1.0);

  fragColor = c * (cover * qt_Opacity);
}
