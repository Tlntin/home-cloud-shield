cmake_minimum_required(VERSION 3.5.0)
project(vpnclientbridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_SKIP_RPATH TRUE)

# Prebuilt AdGuardHome c-shared library (full-mode filter engine).  The cgo
# header lives in include/, the .so in libs/<abi>/ (packaged into the HAP
# alongside this module, so the dynamic loader finds it at runtime).
if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH "arm64-v8a")
endif()
set(AGH_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../libs/${OHOS_ARCH}/libadguardhome_ohos.so")

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

add_library(adguardhome_ohos SHARED IMPORTED)
set_target_properties(adguardhome_ohos PROPERTIES IMPORTED_LOCATION "${AGH_LIB}")

add_library(vpnclientbridge SHARED vpnclient_bridge.cpp)
target_link_libraries(vpnclientbridge PUBLIC libace_napi.z.so libhilog_ndk.z.so adguardhome_ohos)
