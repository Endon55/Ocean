#include "inc_ocean.slang"
#include "../inc_scene_data.slang"

struct VSOutput
{
    float4 pos : SV_Position; 
    [vk_location(0)]
    float3 worldPos;
    [vk_location(1)]
    float3 normal;
    [vk_location(2)]
    float4 outColor;
    [vk_location(3)]
    float2 outUV;
    [vk_location(4)]
    float4 misc;
};

struct Vertex
{
    float3 position;
    float uv_x;
    float3 normal;
    float uv_y;
    float4 color;
};

struct PushConstants
{
    float4x4 render_matrix;
    Vertex *vertex_buffer;
};

[vk_push_constant]
PushConstants push_constants;

[[vk_binding(0, 0)]]
Texture2DArray images[];

[[vk_binding(1, 0)]]
SamplerState samplers[];

[[vk_binding(0, 1)]]
ConstantBuffer<SceneData> scene_data;

[[vk_binding(1, 1)]]
ConstantBuffer<OceanData> ocean_data;
[[vk_binding(2, 1)]]
ConstantBuffer<SpectrumParams, Std430DataLayout> params;


/*
    Engine assumes a z-up axis convention, reference the engine documentation for specifics
    This ocean will abide that convention.
*/
[shader("vertex")]
VSOutput main(uint vertex_index: SV_VertexID)
{
    Vertex v = push_constants.vertex_buffer[vertex_index];
    
    float4 position = float4(v.position, 1.0);
    float2 slope = float2(0);

    for(int i = 0; i < SPECTRUMS; i++) {

       float3 spectrum_uv = float3(v.position.x / params.length_scale[i], v.position.y / params.length_scale[i], (float)i);

       float4 spec = images[ocean_data.displacement_index].SampleLevel(samplers[0], spectrum_uv,  0.0);
       position.xyz += spec.xyz; 
        slope += images[ocean_data.slope_index].SampleLevel(samplers[0], spectrum_uv, 0.0).xy;
    }

    VSOutput output;


    float3 tangent = float3(1.0, 0.0, slope.x);
    float3 bitangent = float3(0.0, 1.0, slope.y);
    output.normal = normalize(cross(tangent, bitangent));
    //float2 tiled_uvs = float2(position.x % ocean_data.texture_size, position.y % ocean_data.texture_size);
    output.pos = float4(position.xyz, 1.0);
    output.pos = mul(push_constants.render_matrix, output.pos);
    output.worldPos = output.pos.xyz;
    output.pos = mul(scene_data.view_proj, output.pos);

    output.outColor = v.color;
    output.outUV.x = v.uv_x;
    output.outUV.y = v.uv_y;
    output.misc = float4(position.w, 0.0, 0.0, 0.0);
    if(isnan(position.x) || isnan(position.y) || isnan(position.z) || isnan(position.w)) {
        output.misc.y = 1.0;
    }
    return output;
}
