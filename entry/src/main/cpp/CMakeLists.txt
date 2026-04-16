cmake_minimum_required(VERSION 3.5.0)
project(vpnclientbridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_SKIP_RPATH TRUE)

add_library(vpnclientbridge SHARED vpnclient_bridge.cpp)
target_link_libraries(vpnclientbridge PUBLIC libace_napi.z.so libhilog_ndk.z.so)
