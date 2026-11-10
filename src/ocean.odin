package Ocean 

import "core:math"
import la "core:math/linalg"
import vk "vendor:vulkan"
import astro "../../src/"
import "core:log"

import im "libs:imgui"
// resolution must stay proportional to patch_size (deltaK = 2*pi/patch_size) or the energetic
// wavenumbers collapse into a tiny blob at the texture center

GLOBALS : ^astro.Engine_Globals

SPECTRUM_TEXTURE_SIZE :: 256 
DOMAIN_GRAPH_EXTENT :: vk.Extent3D{SPECTRUM_TEXTURE_SIZE, SPECTRUM_TEXTURE_SIZE, 1}

OCEAN_PLANE_SIZE :: 1024
OCEAN_PATCH_SIZE :: SPECTRUM_TEXTURE_SIZE 
OCEAN_VERTEX_DENSITY :: 1
OCEAN_SPECTRUMS :: 4
TEXTURES :: 4
Ocean :: struct {

    plane_size: u32,
    plane_size2: u32,

    ocean_material: astro.Material_Shader,
    ocean_material_data: astro.Material_Instance,
    mesh_idx: i32,
    node_idx: i32,
    ocean_data: ^Ocean_Data,
    scene_data: ^astro.GPU_Scene_Data,
    plane_transform: la.Matrix4f32,
    compute_data: Ocean_Compute,
    render_pipeline: astro.Shader_Pipeline,
    debug_render_pipeline: astro.Shader_Pipeline,
    spectrums: u32,
    spectrum_initialized: bool,
    paused: bool, 
}
Ocean_Compute :: struct {
    pipelines: map[string]astro.Shader_Pipeline,
    spectrum_params: ^Spectrum_Parameters,  
    textures: [TEXTURES]astro.Texture_Reference, 
    image_allocations: [TEXTURES]astro.Allocated_Image,
}


Ocean_Data :: struct {
    time: f32,
    tile_time: f32,
    patch_size: u32,
    ocean_depth: f32,
    mesh_size_x: u32,
    mesh_size_y: u32,
    texture_size: u32,
    mesh_gap_size: f32, 
    spectrum_texel_size: f32,
    displacement_index: u32,
    slope_index: u32,
    spectrums:u32,
}


Spectrum_Parameters :: struct {

    length_scale: [OCEAN_SPECTRUMS]i32,
    scale: [OCEAN_SPECTRUMS]f32,
    storm_maturity: [OCEAN_SPECTRUMS]f32,

    wind_speed: [OCEAN_SPECTRUMS]f32,
    wind_span: [OCEAN_SPECTRUMS]f32,
    wind_angle: [OCEAN_SPECTRUMS]f32,

    choppiness: [OCEAN_SPECTRUMS]f32, 

    wind_spread_control:[OCEAN_SPECTRUMS]f32,

    initialized: [OCEAN_SPECTRUMS]b32,
    swell:f32,
    toggle:b32,
    jacobian_modifier: f32,
}

