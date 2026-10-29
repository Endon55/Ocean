
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
};

struct PSOutput
{
    [vk_location(0)]
    float4 out_frag_color : SV_Target0;
};

struct OceanData {
    float time;
    uint mesh_size_x;
    uint mesh_size_y;
    uint texture_size;
    uint spectrum_index;
};

[[vk_binding(1, 1)]]
ConstantBuffer<OceanData> globalData;

// Fragment shader entry point
[shader("fragment")]
PSOutput main(PSInput input) : SV_Target
{
    PSOutput output;
    float2 uv = input.outUV;
    float time = globalData.time;

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

    // Define water cnpilors
    float overZ = (clamp(input.worldPos.z + 20, 0, 100) / 100);
    float4 deepWater = float4(uv.x, uv.y, 1.0, 1.0);
    float4 shallowWater = float4(0.1, 0.2, 0.8, 1.0);
    float4 bottomColor = float4(1.0, overZ, 0.0, 1.0);
    if(input.frontFace){
        output.out_frag_color = deepWater;
    }
    else {
        output.out_frag_color = bottomColor;
    }
    // Mix colors based on the moving wave value
    //output.out_frag_color = lerp(deepWater, shallowWater, finalWave);
    return output; 
}

