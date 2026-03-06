// PassThrough vertex + fragment shader for PRMPreviewMetalView.
// Renders a textured quad (camera frame) to the screen.

#include <metal_stdlib>
using namespace metal;

struct VertexIO {
    float4 position [[position]];
    float2 textureCoord [[user(texturecoord)]];
};

vertex VertexIO vertexPassThrough(
    const device packed_float4 *pPosition  [[ buffer(0) ]],
    const device packed_float2 *pTexCoords [[ buffer(1) ]],
    uint                        vid        [[ vertex_id ]]
) {
    VertexIO outVertex;
    outVertex.position = pPosition[vid];
    outVertex.textureCoord = pTexCoords[vid];
    return outVertex;
}

fragment half4 fragmentPassThrough(
    VertexIO         inputFragment [[ stage_in ]],
    texture2d<half>  inputTexture  [[ texture(0) ]],
    sampler          samplr        [[ sampler(0) ]]
) {
    return inputTexture.sample(samplr, inputFragment.textureCoord);
}