@(export)
game_init :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok: bool,) {

    scene.scene_data_ptr = rawptr(new(Ocean))
    ocean := cast(^Ocean)scene.scene_data_ptr
    ocean.spectrums = OCEAN_SPECTRUMS

    fragment, has_fragment := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.frag")
    vertex, has_vertex := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/ocean.vert")
    compute, has_compute := astro.shader_manager_get_shader(&engine.shader_manager, "game/ocean/generate_jonswap.comp")


    if !has_fragment || !has_vertex || !has_compute{
        return false
    }

    image_usages := vk.ImageUsageFlags {
        .SAMPLED,
        .TRANSFER_SRC,
        .TRANSFER_DST,
        .STORAGE,
        .COLOR_ATTACHMENT
    }
    //Initial Spectrum Texture
    ocean.compute_data.image_allocations[0] = astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R16G16B16A16_SFLOAT, image_usages, layers = OCEAN_SPECTRUMS) or_return
    //Spectrum Texture
    ocean.compute_data.image_allocations[1] = astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R32G32B32A32_SFLOAT, image_usages, layers = OCEAN_SPECTRUMS * 2) or_return
    //Displacement Texture
    ocean.compute_data.image_allocations[2] = astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R32G32B32A32_SFLOAT, image_usages, layers = OCEAN_SPECTRUMS) or_return
    ocean.compute_data.image_allocations[3] = astro.create_image_default(engine, DOMAIN_GRAPH_EXTENT, .R32G32_SFLOAT, image_usages, layers = OCEAN_SPECTRUMS) or_return




    ocean.compute_data.textures[0] = astro.memory_manager_register_texture(ocean.compute_data.image_allocations[0]) or_return
    ocean.compute_data.textures[1] = astro.memory_manager_register_texture(ocean.compute_data.image_allocations[1]) or_return
    ocean.compute_data.textures[2] = astro.memory_manager_register_texture(ocean.compute_data.image_allocations[2]) or_return
    ocean.compute_data.textures[3] = astro.memory_manager_register_texture(ocean.compute_data.image_allocations[3]) or_return


    builder: astro.Compute_Pipeline_Builder
    astro.compute_pipeline_builder_init(&builder, &engine.memory_manager, engine.vk_device)
    astro.compute_pipeline_builder_set_shader(&builder, compute)
    astro.pipeline_builder_bind_image(&builder, ocean.compute_data.textures[0], "initial_spectrum")
    astro.pipeline_builder_bind_image(&builder, ocean.compute_data.textures[1], "spectrum")
    astro.pipeline_builder_bind_image(&builder, ocean.compute_data.textures[2], "displacement")
    astro.pipeline_builder_bind_image(&builder, ocean.compute_data.textures[3], "slope")
    ocean_data := astro.pipeline_builder_bind_uniform_ptr(&builder, &ocean.ocean_data, "ocean_data")
    spectrum_params := astro.pipeline_builder_bind_uniform_ptr(&builder, &ocean.compute_data.spectrum_params, "params")

    ocean.compute_data.pipelines = astro.compute_pipeline_builder_build_all(&builder, engine) or_return

    builder2: astro.Graphics_Pipeline_Builder
    astro.graphics_pipeline_builder_init(&builder2, &engine.memory_manager, engine.vk_device)
    astro.graphics_pipeline_builder_set_shaders(&builder2, astro.Render_Shaders{vertex = vertex, fragment = fragment})
    astro.pipeline_builder_bind_uniform_ptr(&builder2, &ocean.scene_data, "scene_data")
    astro.pipeline_builder_bind_existing_uniform_ptr(&builder2, &ocean.ocean_data, ocean_data, "ocean_data")
    astro.pipeline_builder_bind_existing_uniform_ptr(&builder2, &ocean.compute_data.spectrum_params, spectrum_params, "params")
    astro.graphics_pipeline_builder_set_input_topology(&builder2, .TRIANGLE_LIST)
    astro.graphics_pipeline_builder_set_polygon_mode(&builder2, .FILL)
    astro.graphics_pipeline_builder_set_cull_mode(&builder2, vk.CullModeFlags_NONE, .CLOCKWISE)
    astro.graphics_pipeline_builder_set_multisampling_none(&builder2)
    astro.graphics_pipeline_builder_disable_blending(&builder2)
    astro.graphics_pipeline_builder_enable_depth_test(&builder2, true, .GREATER_OR_EQUAL)
    astro.graphics_pipeline_builder_set_color_attachment_format(&builder2, engine.draw_image.image_format)
    astro.graphics_pipeline_builder_set_depth_attachment_format(&builder2, engine.depth_image.image_format)
    ocean.render_pipeline = astro.graphics_pipeline_builder_build(&builder2, engine) or_return

    ocean.mesh_idx = i32(astro.generate_plane(engine, &scene.meshes, OCEAN_PLANE_SIZE, OCEAN_PLANE_SIZE, OCEAN_VERTEX_DENSITY, OCEAN_PATCH_SIZE, OCEAN_PATCH_SIZE) or_return)
    // The world is Z-up with +Y forward and the plane is generated in XY, so just center it in X in front of the camera.
    ocean.plane_transform = la.matrix4_translate_f32({-OCEAN_PLANE_SIZE / 2, -OCEAN_PLANE_SIZE / 2, 0})

    ocean.ocean_data.spectrums = ocean.spectrums 
    ocean.ocean_data.tile_time = 256.0 
    ocean.ocean_data.ocean_depth = 10.0 
    ocean.ocean_data.patch_size = OCEAN_PATCH_SIZE 
    ocean.ocean_data.mesh_size_x = OCEAN_PLANE_SIZE
    ocean.ocean_data.mesh_size_y = OCEAN_PLANE_SIZE
    ocean.ocean_data.texture_size = DOMAIN_GRAPH_EXTENT.width

    ocean.ocean_data.displacement_index = ocean.compute_data.textures[2].heap_ref.index
    ocean.ocean_data.slope_index = ocean.compute_data.textures[3].heap_ref.index

    ocean.ocean_data.mesh_gap_size = (1.0 / f32(OCEAN_VERTEX_DENSITY))
    ocean.ocean_data.spectrum_texel_size = (f32(OCEAN_PLANE_SIZE) / f32(SPECTRUM_TEXTURE_SIZE))
    scale: i32 = 32 
    for i in 0..<OCEAN_SPECTRUMS {
        ocean.compute_data.spectrum_params.length_scale[i] = scale << (u32(i * 2))
    }
    ocean.compute_data.spectrum_params.initialized = false 
    ocean.compute_data.spectrum_params.scale = 1.0 
    ocean.compute_data.spectrum_params.storm_maturity = 3.3
    ocean.compute_data.spectrum_params.choppiness = 0.5

    ocean.compute_data.spectrum_params.wind_spread_control = 0.5
    ocean.compute_data.spectrum_params.wind_speed = 10
    ocean.compute_data.spectrum_params.wind_span = 100
    ocean.compute_data.spectrum_params.wind_angle = 180

    ocean.compute_data.spectrum_params.jacobian_modifier = 1.0 



    return true
}

