package Ocean 

import "core:math"
import "core:math/rand"
import la "core:math/linalg"
import vk "vendor:vulkan"
import astro "../../src/"
import "core:log"

import im "libs:imgui"
// resolution must stay proportional to patch_size (deltaK = 2*pi/patch_size) or the energetic
// wavenumbers collapse into a tiny blob at the texture center
DOMAIN_GRAPH_EXTENT :: vk.Extent3D{256, 256, 1}

OCEAN_LAYER_COUNT :: 32
OCEAN_PLANE_SIZE :: 64 


Ocean :: struct {

    plane_size: u32,
    plane_size2: u32,

    ocean_material: astro.Material_Shader,
    ocean_material_data: astro.Material_Instance,
    mesh_idx: i32,
    node_idx: i32,
    ocean_data: ^Ocean_Data,
    sim_data: Ocean_Sim_Data,
    render_pipeline: astro.Shader_Pipeline,
    
}
Ocean_Sim_Data :: struct {
    jonswap_pipeline: astro.Shader_Pipeline,
    // jonswap_pipeline: vk.Pipeline,
    // jonswap_layout: astro.Pipeline_Layout,
    // jonswap_descriptor: vk.DescriptorSet,
    spectrum_params: ^Spectrum_Parameters,  
    jonswap_texture: astro.Texture_Reference, 
    random_sampler: [256]f32,
}

Ocean_Data :: struct {
    time: f32,
    mesh_size_x: u32,
    mesh_size_y: u32,
    texture_size: u32,
}



Spectrum_Parameters :: struct {
    layer_count: i32,
    wind_speed: f32,
    fetch: f32,
    storm_maturity: f32,
    peak_freq: f32,

    scale: f32,
    short_waves_fade: f32,
    alignment: f32,
    patch_size: f32,
    toggle: b32,
    
    padding: [6]f32,
}


@(export)
game_init :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok: bool,) {

    scene.scene_data_ptr = rawptr(new(Ocean))
    ocean := cast(^Ocean)scene.scene_data_ptr
   
    for i in 0..<len(ocean.sim_data.random_sampler) {
        ocean.sim_data.random_sampler[i] = rand.float32()    
    }

    fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
    vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
    compute, has_compute := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/generate_jonswap.comp")
    if !has_fragment || !has_vertex || !has_compute {
        return false
    }

    image_usages := vk.ImageUsageFlags {
        .SAMPLED,
        .TRANSFER_SRC,
        .TRANSFER_DST,
        .STORAGE,
        .COLOR_ATTACHMENT
    }
    image := astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R16G16B16A16_SFLOAT, image_usages) or_return
    ocean.sim_data.jonswap_texture = astro.memory_manager_register_texture(&engine.memory_manager, image) or_return



    builder: astro.Shader_Pipeline_Builder
    astro.shader_pipeline_builder_init(&builder, &engine.memory_manager, engine.vk_device, .COMPUTE)
    astro.shader_pipeline_builder_set_shaders(&builder, astro.Compute_Shaders{compute = compute})
    astro.shader_pipeline_builder_bind_uniform_ptr(&builder, &ocean.ocean_data , 1, 1)
    astro.shader_pipeline_builder_bind_uniform_ptr(&builder, &ocean.sim_data.spectrum_params, 1, 2)
    astro.shader_pipeline_builder_bind_image(&builder, ocean.sim_data.jonswap_texture, 1, 0)
    astro.shader_pipeline_builder_bind_new_static_buffer(&builder, engine, &ocean.sim_data.random_sampler, set = 1, binding = 3,)

    ocean.sim_data.jonswap_pipeline = astro.shader_pipeline_builder_build(&builder, engine) or_return

    ocean.ocean_data.mesh_size_x = DOMAIN_GRAPH_EXTENT.width
    ocean.ocean_data.mesh_size_y = DOMAIN_GRAPH_EXTENT.height
    ocean.ocean_data.texture_size = DOMAIN_GRAPH_EXTENT.width

    ocean.sim_data.spectrum_params.layer_count = 32
    ocean.sim_data.spectrum_params.peak_freq = .2
    ocean.sim_data.spectrum_params.storm_maturity = 3.3
    ocean.sim_data.spectrum_params.scale = 1
    ocean.sim_data.spectrum_params.patch_size = 64 

    builder2: astro.Shader_Pipeline_Builder
    astro.shader_pipeline_builder_init(&builder2, &engine.memory_manager, engine.vk_device, .GRAPHICS)
    astro.shader_pipeline_builder_set_shaders(&builder2, astro.Render_Shaders{vertex = vertex, fragment=fragment})
    astro.shader_pipeline_builder_set_input_topology(&builder2, .TRIANGLE_LIST)
    astro.shader_pipeline_builder_set_polygon_mode(&builder2, .FILL)
    astro.shader_pipeline_builder_set_cull_mode(&builder2, vk.CullModeFlags_NONE, .CLOCKWISE)
    astro.shader_pipeline_builder_set_multisampling_none(&builder2)
    astro.shader_pipeline_builder_disable_blending(&builder2)
    astro.shader_pipeline_builder_enable_depth_test(&builder2, true, .GREATER_OR_EQUAL)
    astro.shader_pipeline_builder_set_color_attachment_format(&builder2, engine.draw_image.image_format)
    astro.shader_pipeline_builder_set_depth_attachment_format(&builder2, engine.depth_image.image_format)
    ocean.render_pipeline = astro.shader_pipeline_builder_build(&builder2, engine) or_return



    return true
}
@(export)
game_update :: proc(scene: ^astro.Scene, engine: ^astro.Engine, delta_time: f32) ->(ok: bool,) {

    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_data := ocean.ocean_data
    ocean_data.time += delta_time 
    
    return true
}

