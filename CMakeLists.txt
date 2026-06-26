cmake_minimum_required(VERSION 3.8)

project (EKA2L1)

# Clang 14 is required to compile nicely with C++ 20
set (CMAKE_CXX_STANDARD 20)

option(EKA2L1_BUILD_TOOLS "Build EKA2L1's tool" ON)
option(EKA2L1_BUILD_TESTS "Build EKA2L1's tests" ON)
option(EKA2L1_ENABLE_SCRIPTING_ABILITY "Enable to script with Python or Lua" ON)
option(EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER "Enable EKA2L1 to dump unexpected exception" OFF)
option(EKA2L1_BUILD_VULKAN_BACKEND "Build Vulkan backend" OFF)
option(EKA2L1_DEPLOY_DMG "Deploy EKA2L1 as .dmg" OFF)
option(EKA2L1_BUILD_PATCH "Enable building Symbian's DLL patches using Symbian SDK" OFF)
option(EKA2L1_ENABLE_DISCORD_RICH_PRESENCE "Enable support for Discord Rich Presence" OFF)

set (CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
set (ROOT ${CMAKE_CURRENT_SOURCE_DIR})

# Normalize iOS detection (CMake itself only sets APPLE + CMAKE_SYSTEM_NAME).
if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set (EKA2L1_IOS TRUE)
    message("Configuring EKA2L1 for iOS")

    # The iOS frontend is a self-contained app; desktop-only pieces and the
    # LuaJIT/Python scripting engine are not built (JIT codegen libs + Qt UI
    # do not apply on iOS).
    set (EKA2L1_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set (EKA2L1_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set (EKA2L1_ENABLE_SCRIPTING_ABILITY OFF CACHE BOOL "" FORCE)
    set (EKA2L1_BUILD_VULKAN_BACKEND OFF CACHE BOOL "" FORCE)

    # The very new libc++ shipped with Xcode 26 removed the C++98 std::unary_function /
    # std::binary_function helpers that the bundled ext-boost (used by dynarmic) still
    # relies on. Re-enable them and steer boost onto its non-deprecated code path.
    add_compile_definitions(
        _LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION
        _HAS_AUTO_PTR_ETC=0)
endif()

find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")

    message("Using CCache for building")
endif()

if (MSVC)
    add_definitions(-D_CRT_SECURE_NO_DEPRECATE)
    add_definitions(-D_CRT_NONSTDC_NO_DEPRECATE)
    add_definitions(-D_DISABLE_VECTOR_ANNOTATION)
endif(MSVC)

if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    add_compile_options(-Wno-error)
endif()

if (EKA2L1_BUILD_VULKAN_BACKEND)
    set (BUILD_WITH_VULKAN 1)
else()
    set (BUILD_WITH_VULKAN 0)
endif()

if (EKA2L1_ENABLE_SCRIPTING_ABILITY)
    set (ENABLE_SCRIPTING 1)
endif(EKA2L1_ENABLE_SCRIPTING_ABILITY)

if (CI)
    set (BUILD_FOR_USER 1)
endif (CI)

set (ENABLE_SEH_HANDLER 0)

if (EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER)
    set(ENABLE_SEH_HANDLER 1)
endif (EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER)

if (EKA2L1_ENABLE_DISCORD_RICH_PRESENCE AND NOT ANDROID AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "GNU"))
    set(ENABLE_DISCORD_RICH_PRESENCE 1)
else()
    set(ENABLE_DISCORD_RICH_PRESENCE 0)
endif()

add_subdirectory(src/patch)
add_subdirectory(src/external)
add_subdirectory(src/emu)

if (EKA2L1_BUILD_TOOLS)
    add_subdirectory(src/tools)
endif()

if (EKA2L1_BUILD_TESTS)
    enable_testing()
    add_subdirectory(src/tests)
endif()
