// LeanUI Exact uint32 Separable Box Blur Compute Shader (Vulkan 1.3 / GLSL 450)
// Matches c/lean_ui_vulkan.c:lean_ui_box_axis bit-for-bit:
//   dst[i] = (sum + radius) / (2 * radius + 1) with edge clamping.
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(push_constant) uniform BlurPushConstants {
    uint width;
    uint height;
    uint radius;
    uint horizontal;
} pc;

layout(set = 0, binding = 0, rgba8) readonly uniform image2D uSrc;
layout(set = 0, binding = 1, rgba8) writeonly uniform image2D uDst;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= pc.width || y >= pc.height) {
        return;
    }
    if (pc.radius == 0u) {
        imageStore(uDst, ivec2(x, y), imageLoad(uSrc, ivec2(x, y)));
        return;
    }

    int r = int(pc.radius);
    uint denom = 2u * pc.radius + 1u;
    uvec4 sum = uvec4(0u);

    if (pc.horizontal != 0u) {
        int maxX = int(pc.width) - 1;
        int cy = int(y);
        for (int dx = -r; dx <= r; ++dx) {
            int sx = clamp(int(x) + dx, 0, maxX);
            vec4 px = imageLoad(uSrc, ivec2(sx, cy));
            sum += uvec4(round(clamp(px, 0.0, 1.0) * 255.0));
        }
    } else {
        int maxY = int(pc.height) - 1;
        int cx = int(x);
        for (int dy = -r; dy <= r; ++dy) {
            int sy = clamp(int(y) + dy, 0, maxY);
            vec4 px = imageLoad(uSrc, ivec2(cx, sy));
            sum += uvec4(round(clamp(px, 0.0, 1.0) * 255.0));
        }
    }

    uvec4 outU = (sum + uvec4(pc.radius)) / denom;
    imageStore(uDst, ivec2(x, y), vec4(outU) / 255.0);
}
