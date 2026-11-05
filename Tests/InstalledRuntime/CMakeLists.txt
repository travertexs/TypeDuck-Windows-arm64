cmake_minimum_required(VERSION 3.21)
cmake_policy(SET CMP0091 NEW)
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)
project(TypeDuckInstalledRuntimeProbes LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
add_compile_options(/utf-8)
add_compile_definitions(UNICODE _UNICODE _WIN32_WINNT=0x0602)
add_executable(TypeDuckLoadProbe
  ../TypeDuckLoadProbe.cpp
  ../TouchPacketProbe.cpp
  ../../libIME2/src/KeyEvent.cpp)
target_link_libraries(TypeDuckLoadProbe PRIVATE ole32 oleaut32 uuid advapi32)
