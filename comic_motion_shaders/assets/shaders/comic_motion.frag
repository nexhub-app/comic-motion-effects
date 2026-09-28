#version 460 core

// comic_motion uber-shader (W7 MVP)
// 单一 fragment shader + uniform 开关切换四件参数化变换效果：
//   parallax（分层纹理偏移）/ breathing（呼吸缩放）/ lightSweep（扫光）/ vignette（暗角）。
//
// 层输入固定 4 个 sampler（远→近序，即核心包 exportLayers 的层序）；
// 不足 4 层时宿主侧用 1x1 透明纹理占位空槽。
// 分格感知（panelAware）层 PNG 本身是"全画布透明 + 格内内容"，
// alpha 混合天然不串色，本 shader 无需读 clip 元数据。
//
// uniform 布局约定：float uniform 按声明序对应 Dart 侧 setFloat(i, v)
// 的索引 0..18；sampler 单独按声明序对应 setImageSampler 0..3。

#include <flutter/runtime_effect.glsl>

uniform float uParallaxOn;      // 0/1
uniform float uParallaxX;       // 最大 uv 偏移（画布宽的分数，如 0.02）
uniform float uParallaxY;       // 最大 uv 偏移（画布高的分数）
uniform float uDepth0;          // 层深度因子 0..1（0 = 基准层不位移）
uniform float uDepth1;
uniform float uDepth2;
uniform float uDepth3;
uniform float uBreathingOn;     // 0/1
uniform float uZoom;            // 呼吸幅度（0.02 = ±2%）
uniform float uPhase;           // 呼吸相位 0..1（宿主时钟驱动）
uniform float uSweepOn;         // 0/1
uniform float uSweepPos;        // 扫光中心（uv x，可略越界 [−w, 1+w]）
uniform float uSweepWidth;      // 半带宽（uv 分数）
uniform float uSweepIntensity;  // 高亮强度 0..1
uniform float uVignetteOn;      // 0/1
uniform float uVignetteStrength; // 压暗强度 0..1
uniform float uVignetteSoftness; // 过渡柔度 0..1
uniform vec2  uSize;            // 画布像素尺寸

uniform sampler2D uTex0;
uniform sampler2D uTex1;
uniform sampler2D uTex2;
uniform sampler2D uTex3;

out vec4 fragColor;

const float kTwoPi = 6.28318530718;

vec4 sampleLayer(sampler2D tex, vec2 uv) {
  // 越界返回透明：parallax 偏移后边缘露出下层，不拉伸边缘像素
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return vec4(0.0);
  }
  return texture(tex, uv);
}

// straight-alpha back-to-front over 合成（远→近）
vec4 over(vec4 src, vec4 dst) {
  float outA = src.a + dst.a * (1.0 - src.a);
  if (outA <= 0.0) {
    return vec4(0.0);
  }
  vec3 outRgb = src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a);
  return vec4(outRgb / outA, outA);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;

  // breathing：围绕中心缩放（zoom>1 = 内容放大 → 采样范围收缩）
  if (uBreathingOn > 0.5) {
    float zoom = 1.0 + uZoom * sin(uPhase * kTwoPi);
    uv = vec2(0.5) + (uv - vec2(0.5)) / zoom;
  }

  vec2 baseShift = vec2(0.0);
  if (uParallaxOn > 0.5) {
    baseShift = vec2(uParallaxX, uParallaxY);
  }

  vec4 acc = vec4(0.0);
  acc = over(sampleLayer(uTex0, uv + baseShift * uDepth0), acc);
  acc = over(sampleLayer(uTex1, uv + baseShift * uDepth1), acc);
  acc = over(sampleLayer(uTex2, uv + baseShift * uDepth2), acc);
  acc = over(sampleLayer(uTex3, uv + baseShift * uDepth3), acc);

  // lightSweep：竖直亮带，加性提亮（按 acc.a 加权，只亮非透明像素）
  if (uSweepOn > 0.5) {
    float d = abs(uv.x - uSweepPos);
    float band = 1.0 - smoothstep(0.0, max(uSweepWidth, 1e-4), d);
    band = band * band * uSweepIntensity;
    acc.rgb += band * acc.a;
  }

  // vignette：椭圆径向压暗（按 acc.a 加权，只暗非透明像素）
  if (uVignetteOn > 0.5) {
    vec2 p = (uv - vec2(0.5)) * vec2(1.15, 1.0);
    float r = length(p);
    float inner = 0.30;
    float outer = inner + mix(0.15, 0.60, uVignetteSoftness);
    float shade = 1.0 - smoothstep(inner, outer, r);
    acc.rgb *= mix(1.0, 1.0 - uVignetteStrength * shade, acc.a);
  }

  fragColor = acc;
}
