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
    
}
Ocean_Sim_Data :: struct {
    jonswap_pipeline: vk.Pipeline,
    jonswap_layout: astro.Pipeline_Layout,
    jonswap_descriptor: vk.DescriptorSet,
    spectrum_params: Spectrum_Parameters,  
    jonswap_texture: astro.Allocated_Image, 
    random_sampler : ^Random_Sampler,
    
}

Ocean_Data :: struct {
    time: f32,
    mesh_size_x: u32,
    mesh_size_y: u32,
    texture_size: u32,
}

Random_Sampler :: struct {
    nums : [OCEAN_LAYER_COUNT]f32,
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
    toggle: bool,
    
    padding: [6]f32,
}


@(export)
game_init :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok: bool,) {

    scene.scene_data_ptr = rawptr(new(Ocean))
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    //ocean_build_pipeline(ocean, engine) or_return
    //ocean_init_default_data(ocean, engine) or_return
    game_build_pipelines(scene, engine)


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

    

    // astro.transition_image(cmd, ocean_sim.jonswap_texture.image, .UNDEFINED, .GENERAL)
    // vk.CmdBindPipeline(cmd, .COMPUTE, ocean_sim.jonswap_pipeline)
    // vk.CmdBindDescriptorSets(
    //     cmd,
    //     .COMPUTE,
    //     ocean_sim.jonswap_layout.handle,
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
        params := &ocean_sim.spectrum_params
        im.Checkbox("Toggle", &params.toggle)
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
game_reload :: proc(scene: ^astro.Scene, engine: ^astro.Engine, globals: astro.Game_Globals) -> (ok: bool,){
    vk.load_proc_addresses_global(globals.vk_proc_address)
    vk.load_proc_addresses(globals.vk_instance)
    im.SetCurrentContext(globals.imgui_context)
    im.SetAllocatorFunctions(globals.imgui_alloc_func, globals.imgui_free_func, globals.imgui_user_data)
    return true
}

ocean_init_default_data :: proc(self:^Ocean, engine:^astro.Engine) ->(ok:bool,) {

    self.plane_size = OCEAN_PLANE_SIZE; 
    self.plane_size2 = self.plane_size / 2

    self.sim_data.spectrum_params = Spectrum_Parameters {
        layer_count = OCEAN_LAYER_COUNT,
        wind_speed = 10.0,
        fetch = 100000.0,
        peak_freq = 0.35,
        storm_maturity = 2.5,
        scale = 2.0,
        short_waves_fade = 0.01,
        alignment = 0.1,
        patch_size = 1000.0,
    }



    image_usages := vk.ImageUsageFlags {
        .SAMPLED,
        .TRANSFER_SRC,
        .TRANSFER_DST,
        .STORAGE,
        .COLOR_ATTACHMENT
    }
    if astro.create_image_default == nil {
        log.warnf("Create image is nil")
    }
    self.sim_data.jonswap_texture = astro.create_image_default(
        engine, DOMAIN_GRAPH_EXTENT, .R16G16B16A16_SFLOAT, image_usages) or_return  

    self.sim_data.jonswap_descriptor = astro.descriptor_allocator_allocate(
        &engine.global_descriptor_allocator,
        astro.pipeline_layout_set(&self.sim_data.jonswap_layout, 0),
    ) or_return


    ocean_constants_buffer := astro.create_buffer(
                            engine,
                            size_of(Ocean_Data),
                            {.UNIFORM_BUFFER},
                            .CPU_TO_GPU,) or_return
    self.ocean_data = cast(^Ocean_Data)ocean_constants_buffer.info.pMappedData
    self.ocean_data.mesh_size_x = self.plane_size
    self.ocean_data.mesh_size_y = self.plane_size
    self.ocean_data.texture_size = DOMAIN_GRAPH_EXTENT.width
    astro.deletion_queue_push(&engine.main_deletion_queue, ocean_constants_buffer)
    self.ocean_material_data = astro.material_shader_write(
        &self.ocean_material,
        engine.vk_device,
        astro.Material_Pass.Main_Color,
        &engine.global_descriptor_allocator,
    ) or_return


    writer: astro.Descriptor_Writer
    astro.material_shader_init_writer(&self.ocean_material, &writer)
    astro.descriptor_writer_write_buffer(
        &writer,
        binding = 1,
        buffer = ocean_constants_buffer.buffer,
        size = size_of(Ocean_Data),
    ) or_return

    astro.descriptor_writer_write_image(
        &writer,
        binding = 2,
        image = self.sim_data.jonswap_texture.image_view,
        sampler = engine.default_sampler_linear,
    ) or_return 
    astro.descriptor_writer_update_set(&writer, self.ocean_material_data.material_set)
/*
               --------- JONSWAP PIPELINE ----------------
   */

    random_sampler_buffer := astro.create_buffer(
        engine,
        size_of(Random_Sampler),
        {.UNIFORM_BUFFER},
        .CPU_TO_GPU,) or_return

    self.sim_data.random_sampler = cast(^Random_Sampler)random_sampler_buffer.info.pMappedData
    for i in 0..<len(self.sim_data.random_sampler.nums) {
        self.sim_data.random_sampler.nums[i] = rand.float32()    
    }

    astro.deletion_queue_push(&engine.main_deletion_queue, random_sampler_buffer)
    astro.descriptor_writer_init(&writer, engine.vk_device, astro.pipeline_layout_set(&self.sim_data.jonswap_layout, 0))
    astro.descriptor_writer_write_image(
        &writer,
        binding = 0,
        image = self.sim_data.jonswap_texture.image_view,
    ) or_return
    astro.descriptor_writer_write_buffer(
        &writer,
        binding = 2,
        buffer = random_sampler_buffer.buffer,
        size = size_of(Ocean_Data),
    ) or_return
    astro.descriptor_writer_write_buffer(
        &writer,
        binding = 1,
        buffer = ocean_constants_buffer.buffer,
        size = size_of(Ocean_Data),
    ) or_return

    astro.descriptor_writer_update_set(&writer, self.sim_data.jonswap_descriptor)



    ocean_material_idx := astro.append_and_get_idx(
        &engine.scene.materials, self.ocean_material_data,
    )
    self.mesh_idx = i32(astro.generate_plane(engine, &engine.scene.meshes, self.plane_size, self.plane_size, 5.0) or_return)
    self.node_idx = astro.scene_add_mesh_node(
                   &engine.scene,
                   parent = -1,
                   mesh_index = self.mesh_idx,
                   material_index = ocean_material_idx,
                   name = "Plane",
               )
    engine.scene.local_transforms[self.node_idx] = la.matrix_mul(
        engine.scene.local_transforms[self.node_idx], 
    la.matrix4_translate_f32({-f32(self.plane_size / 2.0) , -f32(self.plane_size / 2.0), 0})
    )

    return true
}
//
// ocean_build_pipeline2 :: proc(self: ^Ocean, engine: ^astro.Engine) -> (ok: bool) {
//
//     //Vertex and Fragment Shaders
//     astro.material_shader_init(&self.ocean_material, engine, "Ocean")
//     astro.material_shader_add_binding(&self.ocean_material, 0, .COMBINED_IMAGE_SAMPLER)
//     astro.material_shader_add_binding(&self.ocean_material, 1, .UNIFORM_BUFFER)
//     astro.material_shader_add_binding(&self.ocean_material, 2, .COMBINED_IMAGE_SAMPLER)
//
//     fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
//     vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
//     if !has_fragment || !has_vertex {
//         return false
//     }
//
//     config := astro.Material_Shader_Config {
//         vertex_shader = vertex.spirv_bytes, 
//         fragment_shader = fragment.spirv_bytes, 
//     }
//     astro.material_shader_build(&self.ocean_material, engine, config) or_return
//
//     //Compute Shader
//     jonswap := &self.sim_data.jonswap_layout
//     astro.pipeline_layout_init(jonswap, engine.vk_device, "Jonswap")
//     astro.pipeline_layout_add_binding(jonswap, 0, 0, .STORAGE_IMAGE, {.COMPUTE})
//     astro.pipeline_layout_add_binding(jonswap, 0, 1, .UNIFORM_BUFFER, {.COMPUTE})
//     astro.pipeline_layout_add_binding(jonswap, 0, 2, .UNIFORM_BUFFER, {.COMPUTE})
//     astro.pipeline_layout_add_push_constant(jonswap, Spectrum_Parameters, {.COMPUTE})
//     astro.pipeline_layout_build(jonswap) or_return
//     astro.deletion_queue_push(&engine.main_deletion_queue, jonswap^)
//
//     self.sim_data.jonswap_pipeline = astro.create_shader_pipeline_compute(
//         engine,
//         "game/ocean/generate_jonswap.comp",
//         &self.sim_data.jonswap_layout,
//         false,
//     ) or_return
//
//
//     return true
// }
//
// @(export)
// game_build_pipelines2 :: proc(scene: ^astro.Scene, engine: ^astro.Engine) -> (ok: bool) {
//     ocean := cast(^Ocean)scene.scene_data_ptr
//     if ocean == nil {
//         return false
//     }
//
//     fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
//     vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
//     compute, has_compute := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/generate_jonswap.comp")
//     if !has_fragment || !has_vertex || !has_compute {
//         return false
//     }
//
//     material_pipelines := astro.material_shader_rebuild_pipelines(
//         &ocean.ocean_material,
//         engine,
//         vertex.spirv_bytes,
//         fragment.spirv_bytes,
//     ) or_return
//     defer if !ok {
//         vk.DestroyPipeline(engine.vk_device, material_pipelines.opaque.pipeline, nil)
//         vk.DestroyPipeline(engine.vk_device, material_pipelines.transparent.pipeline, nil)
//     }
//
//     compute_pipeline := astro.create_shader_pipeline_compute(
//         engine,
//         "game/ocean/generate_jonswap.comp",
//         &ocean.sim_data.jonswap_layout,
//         false,
//     ) or_return
//     defer if !ok {
//         vk.DestroyPipeline(engine.vk_device, compute_pipeline, nil)
//     }
//
//     astro.vk_check(vk.DeviceWaitIdle(engine.vk_device)) or_return
//
//     old_opaque := ocean.ocean_material.opaque_pipeline.pipeline
//     old_transparent := ocean.ocean_material.transparent_pipeline.pipeline
//     old_compute := ocean.sim_data.jonswap_pipeline
//
//     ocean.ocean_material.opaque_pipeline = material_pipelines.opaque
//     ocean.ocean_material.transparent_pipeline = material_pipelines.transparent
//     ocean.sim_data.jonswap_pipeline = compute_pipeline
//
//     vk.DestroyPipeline(engine.vk_device, old_opaque, nil)
//     vk.DestroyPipeline(engine.vk_device, old_transparent, nil)
//     vk.DestroyPipeline(engine.vk_device, old_compute, nil)
//     return true
// }
//
@(export)
game_deinit :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok:bool,){
    
    log.infof("Called deinit")  

    ocean := cast(^Ocean)scene.scene_data_ptr
    astro.material_shader_clear_resources(ocean.ocean_material)
    vk.DestroyPipeline(engine.vk_device, ocean.sim_data.jonswap_pipeline, nil)
    free(ocean)
    return true
}

