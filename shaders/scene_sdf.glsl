// LeanUI Unified Scene SDF + Glyph Atlas Shader (Vulkan 1.3 / GLSL 450)
// Supports instanced draws for:
//   kind = 0: SDF rounded rectangle fill (r4 per-corner radii)
//   kind = 1: SDF rounded rectangle stroke (strokeWidth + r4 per-corner radii)
//   kind = 2: SDF analytical drop shadow (sigma + spread + r4 per-corner radii)
//   kind = 3: R8 coverage glyph sample from shelf-packed atlas
//   kind = 4: BGRA8/RGBA8 color glyph sample from shelf-packed atlas
//   kind = 5: Textured RGBA8 image quad
#version 450

layout(push_constant) uniform PushConstants {
    vec2 viewportSize;
    vec2 atlasSize;
} pc;

struct PrimInstance {
    vec4 dstRect;      // (x, y, w, h) in device pixels
    vec4 uvRect;       // (u, v, uw, vh) in atlas texels
    vec4 clipRect;     // (cx, cy, cw, ch) in device pixels
    vec4 radii;        // (tl, tr, br, bl) in device pixels
    uvec4 packedColor; // .x = 0xRRGGBBAA, .y = kind, .z = aux0 (stroke/sigma), .w = aux1 (spread/alpha)
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    PrimInstance instances[];
} ssbo;

layout(set = 0, binding = 1) uniform sampler2D uAtlas;

#ifdef VERTEX_SHADER
layout(location = 0) out vec2 vFragCoord;
layout(location = 1) out vec2 vUV;
layout(location = 2) flat out uint vInstanceIndex;

void main() {
    uint idx = gl_InstanceIndex;
    PrimInstance inst = ssbo.instances[idx];
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = inst.dstRect.xy + corner * inst.dstRect.zw;
    vec2 ndc = (pos / pc.viewportSize) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    vFragCoord = pos;
    vUV = (inst.uvRect.xy + corner * inst.uvRect.zw) / max(pc.atlasSize, vec2(1.0));
    vInstanceIndex = idx;
}
#endif

#ifdef FRAGMENT_SHADER
layout(location = 0) in vec2 vFragCoord;
layout(location = 1) in vec2 vUV;
layout(location = 2) flat in uint vInstanceIndex;
layout(location = 0) out vec4 outColor;

vec4 unpackRGBA(uint c) {
    return vec4(
        float((c >> 24) & 0xFFu) / 255.0,
        float((c >> 16) & 0xFFu) / 255.0,
        float((c >>  8) & 0xFFu) / 255.0,
        float( c        & 0xFFu) / 255.0
    );
}

float sdRoundedBox(vec2 p, vec2 b, vec4 r) {
    vec2 rSel = (p.x > 0.0) ? r.yz : r.xw; // (tr, br) vs (tl, bl)
    float rad = (p.y > 0.0) ? rSel.y : rSel.x;
    rad = min(rad, min(b.x, b.y));
    vec2 q = abs(p) - b + vec2(rad);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

void main() {
    PrimInstance inst = ssbo.instances[vInstanceIndex];
    if (vFragCoord.x < inst.clipRect.x || vFragCoord.y < inst.clipRect.y ||
        vFragCoord.x >= inst.clipRect.x + inst.clipRect.z ||
        vFragCoord.y >= inst.clipRect.y + inst.clipRect.w) {
        discard;
    }

    vec4 baseColor = unpackRGBA(inst.packedColor.x);
    uint kind = inst.packedColor.y;
    float layerAlpha = float(inst.packedColor.w & 0xFFu) / 255.0;
    vec2 halfSize = 0.5 * inst.dstRect.zw;
    vec2 center = inst.dstRect.xy + halfSize;
    vec2 p = vFragCoord - center;

    if (kind == 0u) {
        float d = sdRoundedBox(p, halfSize, inst.radii);
        float cov = clamp(0.5 - d, 0.0, 1.0);
        outColor = vec4(baseColor.rgb, baseColor.a * cov * layerAlpha);
    } else if (kind == 1u) {
        float sw = max(float(inst.packedColor.z), 1.0);
        float dOuter = sdRoundedBox(p, halfSize, inst.radii);
        vec4 innerR = max(inst.radii - vec4(sw), vec4(0.0));
        float dInner = sdRoundedBox(p, max(halfSize - vec2(sw), vec2(0.0)), innerR);
        float cov = clamp(0.5 - dOuter, 0.0, 1.0) * clamp(0.5 + dInner, 0.0, 1.0);
        outColor = vec4(baseColor.rgb, baseColor.a * cov * layerAlpha);
    } else if (kind == 2u) {
        float sigma = max(float(inst.packedColor.z), 1.0);
        float d = sdRoundedBox(p, halfSize, inst.radii);
        float falloff = clamp(exp(-max(d, 0.0) * max(d, 0.0) / (2.0 * sigma * sigma)), 0.0, 1.0);
        outColor = vec4(baseColor.rgb, baseColor.a * falloff * layerAlpha);
    } else if (kind == 3u) {
        float cov = texture(uAtlas, vUV).a;
        outColor = vec4(baseColor.rgb, baseColor.a * cov * layerAlpha);
    } else {
        vec4 tex = texture(uAtlas, vUV);
        outColor = vec4(tex.rgb, tex.a * baseColor.a * layerAlpha);
    }
}
#endif
