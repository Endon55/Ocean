#include "inc_ocean.slang"
struct PSInput
{
    float4 pos : SV_Position;
    bool frontFace : SV_IsFrontFace;
    [vk_location(0)]
    float3 outColor;
    [vk_location(1)]
    float2 outUV;
    [vk_location(2)]
    float3 worldPos;
    //slot 1 i jacobian, slot 2 is 1.0=NaN
    [vk_location(3)]
    float4 misc;
};

struct PSOutput
{
    [vk_location(0)]
    float4 out_frag_color : SV_Target0;
};

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

    // First wave direction and speed
    float2 waveDir1 = float2(0.5, 0.5);
    float waveSpeed1 = 1.0;
    float wave1 = sin(dot(uv, waveDir1) * 20.0 +  waveSpeed1) * 0.5 + 0.5;

    // Second wave direction and speed (creates interference patterns)
    float2 waveDir2 = float2(-0.3, 0.7);
    float waveSpeed2 = 1.5;
    float wave2 = sin(dot(uv, waveDir2) * 30.0 +  waveSpeed2) * 0.5 + 0.5;

    // Blend the two waves together
    float finalWave = (wave1 + wave2) * 0.5;

    // Define water colors
    float overZ = (clamp(input.worldPos.z + 20, 0, 100) / 100);
    float4 deepWater = float4(uv.x, uv.y, 1.0, 1.0);
    float4 shallowWater = float4(0.1, 0.2, 0.8, 1.0);
    float4 bottomColor = float4(1.0, overZ, 0.0, 1.0);
    if(input.misc.y == 1.0) {
        output.out_frag_color = float4(0.0, 0.0, 0.0, 1.0);
    }
    else if(!input.frontFace){
        output.out_frag_color = bottomColor;
    }
    // else if(input.jacobian.x > 0 && input.jacobian.x <= 1) {
    //     output.out_frag_color = float4(1.0, 1.0, 0, input.misc.x);
    // } 
    else if(input.misc.x > 1) {
        output.out_frag_color = float4(1.0, 1.0, 1.0, input.misc.x - 1.0);
    }
    else {
        output.out_frag_color = deepWater;
    }

    return output; 
}

