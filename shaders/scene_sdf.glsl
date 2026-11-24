// LeanUI Unified Scene SDF + Glyph Atlas Shader (Vulkan 1.3 / GLSL 450)
// Premultiplied RGBA8 output with VK_BLEND_FACTOR_ONE / VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA.
// Supports instanced draws for:
//   kind = 0: SDF rounded rectangle fill (r4 per-corner radii)
//   kind = 1: SDF rounded rectangle border (asymmetric uvRect=(bt,br,bb,bl) + r4 radii)
//   kind = 2: Compute-blurred drop shadow mask composite (uAuxTex)
//   kind = 3: R8 coverage glyph / mask sample from 8-layer uAtlas
//   kind = 4: Premultiplied color glyph sample from 8-layer uAtlas
//   kind = 5: Rounded-rect textured RGBA8 image quad (uAuxTex) or solid placeholder
//   kind = 6: Two-stop CSS angled linear gradient in SDF rounded rect
//   kind = 7: Offscreen opacity layer composite from 4-layer uLayers
#version 450

layout(push_constant) uniform PushConstants {
    vec2 viewportSize;
    vec2 atlasSize;
    vec2 layerTexSize;
    vec2 imageTexSize;
} pc;

struct PrimInstance {
    ivec4 dstRect;     // (x, y, w, h) in device pixels
    ivec4 uvRect;      // (u, v, uw, vh) in source texels; for kind=1: (bt, br, bb, bl)
    ivec4 clipRect;    // (cx, cy, cw, ch) axis-aligned scissor in device pixels
    uvec4 radii;       // (tl, tr, br, bl) in device pixels
    uvec4 packedColor; // .x = 0xRRGGBBAA
                       // .y = kind (0..7) | (roundedClipIdx << 8)
                       // .z = aux0 (c1 / blur / atlasPageIdx / layerSlot / texSlot)
                       // .w = aux1 (layerAlpha[7:0] | angleDeg[23:8] | flags[31:24])
};

struct ClipNode {
    ivec4 rect;        // (x, y, w, h) in device pixels
    uvec4 radii;       // (tl, tr, br, bl) in device pixels
    uvec4 meta;        // .x = parentIdx (1-based; 0 = root)
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    PrimInstance instances[];
} ssbo;

layout(set = 0, binding = 1) uniform sampler2DArray uAtlas;

layout(std430, set = 0, binding = 2) readonly buffer ClipBuffer {
    ClipNode clips[];
} clipBuf;

layout(set = 0, binding = 3) uniform sampler2DArray uLayers;
layout(set = 0, binding = 4) uniform sampler2D uAuxTex;

#ifdef VERTEX_SHADER
layout(location = 0) out vec2 vFragCoord;
layout(location = 1) out vec2 vUV;
layout(location = 2) flat out uint vInstanceIndex;

void main() {
    uint idx = gl_InstanceIndex;
    PrimInstance inst = ssbo.instances[idx];
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = vec2(inst.dstRect.xy) + corner * vec2(inst.dstRect.zw);
    vec2 ndc = (pos / max(pc.viewportSize, vec2(1.0))) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    vFragCoord = pos;
    uint kind = inst.packedColor.y & 0xFFu;
    if (kind == 2u || kind == 5u) {
        vUV = (vec2(inst.uvRect.xy) + corner * vec2(inst.uvRect.zw)) / max(pc.imageTexSize, vec2(1.0));
    } else if (kind == 7u) {
        vUV = pos / max(pc.layerTexSize, vec2(1.0));
    } else {
        vUV = (vec2(inst.uvRect.xy) + corner * vec2(inst.uvRect.zw)) / max(pc.atlasSize, vec2(1.0));
    }
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
        float((c >> 24u) & 0xFFu) / 255.0,
        float((c >> 16u) & 0xFFu) / 255.0,
        float((c >>  8u) & 0xFFu) / 255.0,
        float( c         & 0xFFu) / 255.0
    );
}

float sdRoundedBox16(vec2 p, vec2 b, vec4 r) {
    vec2 rSel = (p.x >= 0.0) ? r.yz : r.xw; // (tr, br) vs (tl, bl)
    float rad = (p.y >= 0.0) ? rSel.y : rSel.x;
    rad = floor(min(rad, floor(min(b.x, b.y))));
    vec2 b16 = round(b * 16.0);
    vec2 p16 = round(abs(p * 16.0));
    float rad16 = rad * 16.0;
    vec2 q16 = p16 - b16 + vec2(rad16);
    vec2 m16 = max(q16, vec2(0.0));
    float d2 = dot(m16, m16);
    float outLen16 = floor(sqrt(d2));
    if (outLen16 * outLen16 > d2) {
        outLen16 -= 1.0;
    }
    if ((outLen16 + 1.0) * (outLen16 + 1.0) <= d2) {
        outLen16 += 1.0;
    }
    return min(max(q16.x, q16.y), 0.0) + outLen16 - rad16;
}

float covOut16(float d16) {
    if (d16 <= -8.0) return 1.0;
    if (d16 >= 8.0) return 0.0;
    return floor((8.0 - d16) * 255.0 / 16.0) / 255.0;
}

float covIn16(float d16) {
    if (d16 >= 8.0) return 1.0;
    if (d16 <= -8.0) return 0.0;
    return floor((d16 + 8.0) * 255.0 / 16.0) / 255.0;
}