@(export)
game_draw :: proc(scene: ^astro.Scene, engine: ^astro.Engine, cmd: vk.CommandBuffer) -> (ok: bool,){
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_sim := &ocean.sim_data

    astro.transition_image(cmd, ocean_sim.jonswap_texture.image.image, .UNDEFINED, .GENERAL)
    astro.shader_pipeline_bind(&ocean_sim.jonswap_pipeline, cmd, engine)
    vk.CmdDispatch(
        cmd,
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
        1,
    )
    astro.transition_image(cmd, ocean_sim.jonswap_texture.image.image, .GENERAL, .SHADER_READ_ONLY_OPTIMAL)


    //vk.CmdBindPipeline(cmd, .COMPUTE, ocean_sim.jonswap_pipeline.pipeline)
    // vk.CmdBindDescriptorSets(
    //     cmd,
    //     .COMPUTE,
    //     ocean_sim.jonswap_pipeline.layout,
    //     0,
    //     1,
    //     &ocean_sim.jonswap_descriptor,
    //     0,
    //     nil,
    // )
    // vk.CmdPushConstants(
    //     cmd,
    //     ocean_sim.jonswap_layout.handle,
    //     {.COMPUTE},
    //     0,
    //     size_of(Spectrum_Parameters),
    //     &ocean_sim.spectrum_params,
    // )
    // vk.CmdDispatch(
    //     cmd,
    //     u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
    //     u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
    //     1,
    // )
    // astro.transition_image(cmd, ocean_sim.jonswap_texture.image, .GENERAL, .SHADER_READ_ONLY_OPTIMAL)
    //
    //
    return true
}

@(export)
game_draw_ui :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok:bool) { 
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_sim := &ocean.sim_data
    ocean_data := &ocean.ocean_data
    if im.Begin("Ocean", nil, {.AlwaysAutoResize}) {
        params := ocean_sim.spectrum_params
        im.Checkbox("Toggle", cast(^bool)&params.toggle)
        im.SliderInt("Layers", &params.layer_count, 4, 256)
        im.SliderFloat("Wind speed", &params.wind_speed, 0.0, 30.0)
        im.SliderFloat("Fetch", &params.fetch, 0.0, 500000.0)
        im.SliderFloat("Storm Maturity", &params.storm_maturity, 1.0, 10.0)
        im.SliderFloat("Peak Frequency", &params.peak_freq, .05, 1.0)
        im.SliderFloat("Scale", &params.scale, 0.0, 10.0)
        im.SliderFloat("Short waves fade", &params.short_waves_fade, 0.0, 1.0)
        im.SliderFloat("Alignment", &params.alignment, 0.0, 1.0)
    }
    im.End()

    return true
}

@(export)
game_build_pipelines :: proc(scene: ^astro.Scene, engine: ^astro.Engine) -> (ok: bool) {
    // ocean := cast(^Ocean)scene.scene_data_ptr
    // if ocean == nil {
    //     return false
    // }
    // for i in 0..<len(ocean.sim_data.random_sampler) {
    //     ocean.sim_data.random_sampler[i] = rand.float32()    
    // }
    //
    // fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
    // vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
    // compute, has_compute := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/generate_jonswap.comp")
    // if !has_fragment || !has_vertex || !has_compute {
    //     return false
    // }
    //
    // image_usages := vk.ImageUsageFlags {
    //     .SAMPLED,
    //     .TRANSFER_SRC,
    //     .TRANSFER_DST,
    //     .STORAGE,
    //     .COLOR_ATTACHMENT
    // }
    // image := astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R16G16B16A16_SFLOAT, image_usages) or_return
    // ocean.sim_data.jonswap_texture = astro.memory_manager_register_texture(&engine.memory_manager, image) or_return
    //
    //
    //
    // builder: astro.Shader_Pipeline_Builder
    // astro.shader_pipeline_builder_init(&builder, &engine.memory_manager, engine.vk_device, .COMPUTE)
    // astro.shader_pipeline_builder_set_shaders(&builder, astro.Compute_Shaders{compute = compute})
    // astro.shader_pipeline_builder_bind_uniform_ptr(&builder, &ocean.ocean_data , 1, 1)
    // astro.shader_pipeline_builder_bind_uniform_ptr(&builder, &ocean.sim_data.spectrum_params, 1, 2)
    // astro.shader_pipeline_builder_bind_image(&builder, ocean.sim_data.jonswap_texture, 1, 0)
    // astro.shader_pipeline_builder_bind_new_static_buffer(&builder, engine, &ocean.sim_data.random_sampler, set = 1, binding = 3,)
    //
    // ocean.sim_data.jonswap_pipeline = astro.shader_pipeline_builder_build(&builder, engine) or_return
       return true
}

@(export)
game_reload :: proc(scene: ^astro.Scene, engine: ^astro.Engine, globals: astro.Game_Globals) -> (ok: bool,){
    vk.load_proc_addresses_global(globals.vk_proc_address)
    vk.load_proc_addresses(globals.vk_instance)
    im.SetCurrentContext(globals.imgui_context)
    im.SetAllocatorFunctions(globals.imgui_alloc_func, globals.imgui_free_func, globals.imgui_user_data)
    return true
}

@(export)
game_deinit :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok:bool,){
    
    log.infof("Called deinit")  

    ocean := cast(^Ocean)scene.scene_data_ptr
    // astro.material_shader_clear_resources(ocean.ocean_material)
    // vk.DestroyPipeline(engine.vk_device, ocean.sim_data.jonswap_pipeline, nil)
    // free(ocean)
    free(scene.scene_data_ptr)
    return true
}


