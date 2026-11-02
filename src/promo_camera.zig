//! Deterministic promo camera, magnifier, vignette, and grain.
//! Input: stage points. Output: BGRA pixels.
const std = @import("std");

pub const Bezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    fn axis(a: f32, b: f32, t: f32) f32 {
        const u = 1 - t;
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
    }

    /// The curve's height where it is `x` across (0…1), clamped.
    pub fn at(e: Bezier, x_in: f32) f32 {
        const x = std.math.clamp(x_in, 0, 1);
        if (x == 0 or x == 1) return x;
        // Bisection: the x of a CSS cubic-bezier is monotonic.
        var lo: f32 = 0;
        var hi: f32 = 1;
        var t: f32 = x;
        for (0..30) |_| {
            t = (lo + hi) / 2;
            if (axis(e.x1, e.x2, t) < x) lo = t else hi = t;
        }
        return axis(e.y1, e.y2, t);
    }
};

pub const out: Bezier = .{ .x1 = 0.23, .y1 = 1, .x2 = 0.32, .y2 = 1 };
pub const in_out: Bezier = .{ .x1 = 0.77, .y1 = 0, .x2 = 0.175, .y2 = 1 };
/// A drawer's: quick, then a long settle.
pub const drawer: Bezier = .{ .x1 = 0.32, .y1 = 0.72, .x2 = 0, .y2 = 1 };

/// How far `now` is through [from, from + len], eased.
pub fn ease(e: Bezier, now: f32, from: f32, len: f32) f32 {
    return e.at((now - from) / len);
}

pub fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Where the camera looks: `zoom` (1 is the whole stage) about a point of
/// the stage, in points.
pub const View = struct { zoom: f32 = 1, cx: f32, cy: f32 };

/// The camera moving to `to` between `at` and `at + len`.
pub const Move = struct { at: f32, len: f32, to: View };

/// The camera at `now`: each move eased from where the last one left it.
pub fn camera(start: View, moves: []const Move, now: f32) View {
    var v = start;
    for (moves) |m| {
        if (now <= m.at) break;
        const k = ease(in_out, now, m.at, m.len);
        v = .{ .zoom = mix(v.zoom, m.to.zoom, k), .cx = mix(v.cx, m.to.cx, k), .cy = mix(v.cy, m.to.cy, k) };
    }
    return v;
}

/// A loupe over a point of the stage: in, held, out.
pub const Loupe = struct {
    at: f32,
    /// The stage point it magnifies (null: the scene says, at `at`).
    x: f32 = 0,
    y: f32 = 0,
    mag: f32,
    hold: f32,
    /// Its window, in output pixels.
    w: f32 = 620,
    h: f32 = 250,
    const in_len = 0.5;
    const out_len = 0.6;

    pub fn end(l: Loupe) f32 {
        return l.at + in_len + l.hold + out_len;
    }

    /// How open it is at `now`: 0 shut, 1 fully in.
    pub fn amount(l: Loupe, now: f32) f32 {
        if (now < l.at or now > l.end()) return 0;
        if (now < l.at + in_len) return ease(out, now, l.at, in_len);
        const close = l.at + in_len + l.hold;
        if (now < close) return 1;
        return 1 - ease(in_out, now, close, out_len);
    }
};

pub const Frame = struct {
    /// BGRA, `w`×`h`, the stage at `px_per_pt` pixels a point.
    bytes: []const u8,
    w: usize,
    h: usize,
    px_per_pt: f32,
};