void main() {
    PrimInstance inst = ssbo.instances[vInstanceIndex];
    vec2 fragPos = gl_FragCoord.xy;
    if (fragPos.x < float(inst.clipRect.x) ||
        fragPos.y < float(inst.clipRect.y) ||
        fragPos.x >= float(inst.clipRect.x + inst.clipRect.z) ||
        fragPos.y >= float(inst.clipRect.y + inst.clipRect.w)) {
        discard;
    }

    float clipCov = 1.0;
    uint clipIdx = inst.packedColor.y >> 8u;
    for (int step = 0; step < 8 && clipIdx != 0u; ++step) {
        ClipNode cn = clipBuf.clips[clipIdx - 1u];
        vec2 cHalf = 0.5 * vec2(cn.rect.zw);
        vec2 cCenter = vec2(cn.rect.xy) + cHalf;
        float dClip16 = sdRoundedBox16(fragPos - cCenter, cHalf, vec4(cn.radii));
        clipCov *= covOut16(dClip16);
        if (clipCov <= 0.0) {
            discard;
        }
        clipIdx = cn.meta.x;
    }

    vec4 baseColor = unpackRGBA(inst.packedColor.x);
    uint kind = inst.packedColor.y & 0xFFu;
    float layerAlpha = float(inst.packedColor.w & 0xFFu) / 255.0;
    vec2 halfSize = 0.5 * vec2(inst.dstRect.zw);
    vec2 center = vec2(inst.dstRect.xy) + halfSize;
    vec2 p = fragPos - center;

    if (kind == 0u) {
        float cov = covOut16(sdRoundedBox16(p, halfSize, vec4(inst.radii))) * clipCov;
        float effA = baseColor.a * cov * layerAlpha;
        outColor = vec4(baseColor.rgb * effA, effA);
    } else if (kind == 1u) {
        vec4 bw = vec4(inst.uvRect); // (bt, br, bb, bl)
        float bt = bw.x, brW = bw.y, bbW = bw.z, blW = bw.w;
        vec2 innerHalf = max(halfSize - 0.5 * vec2(blW + brW, bt + bbW), vec2(0.0));
        vec2 pInner = p - 0.5 * vec2(blW - brW, bt - bbW);
        vec4 innerRadii = max(
            vec4(inst.radii) - vec4(max(bt, blW), max(bt, brW), max(bbW, brW), max(bbW, blW)),
            vec4(0.0)
        );
        float cOut = covOut16(sdRoundedBox16(p, halfSize, vec4(inst.radii)));
        float cIn = covIn16(sdRoundedBox16(pInner, innerHalf, innerRadii));
        float cov = cOut * cIn * clipCov;
        float effA = baseColor.a * cov * layerAlpha;
        outColor = vec4(baseColor.rgb * effA, effA);
    } else if (kind == 2u) {
        float cov = texture(uAuxTex, vUV).a * clipCov;
        float effA = baseColor.a * cov * layerAlpha;
        outColor = vec4(baseColor.rgb * effA, effA);
    } else if (kind == 3u) {
        uint pageIdx = clamp(inst.packedColor.z, 0u, 7u);
        float cov = texture(uAtlas, vec3(vUV, float(pageIdx))).a * clipCov;
        float effA = baseColor.a * cov * layerAlpha;
        outColor = vec4(baseColor.rgb * effA, effA);
    } else if (kind == 4u) {
        uint pageIdx = clamp(inst.packedColor.z, 0u, 7u);
        vec4 tex = texture(uAtlas, vec3(vUV, float(pageIdx)));
        float modA = baseColor.a * clipCov * layerAlpha;
        outColor = vec4(tex.rgb * modA, tex.a * modA);
    } else if (kind == 5u) {
        float cov = covOut16(sdRoundedBox16(p, halfSize, vec4(inst.radii))) * clipCov;
        if (inst.uvRect.z > 0 && inst.uvRect.w > 0) {
            vec4 tex = texture(uAuxTex, vUV);
            float modA = cov * layerAlpha;
            outColor = vec4(tex.rgb * modA, tex.a * modA);
        } else {
            float effA = baseColor.a * cov * layerAlpha;
            outColor = vec4(baseColor.rgb * effA, effA);
        }
    } else if (kind == 6u) {
        vec4 c1 = unpackRGBA(inst.packedColor.z);
        float angleDeg = float((inst.packedColor.w >> 8u) & 0xFFFFu);
        float rad = radians(mod(angleDeg, 360.0));
        vec2 dir = vec2(sin(rad), -cos(rad));
        float halfLen = max(abs(dir.x) * halfSize.x + abs(dir.y) * halfSize.y, 1e-4);
        float t = clamp(dot(p, dir) / (2.0 * halfLen) + 0.5, 0.0, 1.0);
        vec4 gradCol = mix(baseColor, c1, t);
        float cov = covOut16(sdRoundedBox16(p, halfSize, vec4(inst.radii))) * clipCov;
        float effA = gradCol.a * cov * layerAlpha;
        outColor = vec4(gradCol.rgb * effA, effA);
    } else {
        uint layerSlot = clamp(inst.packedColor.z, 0u, 3u);
        vec4 tex = texture(uLayers, vec3(vUV, float(layerSlot)));
        float modA = layerAlpha * clipCov;
        outColor = vec4(tex.rgb * modA, tex.a * modA);
    }
}
#endif
