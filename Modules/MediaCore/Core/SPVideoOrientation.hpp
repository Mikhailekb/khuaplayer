// KhuaPlayer - container picture orientation (display matrix) as one of the
// eight axis-aligned rotate/mirror transforms. Pure C++, no FFmpeg dependency.
//
// Convention, shared with the videoVertex geometry in Shaders/Video.metal:
// coordinates are y-up and a transform maps source picture points to display
// points as  display = (hflip ? diag(-1, 1) : I) * R(90 deg * turnsCCW) * source,
// i.e. rotate counterclockwise first, then mirror the screen x axis. Uniform
// 18 (rotation) and 19 (mirror == 1) take turnsCCW and hflip directly.
//
// The container orientation is applied before the user's manual rotation and
// mirror: the user transforms the upright picture. Aspect overrides and crop
// ratios are therefore expressed in upright (container-oriented) space.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace sp {

struct VideoOrientation {
    uint8_t turnsCCW = 0; // 0..3 quarter turns counterclockwise
    bool hflip = false;   // mirror the screen x axis after rotating

    bool isIdentity() const { return turnsCCW == 0 && !hflip; }
    // Width and height trade places on screen.
    bool swapsAxes() const { return (turnsCCW & 1) != 0; }
    bool operator==(const VideoOrientation &o) const {
        return turnsCCW == o.turnsCCW && hflip == o.hflip;
    }
    bool operator!=(const VideoOrientation &o) const { return !(*this == o); }
};

// Row-major y-up 2x2 integer matrix {m00, m01, m10, m11} of a transform.
inline void videoOrientationMatrix(VideoOrientation o, int m[4]) {
    static const int kRot[4][4] = {
        {1, 0, 0, 1}, {0, -1, 1, 0}, {-1, 0, 0, -1}, {0, 1, -1, 0}};
    const int *r = kRot[o.turnsCCW & 3];
    const int f = o.hflip ? -1 : 1;
    m[0] = f * r[0]; m[1] = f * r[1];
    m[2] = r[2];     m[3] = r[3];
}

// Inverse of videoOrientationMatrix for any signed permutation matrix.
// Returns false (and identity) for anything else.
inline bool videoOrientationFromMatrix(const int m[4], VideoOrientation *out) {
    *out = VideoOrientation{};
    const int det = m[0] * m[3] - m[1] * m[2];
    if (det != 1 && det != -1) return false;
    for (int i = 0; i < 4; i++) {
        if (m[i] < -1 || m[i] > 1) return false;
    }
    // Undo the mirror (rows are display axes) to recover a pure rotation,
    // whose first column (cos, sin) names the quarter turn.
    const bool hflip = det < 0;
    const int c0 = hflip ? -m[0] : m[0];
    const int s0 = m[2];
    uint8_t turns;
    if (c0 == 1 && s0 == 0) turns = 0;
    else if (c0 == 0 && s0 == 1) turns = 1;
    else if (c0 == -1 && s0 == 0) turns = 2;
    else if (c0 == 0 && s0 == -1) turns = 3;
    else return false;
    *out = VideoOrientation{turns, hflip};
    return true;
}

// outer applied after inner: compose(outer, inner) == outer * inner.
inline VideoOrientation composeVideoOrientation(VideoOrientation outer,
                                                VideoOrientation inner) {
    int a[4], b[4];
    videoOrientationMatrix(outer, a);
    videoOrientationMatrix(inner, b);
    const int m[4] = {a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
                      a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]};
    VideoOrientation r;
    videoOrientationFromMatrix(m, &r);
    return r;
}

// The renderer's manual controls: rotation as quarter turns (menu degrees / 90,
// counterclockwise like uniform 18) and mirror 0 = none, 1 = horizontal,
// 2 = vertical. A vertical mirror is a horizontal
// mirror after a half turn.
inline VideoOrientation videoOrientationFromUserControls(int quarterTurnsCCW, int mirror) {
    VideoOrientation o;
    o.turnsCCW = (uint8_t)(((quarterTurnsCCW % 4) + 4) % 4);
    if (mirror == 1) {
        o.hflip = true;
    } else if (mirror == 2) {
        o.hflip = true;
        o.turnsCCW = (uint8_t)((o.turnsCCW + 2) & 3);
    }
    return o;
}

// FFmpeg display matrix (AV_PKT_DATA_DISPLAYMATRIX: 3x3 row-major int32,
// a/b/c/d in 16.16 fixed point). The matrix maps decoded-frame points (p, q),
// y-down, to display points as  p' = a*p + c*q,  q' = b*p + d*q. Converting to
// y-up gives the 2x2 matrix {a, -c, -b, d}. Only axis-aligned transforms within
// about one degree are recognized; arbitrary angles, shears and degenerate
// matrices return identity (and false), like having no matrix.
inline bool videoOrientationFromDisplayMatrix(const int32_t matrix[9], VideoOrientation *out) {
    *out = VideoOrientation{};
    if (!matrix) return false;
    const int64_t a = matrix[0], b = matrix[1], c = matrix[3], d = matrix[4];
    auto mag = [](int64_t v) { return v < 0 ? -v : v; };
    const int64_t diag = mag(a) + mag(d), anti = mag(b) + mag(c);
    // sin(1 deg) ~= 0.0175: off-axis terms must be below 2% of the on-axis ones.
    auto sgn = [](int64_t v) { return v < 0 ? -1 : 1; };
    int na = 0, nb = 0, nc = 0, nd = 0;
    if (diag >= anti) {
        if (a == 0 || d == 0 || mag(b) * 50 >= mag(a) || mag(c) * 50 >= mag(d)) return false;
        na = sgn(a); nd = sgn(d);
    } else {
        if (b == 0 || c == 0 || mag(a) * 50 >= mag(b) || mag(d) * 50 >= mag(c)) return false;
        nb = sgn(b); nc = sgn(c);
    }
    const int m[4] = {na, -nc, -nb, nd};
    return videoOrientationFromMatrix(m, out);
}

// Side-data payload form: pass the AV_PKT_DATA_DISPLAYMATRIX entry's data and
// size (null or short payloads are identity, like a missing entry).
inline VideoOrientation videoOrientationFromDisplayMatrixData(const void *data, size_t size) {
    VideoOrientation o;
    if (!data || size < 9 * sizeof(int32_t)) return o;
    int32_t m[9];
    std::memcpy(m, data, sizeof(m));
    videoOrientationFromDisplayMatrix(m, &o);
    return o;
}

// Clockwise degrees of the rotation part as reported by media tools for an
// iPhone portrait clip (90). Mirroring is reported separately.
inline int videoOrientationClockwiseDegrees(VideoOrientation o) {
    return ((4 - (o.turnsCCW & 3)) & 3) * 90;
}

} // namespace sp