/// The stage's size in points; the output's in pixels.
pub const Lens = struct {
    stage_w: f32,
    stage_h: f32,
    out_w: usize,
    out_h: usize,

    fn outPerPt(l: Lens) f32 {
        return @as(f32, @floatFromInt(l.out_w)) / l.stage_w;
    }

    /// `v`, kept inside the stage (a zoom of at least 1).
    pub fn clamp(l: Lens, v: View) View {
        const z = @max(1, v.zoom);
        const hw = l.stage_w / 2 / z;
        const hh = l.stage_h / 2 / z;
        return .{ .zoom = z, .cx = std.math.clamp(v.cx, hw, l.stage_w - hw), .cy = std.math.clamp(v.cy, hh, l.stage_h - hh) };
    }

    /// Where stage point (x, y) lands in the output, in pixels.
    pub fn toOut(l: Lens, v: View, x: f32, y: f32) [2]f32 {
        const k = l.outPerPt() * v.zoom;
        return .{ (x - v.cx) * k + @as(f32, @floatFromInt(l.out_w)) / 2, (y - v.cy) * k + @as(f32, @floatFromInt(l.out_h)) / 2 };
    }
};

fn sample(src: Frame, sx: f32, sy: f32) [3]f32 {
    const x = std.math.clamp(sx, 0, @as(f32, @floatFromInt(src.w - 1)) - 0.001);
    const y = std.math.clamp(sy, 0, @as(f32, @floatFromInt(src.h - 1)) - 0.001);
    const x0: usize = @intFromFloat(x);
    const y0: usize = @intFromFloat(y);
    const fx = x - @as(f32, @floatFromInt(x0));
    const fy = y - @as(f32, @floatFromInt(y0));
    const row = src.w * 4;
    const p = src.bytes[y0 * row + x0 * 4 ..];
    const q = src.bytes[(y0 + 1) * row + x0 * 4 ..];
    var c: [3]f32 = undefined;
    for (0..3) |i| {
        const a = mix(@floatFromInt(p[i]), @floatFromInt(p[4 + i]), fx);
        const b = mix(@floatFromInt(q[i]), @floatFromInt(q[4 + i]), fx);
        c[i] = mix(a, b, fy);
    }
    return c;
}

/// The stage under output pixel (ox, oy) through view `v`: four samples
/// a pixel, so a 2× downscale stays smooth.
fn look(src: Frame, l: Lens, v: View, ox: f32, oy: f32) [3]f32 {
    const k = 1 / (l.outPerPt() * v.zoom);
    return point(src, (ox - @as(f32, @floatFromInt(l.out_w)) / 2) * k + v.cx, (oy - @as(f32, @floatFromInt(l.out_h)) / 2) * k + v.cy, k);
}

/// Stage point (x, y), an output pixel being `k` points across.
fn point(src: Frame, x: f32, y: f32, k: f32) [3]f32 {
    const step = k * src.px_per_pt;
    const sx = x * src.px_per_pt;
    const sy = y * src.px_per_pt;
    var acc: [3]f32 = .{ 0, 0, 0 };
    const d = step / 4;
    for ([_][2]f32{ .{ -d, -d }, .{ d, -d }, .{ -d, d }, .{ d, d } }) |o| {
        const c = sample(src, sx + o[0], sy + o[1]);
        for (0..3) |i| acc[i] += c[i] / 4;
    }
    return acc;
}

/// A rounded rectangle's signed distance (negative inside).
fn roundedBox(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px - cx) - (hw - r);
    const qy = @abs(py - cy) - (hh - r);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
}

fn hash(x: u32, y: u32, f: u32) f32 {
    var h = x *% 374761393 +% y *% 668265263 +% f *% 2246822519;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffff)) / 65535.0 - 0.5;
}

/// The loupe as drawn this frame: where, how big, how far in.
pub const Lit = struct {
    /// Where its point lies in the output; the stage point; how far in.
    ox: f32,
    oy: f32,
    x: f32,
    y: f32,
    mag: f32,
    a: f32,
    w: f32,
    h: f32,
    /// Its window's centre: on the point, kept 40 pixels inside the frame.
    wx: f32 = 0,
    wy: f32 = 0,

    pub fn placed(p: Lit, l: Lens) Lit {
        var q = p;
        const ow: f32 = @floatFromInt(l.out_w);
        const oh: f32 = @floatFromInt(l.out_h);
        q.wx = std.math.clamp(p.ox, p.w / 2 + 40, ow - p.w / 2 - 40);
        q.wy = std.math.clamp(p.oy, p.h / 2 + 40, oh - p.h / 2 - 40);
        return q;
    }
};

