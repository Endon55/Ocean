
struct GLTFMaterialData
{
    float4 color_factors;
    float4 metal_rough_factors;
};
[[vk::binding(0, 1)]]
ParameterBlock<GLTFMaterialData> material_data;

[[vk::binding(1, 1)]]
Sampler2D color_tex;
[[vk::binding(2, 1)]]
Sampler2D metal_rough_tex;

