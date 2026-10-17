
struct PSInput
{
    [vk_location(0)]
    float3 inColor : COLOR;
    [vk_location(1)]
    float2 uv : TEXCOORD0;
};

struct PSOutput
{
    [vk_location(0)]
    float4 out_frag_color : SV_Target0;
};

// Uniform buffer for time and animation parameters
struct UniformData
{
    float time;
};

// Bind the uniform buffer to set 0, binding 0
[[vk::binding(0, 0)]]
ConstantBuffer<UniformData> globalData;

// Fragment shader entry point
[shader("fragment")]
PSOutput main(PSInput input) : SV_Target
{
    PSOutput output;
    float2 uv = input.uv;
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

    // Define water colors
    float4 deepWater = float4(0.1, 0.3, .5, 1.0);
    float4 shallowWater = float4(0.5, 0.7, 0.8, 1.0);

    // Mix colors based on the moving wave value
    output.out_frag_color = lerp(deepWater, shallowWater, finalWave);
    output.out_frag_color.xyz += input.inColor;
    return output; 
}

