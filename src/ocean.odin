package Ocean 

import "core:math"
import "core:math/rand"
import la "core:math/linalg"
import vk "vendor:vulkan"
import astro "../../src/"
import "core:log"

import im "libs:imgui"
import glfw "vendor:glfw"
// resolution must stay proportional to patch_size (deltaK = 2*pi/patch_size) or the energetic
// wavenumbers collapse into a tiny blob at the texture center

DOMAIN_GRAPH_EXTENT :: vk.Extent3D{256, 256, 1}

OCEAN_LAYER_COUNT :: 32
OCEAN_PLANE_SIZE :: 64 
OCEAN_VERTEX_DENSITY :: 25

GLOBALS : ^astro.Engine_Globals


Ocean :: struct {

    plane_size: u32,
    plane_size2: u32,

    ocean_material: astro.Material_Shader,
    ocean_material_data: astro.Material_Instance,
    mesh_idx: i32,
    node_idx: i32,
    ocean_data: ^Ocean_Data,
    render_ocean_data: ^Ocean_Data,
    scene_data: ^astro.GPU_Scene_Data,
    plane_transform: la.Matrix4f32,
    sim_data: Ocean_Sim_Data,
    render_pipeline: astro.Shader_Pipeline,
    paused: bool, 
}
Ocean_Sim_Data :: struct {
    jonswap_pipeline: astro.Shader_Pipeline,

    spectrum_params: ^Spectrum_Parameters,  
    jonswap_texture: astro.Texture_Reference, 
    jonswap_image: astro.Allocated_Image,
    random_sampler: [256]f32,
}

Ocean_Data :: struct {
    time: f32,
    mesh_size_x: u32,
    mesh_size_y: u32,
    texture_size: u32,
    spectrum_index: u32,
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
    ocean.sim_data.jonswap_image = astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R16G16B16A16_SFLOAT, image_usages) or_return
    ocean.sim_data.jonswap_texture = astro.memory_manager_register_texture(ocean.sim_data.jonswap_image) or_return



    builder: astro.Compute_Pipeline_Builder
    astro.compute_pipeline_builder_init(&builder, &engine.memory_manager, engine.vk_device)
    astro.compute_pipeline_builder_set_shader(&builder, compute)
    astro.pipeline_builder_bind_uniform_ptr(&builder, &ocean.ocean_data , 1, 1)
    astro.pipeline_builder_bind_uniform_ptr(&builder, &ocean.sim_data.spectrum_params, 1, 2)
    astro.pipeline_builder_bind_image(&builder, ocean.sim_data.jonswap_texture, 1, 0)
    astro.pipeline_builder_bind_new_static_buffer(&builder, engine, &ocean.sim_data.random_sampler, set = 1, binding = 3,)

    ocean.sim_data.jonswap_pipeline = astro.compute_pipeline_builder_build(&builder, engine) or_return

    ocean.ocean_data.mesh_size_x = OCEAN_PLANE_SIZE
    ocean.ocean_data.mesh_size_y = OCEAN_PLANE_SIZE
    ocean.ocean_data.texture_size = DOMAIN_GRAPH_EXTENT.width
    ocean.ocean_data.spectrum_index = ocean.sim_data.jonswap_texture.heap_ref.index

    ocean.mesh_idx = i32(astro.generate_plane(engine, &scene.meshes, OCEAN_PLANE_SIZE, OCEAN_PLANE_SIZE, OCEAN_VERTEX_DENSITY) or_return)
    // The world is Z-up with +Y forward and the plane is generated in XY, so just center it in X in front of the camera.
    ocean.plane_transform = la.matrix4_translate_f32({-OCEAN_PLANE_SIZE / 2, 0, 0})

    ocean.sim_data.spectrum_params.layer_count = 32
    ocean.sim_data.spectrum_params.peak_freq = .2
    ocean.sim_data.spectrum_params.storm_maturity = 3.3
    ocean.sim_data.spectrum_params.scale = 1
    ocean.sim_data.spectrum_params.patch_size = 64 

    builder2: astro.Graphics_Pipeline_Builder
    astro.graphics_pipeline_builder_init(&builder2, &engine.memory_manager, engine.vk_device)
    astro.graphics_pipeline_builder_set_shaders(&builder2, astro.Render_Shaders{vertex = vertex, fragment = fragment})
    astro.pipeline_builder_bind_uniform_ptr(&builder2, &ocean.scene_data, 1, 0)
    astro.pipeline_builder_bind_uniform_ptr(&builder2, &ocean.render_ocean_data, 1, 1)
    astro.graphics_pipeline_builder_set_input_topology(&builder2, .TRIANGLE_LIST)
    astro.graphics_pipeline_builder_set_polygon_mode(&builder2, .FILL)
    astro.graphics_pipeline_builder_set_cull_mode(&builder2, vk.CullModeFlags_NONE, .CLOCKWISE)
    astro.graphics_pipeline_builder_set_multisampling_none(&builder2)
    astro.graphics_pipeline_builder_disable_blending(&builder2)
    astro.graphics_pipeline_builder_enable_depth_test(&builder2, true, .GREATER_OR_EQUAL)
    astro.graphics_pipeline_builder_set_color_attachment_format(&builder2, engine.draw_image.image_format)
    astro.graphics_pipeline_builder_set_depth_attachment_format(&builder2, engine.depth_image.image_format)
    ocean.render_pipeline = astro.graphics_pipeline_builder_build(&builder2, engine) or_return



    return true
}

