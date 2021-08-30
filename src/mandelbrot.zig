const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const Vector = std.meta.Vector;

// ============================================
//  Computation
// ============================================

pub const Fixed = u16;
const range_Fixed = (1 << @typeInfo(Fixed).Int.bits) - 1;

//full precision for input
pub const Real = f128;
pub const Complex = std.math.Complex(Real);

// f32 f64 f128 work fine, f16 llvm doesn't like   (obvisously, fixed point with lots of bits would be needed to zoom further)
fn MandelbrotComputer(comptime supersamples: usize, RealType: type) type {
    const vec_len = supersamples * supersamples;
    return struct {
        const Complexs = struct {
            re: Vector(vec_len, RealType),
            im: Vector(vec_len, RealType),
        };
        const Reals = Vector(vec_len, RealType);

        fn magnitudes2(v: Complexs) Reals {
            return v.im * v.im + v.re * v.re;
        }

        // return total number of iterations before all sample points diverge (up to max_iter per point)
        fn computeTotalIterations(sample_points: Complexs, max_iter: u16) u32 {
            var z = Complexs{ .re = sample_points.re, .im = sample_points.im };
            var der = Complexs{ .re = @splat(vec_len, @as(RealType, 1.0)), .im = @splat(vec_len, @as(RealType, 0.0)) };
            var iters = @splat(vec_len, @as(u16, 0));
            const limit = @splat(vec_len, @as(RealType, 5.0)); // must be  >= 2*2
            const eps_der2 = @splat(vec_len, @as(RealType, 0.000001));
            const k2 = @splat(vec_len, @as(RealType, 2.0));

            var i: u16 = 0;
            while (i < max_iter) : (i += 1) {
                // next der = 2*der*z
                der = next_der: {
                    const tmp = Complexs{
                        .re = k2 * (z.re * der.re - z.im * der.im),
                        .im = k2 * (z.re * der.im + z.im * der.re),
                    };
                    break :next_der tmp;
                };
                // next iter: z= z*z + point
                z = next_iter: {
                    const z_squared = Complexs{
                        .re = z.re * z.re - z.im * z.im,
                        .im = z.re * z.im * k2,
                    };
                    break :next_iter Complexs{
                        .re = z_squared.re + sample_points.re,
                        .im = z_squared.im + sample_points.im,
                    };
                };

                // check for divergence / approx convergence
                // /!\ Using the opposite of 'diverged', because diverging computations will yield 'NaN' eventually,
                //      and we use the fact that comparisons with Nan are always false and still want to account them as diverged.
                const boundeds = magnitudes2(z) < limit;
                const stabilizeds = magnitudes2(der) < eps_der2;

                const all_diverged = !@reduce(.Or, boundeds);
                const all_stabilized = @reduce(.And, stabilizeds);

                if (all_diverged)
                    break;
                if (all_stabilized) {
                    // approx. to avoid wasting iterations when inside the set
                    iters = @splat(vec_len, max_iter);
                    break;
                }

                const inc = @bitCast(Vector(vec_len, u1), boundeds); // == @boolToInt
                iters += @intCast(Vector(vec_len, u16), inc);
            }

            var total: u32 = 0;
            i = 0;
            while (i < vec_len) : (i += 1) {
                total += iters[i];
            }
            return total;
        }

        fn computeOnePoint(col: u32, line: u32, width: u32, height: u32, rect: RectOriented, max_iter: u16) Fixed {
            const samples = comptime createSamplePattern(supersamples);

            var points: Complexs = undefined;
            {
                const cols = @splat(vec_len, @intToFloat(Real, col));
                const lines = @splat(vec_len, @intToFloat(Real, line));
                const iwidths = @splat(vec_len, 1.0 / @intToFloat(Real, width));
                const iheights = @splat(vec_len, 1.0 / @intToFloat(Real, height));
                const orig_res = @splat(vec_len, rect.origin.re);
                const orig_ims = @splat(vec_len, rect.origin.im);
                const axis_re_res = @splat(vec_len, rect.axis_re.re);
                const axis_re_ims = @splat(vec_len, rect.axis_re.im);
                const axis_im_res = @splat(vec_len, rect.axis_im.re);
                const axis_im_ims = @splat(vec_len, rect.axis_im.im);

                const xs = (cols + samples.xs) * iwidths;
                const ys = (lines + samples.ys) * iheights;
                const c_res = orig_res + (axis_re_res * xs + axis_im_res * ys);
                const c_ims = orig_ims + (axis_re_ims * xs + axis_im_ims * ys);

                inline for ([1]u1{0} ** vec_len) |_, i| { // TODO: @floatCast(Vector) not supported yet.
                    points.re[i] = @floatCast(RealType, c_res[i]);
                    points.im[i] = @floatCast(RealType, c_ims[i]);
                }
            }

            const total_iter = computeTotalIterations(points, max_iter);
            return @intCast(Fixed, (total_iter * @as(u64, range_Fixed)) / (vec_len * @as(u64, max_iter)));
        }
    };
}

