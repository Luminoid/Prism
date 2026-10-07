#include <metal_stdlib>
using namespace metal;

// Night merge: every frame is drawn into one rgba16Float accumulator with additive blending.
// The fragment shader warps the frame onto the reference (a homography in pixels, top-left
// origin), converts it to linear light, and outputs (rgb * w, w), so the accumulator holds
// the weighted sum in rgb and the summed weight in alpha. The normalize pass divides them.

struct NightMergeUniforms {
    float3x3 warp;       // reference pixel -> frame pixel
    float2 frameSize;    // frame size in pixels
    float2 smallScale;   // quarter-resolution pixels per full-resolution pixel
    float ghostLow;      // relative luma difference where a frame's weight starts to fall
    float ghostHigh;     // ... and where it reaches zero
    uint transfer;       // 0 = sRGB, 1 = ITU-R BT.709
    uint isReference;    // the reference goes in with weight 1, unwarped
};

struct NightVertexOut {
    float4 position [[position]];
};

// One triangle that covers the whole render target.
vertex NightVertexOut nightFullscreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    NightVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float decodeChannel(float value, uint transfer) {
    if (transfer == 1) {
        return value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1.0 / 0.45);
    }
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static float encodedLuma(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

fragment float4 nightAccumulateFragment(
    NightVertexOut in [[stage_in]],
    texture2d<float> frame [[texture(0)]],
    texture2d<float> frameSmall [[texture(1)]],
    texture2d<float> referenceSmall [[texture(2)]],
    constant NightMergeUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler pixelSampler(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 point = in.position.xy;
    float3 mapped = uniforms.warp * float3(point, 1.0);
    if (mapped.z <= 0.0) {
        return float4(0.0);
    }
    float2 source = mapped.xy / mapped.z;
    if (source.x < 0.0 || source.y < 0.0 || source.x > uniforms.frameSize.x || source.y > uniforms.frameSize.y) {
        return float4(0.0);
    }
    float3 encoded = frame.sample(pixelSampler, source).rgb;
    float3 linearColor = float3(
        decodeChannel(encoded.r, uniforms.transfer),
        decodeChannel(encoded.g, uniforms.transfer),
        decodeChannel(encoded.b, uniforms.transfer)
    );
    float weight = 1.0;
    if (uniforms.isReference == 0) {
        // Ghost rejection at quarter resolution, where the noise is a quarter as strong: a
        // pixel that differs from the reference by more than noise is a moving subject.
        float referenceLuma = encodedLuma(referenceSmall.sample(pixelSampler, point * uniforms.smallScale).rgb);
        float frameLuma = encodedLuma(frameSmall.sample(pixelSampler, source * uniforms.smallScale).rgb);
        float difference = abs(frameLuma - referenceLuma) / (referenceLuma + 0.05);
        weight = 1.0 - smoothstep(uniforms.ghostLow, uniforms.ghostHigh, difference);
    }
    return float4(linearColor * weight, weight);
}

fragment float4 nightNormalizeFragment(
    NightVertexOut in [[stage_in]],
    texture2d<float> accumulator [[texture(0)]]
) {
    float4 sum = accumulator.read(uint2(in.position.xy));
    float weight = max(sum.a, 1e-4);
    return float4(sum.rgb / weight, 1.0);
}