game_update_keys :: proc(scene: ^astro.Scene, engine: ^astro.Engine, delta_time: f32) {
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_data := ocean.ocean_data
        speed :f32 = 1.0 * f32(delta_time)
        if astro.is_key_pressed(.LEFT_SHIFT) {
            speed = speed * 2
        }
        //Rotate Camera
        if astro.is_key_pressed(.Q) {
            astro.camera_add_rotation(&scene.camera, {0,speed, 0})
        }
        if astro.is_key_pressed(.E) {
            astro.camera_add_rotation(&scene.camera, {0,-speed, 0}) 
        }
        //Move Cardinally
        if astro.is_key_pressed(.W) {
            astro.camera_move_forward(&scene.camera, speed) 
        }
        if astro.is_key_pressed(.S) {
            astro.camera_move_backward(&scene.camera, speed) 
        }
        if astro.is_key_pressed(.A) {
            astro.camera_move_left(&scene.camera, speed) 
        }
        if astro.is_key_pressed(.D) {
            astro.camera_move_right(&scene.camera, speed) 
        }

        if astro.is_key_pressed(.SPACE) {
            astro.camera_move_up(&scene.camera, speed) 
        }
        if astro.is_key_pressed(.LEFT_CONTROL) ||
            astro.is_key_pressed(.C){
            astro.camera_move_down(&scene.camera, speed) 
        }
        //Reset
        if astro.is_key_hit(.R) {
            scene.camera.position = {0,0,0}
        }
        //Pause
        if astro.is_key_hit(.P) {
            ocean.paused = !ocean.paused
        }       
        //wireframe_mode
        if astro.is_key_hit(.V) {
            scene.wireframe_mode = !scene.wireframe_mode 
        }
        if astro.is_mouse_pressed(.RIGHT) {
            astro.camera_add_rotation(&scene.camera, {-GLOBALS.input.mouse_delta.y,  -GLOBALS.input.mouse_delta.x, 0} * speed) 
        }
}
@(export)
game_update :: proc(scene: ^astro.Scene, engine: ^astro.Engine, delta_time: f32) ->(ok: bool,) {

    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_data := ocean.ocean_data
    game_update_keys(scene, engine, delta_time) 
    if !ocean.paused {
        ocean_data.time += delta_time 
    }
    ocean.render_ocean_data^ = ocean_data^
    ocean.scene_data^ = engine.scene_data
    
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

    return true
}

@(export)
game_render :: proc(scene: ^astro.Scene, engine: ^astro.Engine, cmd: vk.CommandBuffer) -> (ok: bool) {
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    mesh := &scene.meshes[ocean.mesh_idx]

    astro.shader_pipeline_bind(&ocean.render_pipeline, cmd, engine)

    push_constants := astro.GPU_Draw_Push_Constants {
        world_matrix = ocean.plane_transform,
        vertex_buffer = mesh.mesh_buffers.vertex_buffer_address,
    }
    vk.CmdPushConstants(cmd, ocean.render_pipeline.pipeline_layout.vk_layout, {.VERTEX}, 0, size_of(astro.GPU_Draw_Push_Constants), &push_constants)
    vk.CmdBindIndexBuffer(cmd, mesh.mesh_buffers.index_buffer.buffer, 0, .UINT32)
    for surface in mesh.surfaces {
        vk.CmdDrawIndexed(cmd, surface.count, 1, surface.start_index, 0, 0)
    }
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
    return true
}

@(export)
game_reload :: proc(scene: ^astro.Scene, engine: ^astro.Engine, globals: ^astro.Engine_Globals) -> (ok: bool,){
    vk.load_proc_addresses_global(globals.vk_proc_address)
    vk.load_proc_addresses(globals.vk_instance)
    im.SetCurrentContext(globals.imgui_context)
    im.SetAllocatorFunctions(globals.imgui_alloc_func, globals.imgui_free_func, globals.imgui_user_data)
    astro.GLOBALS = globals
    GLOBALS = globals
    
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