game_update_keys :: proc(scene: ^astro.Scene, engine: ^astro.Engine, delta_time: f32) {
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_data := ocean.ocean_data
        speed :f32 = 3.0 * f32(delta_time)
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
    ocean.scene_data^ = engine.scene_data
    
    return true
}

@(export)
game_draw :: proc(scene: ^astro.Scene, engine: ^astro.Engine, cmd: vk.CommandBuffer) -> (ok: bool,){
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_sim := &ocean.compute_data

    if(!ocean.spectrum_initialized || any_spectrums_outdated(ocean)){

        if(!ocean.spectrum_initialized) {
            astro.transition_image(cmd, ocean_sim.textures[0].image.image, .UNDEFINED, .GENERAL) 
            astro.transition_image(cmd, ocean_sim.textures[1].image.image, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL)
            astro.transition_image(cmd, ocean_sim.textures[2].image.image, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL)
        }


        astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_initial_spectrum"], cmd, engine)
        vk.CmdDispatch(
            cmd,
            u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
            u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
            1,
        )
        astro.image_barrier(cmd, .SHADER_READ, .COMPUTE_SHADER, ocean_sim.textures[0].image)

        //Pack the rest of the initial spectrum
        astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_packed_spectrum"], cmd, engine)
        vk.CmdDispatch(
            cmd,
            u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
            u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
            1,
        )
        astro.image_barrier(cmd, .SHADER_READ, .COMPUTE_SHADER, ocean_sim.textures[0].image)

        // These images have not been used before this frame.


        ocean.spectrum_initialized = true
        for i in 0..<OCEAN_SPECTRUMS {
            ocean.compute_data.spectrum_params.initialized[i] = true
        }
    }
    
    //PRE-FFT Update
    astro.transition_image(cmd, ocean_sim.textures[1].image.image, .SHADER_READ_ONLY_OPTIMAL, .GENERAL)

    astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_update_spectrum"], cmd, engine)
    vk.CmdDispatch(
        cmd,
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
        1,
    )

    astro.image_barrier(cmd, .SHADER_READ, .COMPUTE_SHADER, ocean_sim.textures[1].image)

    //FFT
    astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_horizontal_fft"], cmd, engine)
    vk.CmdDispatch(
        cmd,
        1, SPECTRUM_TEXTURE_SIZE, 1,
    )
    astro.image_barrier(cmd, .SHADER_READ, .COMPUTE_SHADER, ocean_sim.textures[1].image)
    //FFT
    astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_vertical_fft"], cmd, engine)
    vk.CmdDispatch(
        cmd,
        1, SPECTRUM_TEXTURE_SIZE, 1,
    )

    astro.image_barrier(cmd, .SHADER_READ, .COMPUTE_SHADER, ocean_sim.textures[1].image)

    astro.transition_image(cmd, ocean_sim.textures[2].image.image, .SHADER_READ_ONLY_OPTIMAL, .GENERAL)
    astro.shader_pipeline_bind(&ocean_sim.pipelines["COMPUTE_finalize"], cmd, engine)
    vk.CmdDispatch(
        cmd,
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.width) / 16.0)),
        u32(math.ceil_f32(f32(DOMAIN_GRAPH_EXTENT.height) / 16.0)),
        1,
    )

    astro.transition_image(cmd, ocean_sim.textures[1].image.image, .GENERAL, .SHADER_READ_ONLY_OPTIMAL)
    astro.transition_image(cmd, ocean_sim.textures[2].image.image, .GENERAL, .SHADER_READ_ONLY_OPTIMAL)
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

