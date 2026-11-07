cmake_minimum_required(VERSION 3.21)
project(TypeDuckKeyboardCompat LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
if(NOT MSVC OR NOT CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  message(FATAL_ERROR "This compatibility prototype is native Windows ARM64 only")
endif()
include(FetchContent)
FetchContent_Declare(detours
  GIT_REPOSITORY https://github.com/microsoft/Detours.git
  GIT_TAG 1dbd4ea281d73d478aa8d09a8b83fbd265f715f7)
FetchContent_MakeAvailable(detours)
add_library(detours_arm64 STATIC
  ${detours_SOURCE_DIR}/src/detours.cpp
  ${detours_SOURCE_DIR}/src/modules.cpp
  ${detours_SOURCE_DIR}/src/disasm.cpp
  ${detours_SOURCE_DIR}/src/image.cpp
  ${detours_SOURCE_DIR}/src/creatwth.cpp
  ${detours_SOURCE_DIR}/src/disolx86.cpp
  ${detours_SOURCE_DIR}/src/disolx64.cpp
  ${detours_SOURCE_DIR}/src/disolia64.cpp
  ${detours_SOURCE_DIR}/src/disolarm.cpp
  ${detours_SOURCE_DIR}/src/disolarm64.cpp)
target_include_directories(detours_arm64 PUBLIC ${detours_SOURCE_DIR}/src)
target_compile_definitions(detours_arm64 PRIVATE WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
add_library(TypeDuckKeyboardCompatHook SHARED Hook.cpp)
target_link_libraries(TypeDuckKeyboardCompatHook PRIVATE detours_arm64 bcrypt runtimeobject)
add_executable(TypeDuckKeyboardCompat Helper.cpp)
target_link_libraries(TypeDuckKeyboardCompat PRIVATE bcrypt advapi32)
add_executable(TypeDuckKeyboardCompatTests Tests.cpp)
target_link_libraries(TypeDuckKeyboardCompatTests PRIVATE detours_arm64 bcrypt runtimeobject)
foreach(target TypeDuckKeyboardCompatHook TypeDuckKeyboardCompat TypeDuckKeyboardCompatTests)
  target_compile_definitions(${target} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
  target_compile_options(${target} PRIVATE /W4 /utf-8 /guard:cf)
  target_link_options(${target} PRIVATE /guard:cf)
endforeach()
configure_file(${detours_SOURCE_DIR}/LICENSE.md ${CMAKE_BINARY_DIR}/Detours-LICENSE.md COPYONLY)
enable_testing()
add_test(NAME KeyboardCompatPolicyAndDetours COMMAND TypeDuckKeyboardCompatTests)
