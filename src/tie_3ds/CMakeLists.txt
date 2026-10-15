# Nintendo 3DS port: the TIE95 software-rendered game on libctru.
#
# Aeron is not added as a subdirectory: its build requires SDL_shadercross,
# SDL_GPU shaders and FSR. This builds the platform-neutral part of Aeron
# (VFS, config, log, input, audio, the Win32 compatibility layer and the
# classic asset decoders) and replaces the GPU, window and DirectDraw seam
# with aeron_seam_3ds.c.
find_package(SDL3 3.4 REQUIRED CONFIG COMPONENTS SDL3-static)

set(AERON_DIR ${CMAKE_SOURCE_DIR}/aeron)

add_library(tie_3ds_aeron STATIC
    ${AERON_DIR}/third_party/libyaml/src/api.c
    ${AERON_DIR}/third_party/libyaml/src/dumper.c
    ${AERON_DIR}/third_party/libyaml/src/emitter.c
    ${AERON_DIR}/third_party/libyaml/src/loader.c
    ${AERON_DIR}/third_party/libyaml/src/parser.c
    ${AERON_DIR}/third_party/libyaml/src/reader.c
    ${AERON_DIR}/third_party/libyaml/src/scanner.c
    ${AERON_DIR}/third_party/libyaml/src/writer.c
    ${AERON_DIR}/src/aeron.c
    ${AERON_DIR}/src/audio.c
    ${AERON_DIR}/src/config_file.c
    ${AERON_DIR}/src/gamepad.c
    ${AERON_DIR}/src/input.c
    ${AERON_DIR}/src/log.c
    ${AERON_DIR}/src/mesh_normals.c
    ${AERON_DIR}/src/numeric.c
    ${AERON_DIR}/src/paths.c
    ${AERON_DIR}/src/sync.c
    ${AERON_DIR}/src/time.c
    ${AERON_DIR}/src/vfs.c
    ${AERON_DIR}/src/vfs_iso9660.c
    ${AERON_DIR}/src/scene/settings.c
    ${AERON_DIR}/src/compat/config.c
    ${AERON_DIR}/src/compat/dinput.c
    ${AERON_DIR}/src/compat/dsound.c
    ${AERON_DIR}/src/compat/guids.c
    ${AERON_DIR}/src/compat/winmm_joystick.c
    ${AERON_DIR}/src/asset/abp_font.c
    ${AERON_DIR}/src/asset/act.c
    ${AERON_DIR}/src/asset/bitmap_font.c
    ${AERON_DIR}/src/asset/bmp.c
    ${AERON_DIR}/src/asset/decode_types.c
    ${AERON_DIR}/src/asset/image_coverage.c
    ${AERON_DIR}/src/asset/lfd.c
    ${AERON_DIR}/src/asset/pnl.c
    ${AERON_DIR}/tools/opt2gltf/opt.c
    ${AERON_DIR}/tools/opt2gltf/opt_upgrade.c
    aeron_seam_3ds.c)
target_include_directories(tie_3ds_aeron
    PUBLIC
        ${AERON_DIR}/include
        ${AERON_DIR}/tools/opt2gltf
        ${AERON_DIR}/third_party/libyaml/include
    PRIVATE
        ${CMAKE_SOURCE_DIR}/src
        ${AERON_DIR}/src
        ${AERON_DIR}/third_party/libyaml/src)
target_compile_definitions(tie_3ds_aeron
    PUBLIC
        YAML_DECLARE_STATIC
    PRIVATE
        YAML_VERSION_MAJOR=0
        YAML_VERSION_MINOR=2
        YAML_VERSION_PATCH=5
        YAML_VERSION_STRING="0.2.5")
target_link_libraries(tie_3ds_aeron PUBLIC SDL3::SDL3-static citro2d citro3d tie_libm)
target_compile_options(tie_3ds_aeron PRIVATE -fno-strict-aliasing)

# tie_formats and tie_core name the desktop Aeron targets.
add_library(aeron_asset INTERFACE)
target_link_libraries(aeron_asset INTERFACE tie_3ds_aeron)
target_link_libraries(tie_core PRIVATE tie_3ds_aeron)

add_executable(tie_3ds
    main_3ds.c
    ${CMAKE_SOURCE_DIR}/src/tie_app/config/app_config.c
    ${CMAKE_SOURCE_DIR}/src/tie_app/config/controller_config.c
    ${CMAKE_SOURCE_DIR}/src/tie_app/config/keyboard_config.c
    ${CMAKE_SOURCE_DIR}/src/tie_app/setup/installation.c)
set_target_properties(tie_3ds PROPERTIES OUTPUT_NAME "OpenTIE")
target_include_directories(tie_3ds PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_definitions(tie_3ds PRIVATE TIE_VERSION_STRING="${TIE_DISPLAY_VERSION}")
target_link_libraries(tie_3ds PRIVATE tie_core tie_3ds_aeron)
tie_enable_warnings(tie_3ds)

# Application resources ship in romfs, which SDL reports as the base path.
# Staged copies get fresh timestamps and are tracked, so the .3dsx is repacked
# when they change even if the executable does not.
set(TIE_3DS_ROMFS_DIR "${CMAKE_CURRENT_BINARY_DIR}/romfs")
file(REMOVE_RECURSE "${TIE_3DS_ROMFS_DIR}")
file(GLOB_RECURSE TIE_3DS_RESOURCE_FILES RELATIVE "${CMAKE_SOURCE_DIR}/resources" CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/resources/*")
set(TIE_3DS_ROMFS_FILES "")
foreach(file IN LISTS TIE_3DS_RESOURCE_FILES)
    get_filename_component(directory "${TIE_3DS_ROMFS_DIR}/resources/${file}" DIRECTORY)
    file(MAKE_DIRECTORY "${directory}")
    file(COPY_FILE "${CMAKE_SOURCE_DIR}/resources/${file}" "${TIE_3DS_ROMFS_DIR}/resources/${file}")
    list(APPEND TIE_3DS_ROMFS_FILES "resources/${file}")
endforeach()
file(MAKE_DIRECTORY "${TIE_3DS_ROMFS_DIR}/resources/aeron")
file(COPY_FILE "${AERON_DIR}/config/scene3d_defaults.yaml"
    "${TIE_3DS_ROMFS_DIR}/resources/aeron/scene3d_defaults.yaml")
list(APPEND TIE_3DS_ROMFS_FILES "resources/aeron/scene3d_defaults.yaml")
dkp_add_asset_target(tie_3ds_romfs "${TIE_3DS_ROMFS_DIR}")
dkp_track_assets(tie_3ds_romfs FILES ${TIE_3DS_ROMFS_FILES})

ctr_generate_smdh(OpenTIE.smdh
    NAME "OpenTIE"
    DESCRIPTION "Star Wars: TIE Fighter reimplementation"
    AUTHOR "TotallyOpen")
ctr_create_3dsx(tie_3ds SMDH OpenTIE.smdh ROMFS tie_3ds_romfs)
