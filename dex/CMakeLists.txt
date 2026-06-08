cmake_minimum_required(VERSION 3.10.2 FATAL_ERROR)
project(DEX)

# set (CMAKE_C_COMPILER "/usr/local/openmpi/bin/mpicxx")
# set (CMAKE_CXX_COMPILER ${CMAKE_C_COMPILER})

add_definitions(-UNDEBUG)

# By default DEX uses its adaptive cache-vs-pushdown policy (LATENCY_COLLECT),
# which OVERRIDES the manual rpc_rate knob. For a controlled offloading study
# (rpc_rate=0 => no pushdown, rpc_rate=1 => pushdown), configure with
#   cmake -DMANUAL_PUSHDOWN=ON ..
# which disables the adaptive policy so rpc_rate takes effect.
option(MANUAL_PUSHDOWN "Disable adaptive pushdown so rpc_rate controls offloading" OFF)
if(MANUAL_PUSHDOWN)
  add_definitions(-DMANUAL_PUSHDOWN)
  message(STATUS "MANUAL_PUSHDOWN enabled: rpc_rate controls offloading (adaptive policy off)")
endif()

if(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -mssse3 -march=native")
elseif(${CMAKE_BUILD_TYPE} STREQUAL "RelWithDebInfo")
  set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -g -O2 -mssse3 -march=native")
else()
  set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3")
  set(CMAKE_C_FLAGS "-Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-but-set-variable -Wsign-compare -mssse3 -march=native -O3")
endif()

#Compiler options
# set(CMAKE_C_FLAGS "-Wall -Wno-deprecated-declarations -Wsign-compare -DNDEBUG -g")
set(CMAKE_CXX_FLAGS "${CMAKE_C_FLAGS} -std=c++17")

# Link Options
# NOTE: Boost.System is header-only since Boost 1.69, and recent distros (with
# new GCC/Boost) no longer ship a separate libboost_system.so -> '-lboost_system'
# fails with "cannot find -lboost_system". Its symbols are header-only, so it is
# simply dropped here. (If your older toolchain still needs it, add it back.)
set(LINKS_FLAGS "-lcityhash -lboost_coroutine -lpthread -libverbs -lmemcached -ltbb -lnuma")

# option (SANITIZE "Turn on sanitization" ON)
# if (SANITIZE)
    # set (CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address")
# endif()

set(INCLUDE_BASE ${PROJECT_SOURCE_DIR}/include)
include_directories(${INCLUDE_BASE})

#Source file define
set(COMMON_SRC ${PROJECT_SOURCE_DIR}/src)

#Used by both server and clients
file(GLOB_RECURSE COMMON_FILE ${COMMON_SRC}/*.cpp)
message(COMMON_FILE="${COMMON_FILE}")
add_library(DEX STATIC ${COMMON_FILE})
link_libraries(DEX)

# test

file(GLOB TEST_SRC ${PROJECT_SOURCE_DIR}/test/*.cpp)
foreach (TEST ${TEST_SRC})
    get_filename_component(TEST_NAME ${TEST} NAME_WE)
    add_executable(${TEST_NAME} ${TEST})
    target_link_libraries(${TEST_NAME} ${LINKS_FLAGS})
endforeach()

