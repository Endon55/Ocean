#include "inc_scene_data.slang"

struct PSInput
{
    [vk_location(0)]
    float3 inColor : COLOR;
    [vk_location(1)]
    float2 inUV : TEXCOORD0;
};

struct PSOutput
{
    [vk_location(0)]
    float4 out_frag_color : SV_Target0;
};

[shader("fragment")]
PSOutput main(PSInput input)
{
    PSOutput output;

    float light_value = max(dot(float3(0.0, 1.0, 0.0), scene_data.sunlight_direction.xyz), 0.1);

    //float3 color = float3(0.1, 0.1, 1.0);
    float3 color = input.inColor;
    float3 ambient = color * scene_data.ambient_color.xyz;

    output.out_frag_color =
        float4(color * light_value * scene_data.sunlight_color.w + ambient, 1.0);


    return output;
}
