// KhuaPlayer — CPU mirrors of Metal constant-buffer layouts.
//
// Keep every field assertion in this header in sync with Video.metal. The
// explicit offsets make an accidental type or field-order change fail at
// compile time instead of corrupting GPU input.
#pragma once

#ifndef __cplusplus
#error "SPShaderUniforms.h requires C++ or Objective-C++"
#endif

#include <simd/simd.h>

#include <cstddef>
#include <cstdint>
#include <type_traits>
#include "SPDoviUniformLayout.hpp"

struct SPColorUniforms {
    float uvals[32];
};

static_assert(std::is_standard_layout_v<SPColorUniforms>);
static_assert(alignof(SPColorUniforms) == alignof(float));
static_assert(offsetof(SPColorUniforms, uvals) == 0);
static_assert(sizeof(SPColorUniforms::uvals) == 32 * sizeof(float));
static_assert(sizeof(SPColorUniforms) == 128,
              "Video.metal Uniforms layout mismatch");

// Keep the ABI bound explicit for the independent CPU/Metal layout checker.
inline constexpr std::size_t kSPDoviUniformFloatCount = 992;
static_assert(kSPDoviUniformFloatCount == sp::dovi_gpu::FloatCount,
              "DV serialization and constant-buffer bounds differ");

struct SPDoviUniforms {
    float values[kSPDoviUniformFloatCount];
};

static_assert(std::is_standard_layout_v<SPDoviUniforms>);
static_assert(alignof(SPDoviUniforms) == alignof(float));
static_assert(offsetof(SPDoviUniforms, values) == 0);
static_assert(sizeof(SPDoviUniforms::values) == 992 * sizeof(float));
static_assert(sizeof(SPDoviUniforms) == 3968,
              "Video.metal DoviUniforms layout mismatch");

inline constexpr std::size_t kSPDragFxUniformFloatCount = 16;

struct SPDragFxUniforms {
    float values[kSPDragFxUniformFloatCount];
};

static_assert(std::is_standard_layout_v<SPDragFxUniforms>);
static_assert(alignof(SPDragFxUniforms) == alignof(float));
static_assert(offsetof(SPDragFxUniforms, values) == 0);
static_assert(sizeof(SPDragFxUniforms) == 64,
              "Video.metal DragFxUniforms layout mismatch");