ocean_build_pipeline :: proc(self: ^Ocean, engine: ^astro.Engine) -> (ok: bool) {

    //Vertex and Fragment Shaders
    astro.material_shader_init(&self.ocean_material, engine, "Ocean")
    astro.material_shader_add_binding(&self.ocean_material, 0, .COMBINED_IMAGE_SAMPLER)
    astro.material_shader_add_binding(&self.ocean_material, 1, .UNIFORM_BUFFER)
    astro.material_shader_add_binding(&self.ocean_material, 2, .COMBINED_IMAGE_SAMPLER)

    fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
    vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
    if !has_fragment || !has_vertex {
        return false
    }

    config := astro.Material_Shader_Config {
        vertex_shader = vertex.spirv_bytes, 
        fragment_shader = fragment.spirv_bytes, 
    }
    astro.material_shader_build(&self.ocean_material, engine, config) or_return

    //Compute Shader
    jonswap := &self.sim_data.jonswap_layout
    astro.pipeline_layout_init(jonswap, engine.vk_device, "Jonswap")
    astro.pipeline_layout_add_binding(jonswap, 0, 0, .STORAGE_IMAGE, {.COMPUTE})
    astro.pipeline_layout_add_binding(jonswap, 0, 1, .UNIFORM_BUFFER, {.COMPUTE})
    astro.pipeline_layout_add_binding(jonswap, 0, 2, .UNIFORM_BUFFER, {.COMPUTE})
    astro.pipeline_layout_add_push_constant(jonswap, Spectrum_Parameters, {.COMPUTE})
    astro.pipeline_layout_build(jonswap) or_return
    astro.deletion_queue_push(&engine.main_deletion_queue, jonswap^)

    self.sim_data.jonswap_pipeline = astro.create_shader_pipeline_compute(
        engine,
        "game/ocean/generate_jonswap.comp",
        &self.sim_data.jonswap_layout,
        false,
    ) or_return


    return true
}

