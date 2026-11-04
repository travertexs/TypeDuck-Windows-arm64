# Follow Microsoft's two-pass ARM64/ARM64EC link procedure. The combined DLL
# serves the shared 64-bit COM registration on Windows 11 on Arm.
set(TYPEDUCK_ARM64X_MODE "" CACHE STRING "ARM64 to capture inputs; ARM64EC to combine them")
set(TYPEDUCK_ARM64X_INPUTS "" CACHE FILEPATH "Absolute-path linker response from the ARM64 build")
if(TYPEDUCK_ARM64X_MODE STREQUAL "ARM64")
    if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64" OR NOT TYPEDUCK_ARM64X_INPUTS)
        message(FATAL_ERROR "ARM64X capture requires ARM64 and TYPEDUCK_ARM64X_INPUTS")
    endif()
    target_link_options(MoqiTextService PRIVATE "/LINKREPROFULLPATHRSP:${TYPEDUCK_ARM64X_INPUTS}")
elseif(TYPEDUCK_ARM64X_MODE STREQUAL "ARM64EC")
    if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64EC" OR NOT EXISTS "${TYPEDUCK_ARM64X_INPUTS}")
        message(FATAL_ERROR "Build ARM64 first and provide its linker response file")
    endif()
    file(STRINGS "${TYPEDUCK_ARM64X_INPUTS}" native_objects REGEX "\\.[Oo][Bb][Jj]\"$")
    file(STRINGS "${TYPEDUCK_ARM64X_INPUTS}" native_libraries REGEX "\\.[Ll][Ii][Bb]\"$")
    string(REPLACE "\"" "" native_objects "${native_objects}")
    string(REPLACE "\"" "" native_libraries "${native_libraries}")
    if(NOT native_objects OR NOT native_libraries)
        message(FATAL_ERROR "ARM64 linker response contains no objects or libraries")
    endif()
    target_sources(MoqiTextService PRIVATE ${native_objects})
    # Preserve this lowercase spelling: CMake otherwise moves it to TargetMachine,
    # before its default /machine:ARM64EC option, which silently overrides it.
    target_link_options(MoqiTextService PRIVATE /machine:arm64x
        "/DEFARM64NATIVE:${CMAKE_CURRENT_SOURCE_DIR}/MoqiTextService.def")
    target_link_libraries(MoqiTextService ${native_libraries})
elseif(TYPEDUCK_ARM64X_MODE)
    message(FATAL_ERROR "Invalid TYPEDUCK_ARM64X_MODE")
endif()