fn createSamplePattern(comptime n: u32) struct { xs: Vector(n * n, Real), ys: Vector(n * n, Real) } {
    const center = @intToFloat(Real, n - 1) * 0.5;
    const size = @intToFloat(Real, 2 + n);
    var xs: Vector(n * n, Real) = undefined;
    var ys: Vector(n * n, Real) = undefined;
    var j: u32 = 0;
    while (j < n) : (j += 1) {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            xs[i + n * j] = (@intToFloat(Real, i) - center) / size;
            ys[i + n * j] = (@intToFloat(Real, j) - center) / size;
        }
    }

    return .{ .xs = xs, .ys = ys };
}

pub const RectOriented = struct {
    origin: Complex,
    axis_re: Complex,
    axis_im: Complex,
};

const FnComputeOnePoint = fn (u32, u32, u32, u32, RectOriented, u16) Fixed;
fn computeOneLine(line: u32, width: u32, height: u32, buf_line: []Fixed, max_iter: u16, func: FnComputeOnePoint, rect: RectOriented, interrupt: *const bool) void {

    // this will create a new task for the thread pool, and suspend back to the caller.
    std.event.Loop.startCpuBoundOperation();

    // std.mem.set(Fixed, buf_line, 0);

    var col: u32 = 0;
    while (col < width) : (col += 1) {
        if (interrupt.*)
            return;
        buf_line[col] = func(col, line, width, height, rect, max_iter);
    }
}

// compute the appartenance level of each points in buf
pub const AsyncComputeStatus = enum { idle, computing, done };
pub fn computeLevels(buf: []Fixed, width: u32, height: u32, rect: RectOriented, max_iter: u16, supersamples: u32, real_bits: u32, status: *AsyncComputeStatus, interrupt: *const bool) void {
    assert(status.* == .idle);
    status.* = .computing;

    // choose comptime variant for runtime parameters
    const func = switch (real_bits) {
        0...16 => switch (supersamples) {
            1 => MandelbrotComputer(1, f16).computeOnePoint,
            2 => MandelbrotComputer(2, f16).computeOnePoint,
            3 => MandelbrotComputer(3, f16).computeOnePoint,
            4 => MandelbrotComputer(4, f16).computeOnePoint,
            else => MandelbrotComputer(5, f16).computeOnePoint,
        },
        17...32 => switch (supersamples) {
            1 => MandelbrotComputer(1, f32).computeOnePoint,
            2 => MandelbrotComputer(2, f32).computeOnePoint,
            3 => MandelbrotComputer(3, f32).computeOnePoint,
            4 => MandelbrotComputer(4, f32).computeOnePoint,
            else => MandelbrotComputer(5, f32).computeOnePoint,
        },
        33...64 => switch (supersamples) {
            1 => MandelbrotComputer(1, f64).computeOnePoint,
            2 => MandelbrotComputer(2, f64).computeOnePoint,
            3 => MandelbrotComputer(3, f64).computeOnePoint,
            4 => MandelbrotComputer(4, f64).computeOnePoint,
            else => MandelbrotComputer(5, f64).computeOnePoint,
        },
        else => switch (supersamples) {
            1 => MandelbrotComputer(1, f128).computeOnePoint,
            2 => MandelbrotComputer(2, f128).computeOnePoint,
            3 => MandelbrotComputer(3, f128).computeOnePoint,
            4 => MandelbrotComputer(4, f128).computeOnePoint,
            else => MandelbrotComputer(5, f128).computeOnePoint,
        },
    };

    var func_frames: [1500]@Frame(computeOneLine) = undefined;

    var line: u32 = 0;
    while (line < height) : (line += 1) {
        const buf_line = buf[line * width .. (line + 1) * width];
        func_frames[line] = async computeOneLine(line, width, height, buf_line, max_iter, func, rect, interrupt);
    }

    line = 0;
    while (line < height) : (line += 1) {
        await func_frames[line];
    }

    assert(status.* == .computing);
    status.* = .done;
}

pub fn drawSetAscii(rect: RectOriented) void {
    const grayscale = " .:ioVM@";
    const width = 120;
    const height = 40;
    var span: [width]u8 = undefined;

    var lin: u32 = 0;
    while (lin < height) : (lin += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const level = MandelbrotComputer(3, f32).computeOnePoint(col, lin, width, height, rect, 150);
            span[col] = grayscale[(level * (grayscale.len - 1)) / range_Fixed];
        }
        warn("{s}\n", .{span});
    }
}