any_spectrums_outdated :: proc(ocean:^Ocean) -> bool {
    params:= ocean.compute_data.spectrum_params
    for i in 0..< OCEAN_SPECTRUMS {
        if !params.initialized[i] {
            return true
        }
    }
    return false
}
single_mode : b32
@(export)
game_draw_ui :: proc(scene: ^astro.Scene, engine: ^astro.Engine) ->(ok:bool) { 
    ocean: ^Ocean = cast(^Ocean)scene.scene_data_ptr
    ocean_sim := &ocean.compute_data
    ocean_data := &ocean.ocean_data
    if im.Begin("Ocean", nil, {.AlwaysAutoResize}) {
        params := ocean_sim.spectrum_params
        im.Text("Global Ocean Values")

        
        if im.Checkbox("Single Spectrum Mode", cast(^bool)&single_mode) {
            scale : f32 = (single_mode ? 0.0 : 1.0)
           for i in 1..<OCEAN_SPECTRUMS {
                params.scale[i] = scale
                
           } 
           params.initialized[0] = false
        }

        if im.Checkbox("Toggle", cast(^bool)&params.toggle) {
            params.initialized = false;
        }      
        if im.SliderFloat("Jacobian Modifier", &params.jacobian_modifier, 0.01, 10) {
            params.initialized = false
        }
        spectrums:= (single_mode ? 1 : OCEAN_SPECTRUMS)
        for i in 0..< spectrums {
            im.PushIDInt(i32(i))
            im.Text("Spectrum: %i", i) 

            if im.SliderInt("Length Scale", &params.length_scale[i], 2, 4096) {
                params.initialized[i] = false
            }
            if im.SliderFloat("Scale", &params.scale[i], 0.0, 100) {
                params.initialized[i] = false
            } 
            im.Separator();
            if im.SliderFloat("Wind Angle", &params.wind_angle[i], 0.0, 360.0) {
                params.initialized[i] = false
            }
            if im.SliderFloat("Wind Speed", &params.wind_speed[i], 0.0, 30.0) {
                params.initialized[i] = false
            }
            if im.SliderFloat("Wind Span", &params.wind_span[i], 10.0, 120.0) {
                params.initialized[i] = false
            } 
            if im.SliderFloat("Wind Spread Control", &params.wind_spread_control[i], 0.0, 1.0) {
                params.initialized[i] = false
            }
            im.Separator();
            if im.SliderFloat("Choppiness", &params.choppiness[i], 0.05, 10.0) {
                params.initialized[i] = false
            }
            if im.SliderFloat("Storm Maturity", &params.storm_maturity[i], 1.0, 10.0) {
                params.initialized[i] = false
            }
    

            im.Separator();
            im.Separator();
            im.PopID()
        }
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
    astro.compute_pipelines_destroy(ocean.compute_data.pipelines)

    free(scene.scene_data_ptr)
    return true
}
