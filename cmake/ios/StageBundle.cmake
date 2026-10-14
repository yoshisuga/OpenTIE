if(NOT DEFINED TIE_BUNDLE_DIR OR NOT DEFINED TIE_SHADER_SOURCE_DIR OR NOT DEFINED TIE_RESOURCE_SOURCE_DIR)
    message(FATAL_ERROR "TIE iOS bundle staging paths are incomplete")
endif()

file(MAKE_DIRECTORY "${TIE_BUNDLE_DIR}/shaders")
file(GLOB shaders "${TIE_SHADER_SOURCE_DIR}/*.msl")
file(COPY ${shaders} DESTINATION "${TIE_BUNDLE_DIR}/shaders")
file(COPY "${TIE_RESOURCE_SOURCE_DIR}/" DESTINATION "${TIE_BUNDLE_DIR}/tie_resources")
file(COPY "${TIE_AERON_DEFAULTS}" DESTINATION "${TIE_BUNDLE_DIR}/tie_resources/aeron")

# Home screen icons, named as CFBundleIconFiles in Info.plist.
foreach(icon "AppIcon60x60@2x.png:120" "AppIcon60x60@3x.png:180"
             "AppIcon76x76@2x~ipad.png:152" "AppIcon83.5x83.5@2x~ipad.png:167")
    string(REPLACE ":" ";" icon "${icon}")
    list(GET icon 0 name)
    list(GET icon 1 size)
    if(NOT EXISTS "${TIE_BUNDLE_DIR}/${name}" OR "${TIE_ICON_SOURCE}" IS_NEWER_THAN "${TIE_BUNDLE_DIR}/${name}")
        execute_process(
            COMMAND sips -z ${size} ${size} "${TIE_ICON_SOURCE}" --out "${TIE_BUNDLE_DIR}/${name}"
            OUTPUT_QUIET RESULT_VARIABLE result)
        if(NOT result EQUAL 0)
            message(FATAL_ERROR "Could not make the ${name} icon")
        endif()
    endif()
endforeach()