@(export)
game_build_pipelines :: proc(scene: ^astro.Scene, engine: ^astro.Engine) -> (ok: bool) {
    ocean := cast(^Ocean)scene.scene_data_ptr
    if ocean == nil {
        return false
    }

    log.infof("test") 



    fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
    vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
    compute, has_compute := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/generate_jonswap.comp")
    if !has_fragment || !has_vertex || !has_compute {
        return false
    }
    
    // material_pipelines := astro.material_shader_rebuild_pipelines(
    //     &ocean.ocean_material,
    //     engine,
    //     vertex.spirv_bytes,
    //     fragment.spirv_bytes,
    // ) or_return
    // defer if !ok {
    //     vk.DestroyPipeline(engine.vk_device, material_pipelines.opaque.pipeline, nil)
    //     vk.DestroyPipeline(engine.vk_device, material_pipelines.transparent.pipeline, nil)
    // }
    //


    builder: astro.Shader_Pipeline_Builder
    astro.shader_pipeline_builder_init(&builder, &engine.memory_manager, engine.vk_device)
    astro.shader_pipeline_builder_set_shaders(&builder, astro.Compute_Shaders{compute = compute})
    astro.shader_pipeline_builder_bind_data_ptr(&builder, &ocean.ocean_data , 1, 1)


    builder2: astro.Shader_Pipeline_Builder
    astro.shader_pipeline_builder_init(&builder2, &engine.memory_manager, engine.vk_device)
    astro.shader_pipeline_builder_set_shaders(&builder2, astro.Render_Shaders{vertex = vertex, fragment=fragment})


    //
    // compute_pipeline := astro.create_shader_pipeline_compute(
    //     engine,
    //     "game/ocean/generate_jonswap.comp",
    //     &ocean.sim_data.jonswap_layout,
    //     false,
    // ) or_return
    // defer if !ok {
    //     vk.DestroyPipeline(engine.vk_device, compute_pipeline, nil)
    // }
    //
    // astro.vk_check(vk.DeviceWaitIdle(engine.vk_device)) or_return
    //
    // old_opaque := ocean.ocean_material.opaque_pipeline.pipeline
    // old_transparent := ocean.ocean_material.transparent_pipeline.pipeline
    // old_compute := ocean.sim_data.jonswap_pipeline
    //
    // ocean.ocean_material.opaque_pipeline = material_pipelines.opaque
    // ocean.ocean_material.transparent_pipeline = material_pipelines.transparent
    // ocean.sim_data.jonswap_pipeline = compute_pipeline
    //
    // vk.DestroyPipeline(engine.vk_device, old_opaque, nil)
    // vk.DestroyPipeline(engine.vk_device, old_transparent, nil)
    // vk.DestroyPipeline(engine.vk_device, old_compute, nil)
    // return true
    return true
}