// ============================================
//  rescale util
// ============================================

fn rescaleLine(dest: []Fixed, orig: []const Fixed, old_width: u32, new_width: u32) void {
    if (new_width >= old_width) {
        var d: u32 = new_width;
        while (d > 0) : (d -= 1) {
            const o = (d * old_width - old_width / 2) / new_width;
            dest[d - 1] = orig[o];
        }
    } else {
        var d: u32 = 0;
        while (d < new_width) : (d += 1) {
            const o = (d * old_width) / new_width;
            dest[d] = orig[o];
        }
    }
}

pub fn rescaleLevels(buf: []Fixed, old_width: u32, old_height: u32, new_width: u32, new_height: u32) void {
    if (new_height >= old_height) {
        var d: u32 = new_height;
        while (d > 0) : (d -= 1) {
            const o = (d * old_height - old_height / 2) / new_height;
            rescaleLine(buf[(d - 1) * new_width .. d * new_width], buf[o * old_width .. (o + 1) * old_width], old_width, new_width);
        }
    } else {
        var d: u32 = 0;
        while (d < new_height) : (d += 1) {
            const o = (d * old_height) / new_height;
            rescaleLine(buf[d * new_width .. (d + 1) * new_width], buf[o * old_width .. (o + 1) * old_width], old_width, new_width);
        }
    }
}

// ============================================
//  Presentation
// ============================================

fn saturate(v: f32) u8 {
    if (v <= 0.0) {
        return 0;
    } else if (v >= 1.0) {
        return 255;
    } else {
        return @floatToInt(u8, v * 255);
    }
}

fn saturate4(vals: anytype) Vector(4, u8) {
    return [_]u8{
        saturate(vals[0]),
        saturate(vals[1]),
        saturate(vals[2]),
        saturate(vals[3]),
    };
    // TODO: @shuffle + @floatToInt(vector)?
}

fn intToFloat4(comptime T: type, vals: anytype) Vector(4, T) {
    return [_]T{
        @intToFloat(T, vals[0]),
        @intToFloat(T, vals[1]),
        @intToFloat(T, vals[2]),
        @intToFloat(T, vals[3]),
    };
}

fn smootherstep4(x: Vector(4, f32)) Vector(4, f32) {
    const k6 = @splat(4, @as(f32, 6.0));
    const k15 = @splat(4, @as(f32, 15.0));
    const k10 = @splat(4, @as(f32, 10.0));
    return x * x * x * (x * (x * k6 - k15) + k10);
}
fn halfsmootherstep4(x: Vector(4, f32)) Vector(4, f32) {
    const k2 = @splat(4, @as(f32, 2.0));
    const k05 = @splat(4, @as(f32, 0.5));
    return (smootherstep4(x * k05 + k05) - k05) * k2;
}

fn levelsToColors(level: Vector(4, u16)) Vector(4, u32) {
    const l0 = intToFloat4(f32, level);

    //const knorm = @splat(4, 1.0 / @as(f32, range_Fixed));
    //const l = halfsmootherstep4(l0 * knorm);
    //const l = @sqrt(l0 * knorm); // faster and prettier... (but still expensive)

    // prettiest
    const knorm = @splat(4, 1.6667 / @log2(@as(f32, range_Fixed) + 1));
    const l = @log2(l0 + @splat(4, @as(f32, 1.0))) * knorm;

    const k2 = @splat(4, @as(f32, 1.0 / 1.35));
    const R = l;
    const G = (l * k2);
    const B = (l * k2 * k2);

    const kFF000000 = @splat(4, @as(u32, 0xFF000000));
    const k000001 = @splat(4, @as(u32, 0x000001));
    const k000100 = @splat(4, @as(u32, 0x000100));
    const k010000 = @splat(4, @as(u32, 0x010000));
    const ABGR = kFF000000 + k000001 * @intCast(Vector(4, u32), saturate4(R)) + k000100 * @intCast(Vector(4, u32), saturate4(G)) + k010000 * @intCast(Vector(4, u32), saturate4(B));

    return ABGR;
}

pub fn computeColors(levels: []const Fixed, pixels: []Vector(4, u32), width: u32, height: u32) void {
    var j: u32 = 0;
    while (j < height) : (j += 1) {
        var i: u32 = 0;
        while (i < width) : (i += 4) {
            const levels4 = @as(Vector(4, u16), levels[(j * width + i)..][0..4].*);
            pixels[(j * width + i) / 4] = levelsToColors(levels4);
        }
    }
}
