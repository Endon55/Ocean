#include "inc_ocean.slang"
#include "../inc_scene_data.slang"
#include "../../../../shaders/source/MasterPBR.slang"
struct PSInput
{
    float4 pos : SV_Position;
    bool frontFace : SV_IsFrontFace;
    [vk_location(0)]
    float3 worldPos;
    [vk_location(1)]
    float3 normal;
    [vk_location(2)]
    float3 outColor;
    [vk_location(3)]
    float2 outUV;
    [vk_location(4)]
    float4 misc; 
};

struct PSOutput
{
    [vk_location(0)]
    float4 out_frag_color : SV_Target0;
};

[[vk_binding(0, 1)]]
ConstantBuffer<SceneData> scene_data;
[[vk_binding(1, 1)]]
ConstantBuffer<OceanData> ocean_data;

/*
    Engine assumes a z-up axis convention, reference the engine documentation for specifics
    This ocean will abide that convention.
*/
[shader("fragment")]
PSOutput main(PSInput input) : SV_Target
{
    PSOutput output;

    float2 uv = input.outUV;
    float time = ocean_data.time;
    PBR_Data data;
    data.albedo = float3(.01, .02, .8);
    data.roughness = 0.1;
    data.ambient_occlusion = 1.0;
    data.metallic = .2;

    output.out_frag_color = float4(calculate_pbr(data, input.normal, input.worldPos, scene_data.camera_world_position), 1.0);

    return output; 
}

