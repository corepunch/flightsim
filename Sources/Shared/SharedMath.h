#pragma once
#include <simd/simd.h>
#include <math.h>
#include <stdbool.h>

static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Orientation whose -Z points along forward.
static inline simd_quatf LookRotation(simd_float3 forward, simd_float3 up) {
    simd_float3 f = simd_normalize(forward);
    if (fabsf(simd_dot(f, up)) > 0.98f) up = simd_make_float3(1, 0, 0);
    simd_float3 r = simd_normalize(simd_cross(f, up));
    simd_float3 u = simd_cross(r, f);
    return simd_quaternion(simd_matrix(r, u, -f));
}

static inline simd_float3 QuatForward(simd_quatf q) { return simd_act(q, simd_make_float3(0, 0, -1)); }
static inline simd_float3 QuatUp(simd_quatf q) { return simd_act(q, simd_make_float3(0, 1, 0)); }
static inline simd_float3 QuatRight(simd_quatf q) { return simd_act(q, simd_make_float3(1, 0, 0)); }

// Segment vs sphere: does p0->p1 pass within r of c?
static inline bool SegmentHits(simd_float3 p0, simd_float3 p1, simd_float3 c, float r) {
    simd_float3 d = p1 - p0;
    float len2 = simd_length_squared(d);
    float t = len2 > 0 ? clampf(simd_dot(c - p0, d) / len2, 0, 1) : 0;
    return simd_distance_squared(p0 + d * t, c) < r * r;
}
