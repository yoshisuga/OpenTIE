# Nintendo 3DS (devkitARM + libctru). TIE_3DS_PREFIX holds the dependencies
# built for it (SDL3); packaging/3ds/build.sh creates it.
if(NOT DEFINED ENV{DEVKITPRO})
    set(ENV{DEVKITPRO} /opt/devkitpro)
endif()
include("$ENV{DEVKITPRO}/cmake/3DS.cmake")
set(TIE_PLATFORM_3DS ON CACHE BOOL "Build the Nintendo 3DS port")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES TIE_3DS_PREFIX)
if(DEFINED TIE_3DS_PREFIX)
    list(APPEND CMAKE_FIND_ROOT_PATH "${TIE_3DS_PREFIX}")
    list(APPEND CMAKE_PREFIX_PATH "${TIE_3DS_PREFIX}")
endif()
