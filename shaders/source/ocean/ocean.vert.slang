struct SceneData
{
    float4x4 view;
    float4x4 proj;
    float4x4 view_proj;
    float4 ambient_color;
    float4 sunlight_direction; // w for sun power
    float4 sunlight_color;
};

struct VSOutput
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float3 outColor;
    [vk_location(1)]
    float2 outUV ;
    [vk_location(2)]
    float3 worldPos;
};

struct Vertex
{
    float3 position;
    float uv_x;
    float3 normal;
    float uv_y;
    float4 color;
};

struct OceanData {
    float time;
    uint mesh_size_x;
    uint mesh_size_y;
    uint texture_size;
    uint spectrum_index;
};

struct PushConstants
{
    float4x4 render_matrix;
    Vertex *vertex_buffer;
};

[vk_push_constant]
PushConstants push_constants;

[[vk_binding(0, 0)]]
Texture2D<float4> images[];

[[vk_binding(1, 0)]]
SamplerState samplers[];

[[vk_binding(0, 1)]]
ConstantBuffer<SceneData> scene_data;

[[vk_binding(1, 1)]]
ConstantBuffer<OceanData> ocean_data;

[shader("vertex")]
VSOutput main(uint vertex_index: SV_VertexID)
{
    Vertex v = push_constants.vertex_buffer[vertex_index];

    float4 position = float4(v.position, 1.0);
    VSOutput output;
    output.pos = position;
    uint2 texel = uint2(clamp(float2(v.uv_x, v.uv_y), 0.0, 1.0) * float(ocean_data.texture_size - 1) + 0.5);
    float4 spec = images[ocean_data.spectrum_index].SampleLevel(samplers[0], float2(v.uv_x, v.uv_y), 0.0);
    output.pos.xyz += spec.xyz;
    output.worldPos = output.pos.xyz;
    output.pos = mul(scene_data.view_proj, mul(push_constants.render_matrix, output.pos));

    output.outColor = v.color.xyz;
    output.outUV.x = v.uv_x;
    output.outUV.y = v.uv_y;

    return output;
}