/// Writes the output frame (BGRA) for view `v`, with `lit` over it when
/// one is open, and the vignette and grain of frame number `n`.
pub fn shoot(src: Frame, l: Lens, v_in: View, lit: ?Lit, n: u32, dst: []u8) void {
    const v = l.clamp(v_in);
    const ow: f32 = @floatFromInt(l.out_w);
    const oh: f32 = @floatFromInt(l.out_h);
    for (0..l.out_h) |y| {
        const oy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        for (0..l.out_w) |x| {
            const ox: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            var c = look(src, l, v, ox, oy);
            if (lit) |p| c = loupe(src, l, v, p, ox, oy, c);
            // Vignette: a quarter darker in the corners.
            const dx = (ox / ow - 0.5) * 1.6;
            const dy = (oy / oh - 0.5) * 1.6;
            const vig = 1 - 0.22 * @min(1, dx * dx + dy * dy);
            // Film grain: clumps of two pixels, new thirty times a second.
            const g = hash(@intCast(x / 2), @intCast(y / 2), n / 2) * 6;
            const o = dst[(y * l.out_w + x) * 4 ..][0..4];
            for (0..3) |i| o[i] = @intFromFloat(std.math.clamp(c[i] * vig + g, 0, 255));
            o[3] = 255;
        }
    }
}

fn loupe(src: Frame, l: Lens, v: View, p: Lit, ox: f32, oy: f32, under: [3]f32) [3]f32 {
    const hw = p.w / 2 * mix(0.92, 1, p.a);
    const hh = p.h / 2 * mix(0.92, 1, p.a);
    const r: f32 = 26;
    const d = roundedBox(ox, oy, p.wx, p.wy, hw, hh, r);
    var c = under;
    // Its shadow, under it.
    if (d > 0 and d < 60) {
        const s = (1 - d / 60);
        const k = 1 - 0.55 * s * s * p.a;
        for (0..3) |i| c[i] *= k;
        return c;
    }
    if (d > 0) return c;
    // Inside: the stage about (x, y), `mag` times closer, fixed where it lies.
    const m = mix(1, p.mag, p.a);
    const k = 1 / (l.outPerPt() * v.zoom * m);
    const inside = point(src, (ox - p.ox) * k + p.x, (oy - p.oy) * k + p.y, k);
    const edge = std.math.clamp(-d, 0, 1);
    for (0..3) |i| c[i] = mix(c[i], inside[i], edge * @min(1, p.a * 1.6));
    // A hairline rim of light.
    if (d > -2) for (0..3) |i| {
        c[i] = mix(c[i], 255, 0.35 * p.a);
    };
    return c;
}

test "eases start, end and S-curve where they should" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0), in_out.at(0), 1e-4);
    try t.expectApproxEqAbs(@as(f32, 1), in_out.at(1), 1e-4);
    const mid = in_out.at(0.5);
    try t.expect(mid > 0.3 and mid < 0.7);
    try t.expect(in_out.at(0.2) < 0.1);
    try t.expect(out.at(0.2) > 0.6);
}

test "the camera eases between moves and holds after" {
    const moves = [_]Move{.{ .at = 1, .len = 1, .to = .{ .zoom = 2, .cx = 10, .cy = 10 } }};
    const s: View = .{ .zoom = 1, .cx = 0, .cy = 0 };
    try std.testing.expectEqual(@as(f32, 1), camera(s, &moves, 0.5).zoom);
    try std.testing.expectEqual(@as(f32, 2), camera(s, &moves, 5).zoom);
    const l: Lens = .{ .stage_w = 1280, .stage_h = 720, .out_w = 1920, .out_h = 1080 };
    const c = l.clamp(.{ .zoom = 2, .cx = 0, .cy = 0 });
    try std.testing.expectEqual(@as(f32, 320), c.cx);
    const p = l.toOut(.{ .zoom = 1, .cx = 640, .cy = 360 }, 640, 360);
    try std.testing.expectEqual(@as(f32, 960), p[0]);
}
