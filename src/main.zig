const std = @import("std");
const fmt = std.fmt;
const warn = std.debug.warn;
const assert = std.debug.assert;
const trace = @import("tracy.zig").trace;
const traceEx = @import("tracy.zig").traceEx;
const traceFrame = @import("tracy.zig").traceFrame;

const Viewport = @import("viewport.zig");
const Mandelbrot = @import("mandelbrot.zig");
const Imgui = @import("imgui.zig");
const Complex = Mandelbrot.Complex;
const Vector = std.meta.Vector;

const SDL = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

extern fn ImGui_ImplSDL2_ProcessEvent(event: *const SDL.SDL_Event) bool;

// work-arounds:
//pub const SDL_TOUCH_MOUSEID = Uint32 - 1;  -> "error: integer value 1 cannot be coerced to type 'type'""
const zig_SDL_TOUCH_MOUSEID: u32 = 0xFFFFFFFF;

// enable thread pool:
pub const io_mode = .evented;

const show_dev_ui = true;

// ============================================
//  Input states
// ============================================

const Point = struct {
    x: f32,
    y: f32,
};
const Segment = struct {
    a: Point,
    b: Point,
};
const MouseState = struct {
    const ClicPos = struct {
        pos: Point,
    };
    current: ?ClicPos = null,
    initial: ClicPos = undefined,
};

const TouchState = struct {
    const FingerPos = struct {
        pos: Point,
        finger_id: i64,
    };
    const max_fingers = 4;
    fingers: u8 = 0,
    current: [max_fingers]FingerPos = undefined,
    initial: [max_fingers]FingerPos = undefined,

    fn addFinger(self: *TouchState, finger_id: i64) *Point {
        assert(self.fingers < TouchState.max_fingers);
        for (self.current[0..self.fingers]) |s| {
            assert(s.finger_id != finger_id);
        }
        self.fingers += 1;
        self.current[self.fingers - 1].finger_id = finger_id;
        return &self.current[self.fingers - 1].pos;
    }
    fn getFinger(self: *TouchState, finger_id: i64) *Point {
        assert(self.fingers > 0);
        var idx: ?usize = null;
        for (self.current[0..self.fingers]) |s, i| {
            if (s.finger_id == finger_id) idx = i;
        }
        return &self.current[idx.?].pos;
    }
    fn subFinger(self: *TouchState, finger_id: i64) void {
        assert(self.fingers > 0);
        var idx: ?usize = null;
        for (self.current[0..self.fingers]) |s, i| {
            if (s.finger_id == finger_id) idx = i;
        }
        assert(idx != null);
        if (self.fingers > 1)
            self.current[idx.?] = self.current[self.fingers - 1];
        self.fingers -= 1;
    }
};

fn pointToMandel(r: Mandelbrot.RectOriented, p: Point) Complex {
    const axis_re = Complex.mul(r.axis_re, Complex{ .re = @floatCast(f16, p.x), .im = 0 });
    const axis_im = Complex.mul(r.axis_im, Complex{ .re = @floatCast(f16, p.y), .im = 0 });
    return r.origin.add(axis_re).add(axis_im);
}

fn normaliseBufferDim(v: u32, max: u32) u32 {
    const x = if (v > max) max else v;
    return x - x % 4;
}

fn tagNameZ(v: anytype, storage: []u8) [:0]const u8 {
    const name = @tagName(v);
    std.mem.copy(u8, storage, name);
    storage[name.len] = 0;
    return storage[0..name.len :0];
}

pub fn main() !void {
    if (false) {
        Mandelbrot.drawSetAscii(Mandelbrot.RectOriented{
            .origin = Complex{ .re = -2, .im = -1 },
            .axis_re = Complex{ .re = 3, .im = 0 },
            .axis_im = Complex{ .re = 0, .im = 2 },
        });
        return;
    }

    const allocator = std.heap.c_allocator;

    var viewport = try Viewport.init("Mandelbrot set explorer", 1280, 720, allocator);
    defer Viewport.destroy(viewport);

    const mandel_max_width = 1920;
    const mandel_max_height = 1080;
    const mandel_levels = try allocator.alloc(Mandelbrot.Fixed, (mandel_max_height * mandel_max_width));
    defer allocator.free(mandel_levels);
    var mandel_levels_width: u32 = undefined;
    var mandel_levels_height: u32 = undefined;

    const mandel_pixels = try allocator.alloc(Vector(4, u32), (mandel_max_height * mandel_max_width / 4));
    defer allocator.free(mandel_pixels);
    var mandel_pixels_width: u32 = 32;
    var mandel_pixels_height: u32 = 32;
    std.mem.set(Vector(4, u32), mandel_pixels[0..(mandel_pixels_height * mandel_pixels_width / 4)], [_]u32{ 0, 200, 0, 0 });

    // Settings:
    const QualityParams = struct {
        supersamples: c_int,
        max_iter: c_int,
        resolution_divider: c_int,
        precision_bits: c_int, // 32, 64, 128
        label: [:0]const u8,
    };
    var quality_normal = QualityParams{ .supersamples = 3, .max_iter = 25000, .resolution_divider = 1, .precision_bits = 64, .label = "normal" };
    var quality_preview = QualityParams{ .supersamples = 1, .max_iter = 25000, .resolution_divider = 4, .precision_bits = 32, .label = "preview" };
    var continuous_refresh = true;

    // State:
    const MandelComputeState = struct {
        // currently processing
        status: Mandelbrot.AsyncComputeStatus = .idle,
        interrupt: bool = false,
        callframe: @Frame(Mandelbrot.computeLevels) = undefined,

        // next request
        dirty: enum { changed, previewed, done } = .changed,
        mandelrect: Mandelbrot.RectOriented = Mandelbrot.RectOriented{
            .origin = Complex{ .re = -2, .im = -1 },
            .axis_re = Complex{ .re = 3, .im = 0 },
            .axis_im = Complex{ .re = 0, .im = 2 },
        },
        changed_timestamp_ms: u64 = 0,
        previewed_timestamp_ms: u64 = 0,
        done_timestamp_ms: u64 = 0,
    };
    var mandel_compute_state = MandelComputeState{};

    var mouse_state = MouseState{};
    var touch_state = TouchState{};
    var touch_initial_mandelrect: Mandelbrot.RectOriented = undefined;

    var quit = false;
    while (!quit) {
        const tracy_frame = traceFrame(null);
        defer tracy_frame.end();

        // screen size:
        var screen_width: u32 = undefined;
        var screen_height: u32 = undefined;
        Viewport.getWindowSize(viewport, &screen_width, &screen_height);

        // inputs
        {
            const tracy_inputs = traceEx(@src(), .{ .name = "inputs" });
            defer tracy_inputs.end();

            const imgui_io = Imgui.GetIO();

            const AffineTransfo = struct { // y = a0 + a1*x
                a0: Complex,
                a1: Complex,
            };
            var transfo: ?AffineTransfo = null;
            var transfo_ref_mandelrect: Mandelbrot.RectOriented = mandel_compute_state.mandelrect;

            var event: SDL.SDL_Event = undefined;
            while (SDL.SDL_PollEvent(&event) != 0) {
                _ = ImGui_ImplSDL2_ProcessEvent(&event);
                if (event.type == SDL.SDL_QUIT)
                    quit = true;

                if (!imgui_io.WantCaptureMouse) {
                    var ref_segment: ?Segment = null;
                    var target_segment: ?Segment = null;
                    if (event.type == SDL.SDL_MOUSEWHEEL and event.wheel.which != zig_SDL_TOUCH_MOUSEID and event.wheel.y != 0) {
                        ref_segment = Segment{ .a = Point{ .x = 0.5, .y = 0.5 }, .b = Point{ .x = 1, .y = 0.5 } };
                        target_segment = ref_segment;
                        if (event.wheel.y > 0) {
                            target_segment.?.b.x *= 1.333;
                        } else {
                            target_segment.?.b.x /= 1.333;
                        }
                    }

                    if (event.type == SDL.SDL_MOUSEBUTTONDOWN and event.button.which != zig_SDL_TOUCH_MOUSEID) {
                        if (event.button.button == SDL.SDL_BUTTON_RIGHT) {
                            const click_pos = Point{ .x = @intToFloat(f32, event.button.x) / @intToFloat(f32, screen_width), .y = @intToFloat(f32, event.button.y) / @intToFloat(f32, screen_height) };
                            const target_pos = Point{ .x = 0.5, .y = 0.5 };

                            ref_segment = Segment{ .a = click_pos, .b = Point{ .x = click_pos.x + 1, .y = click_pos.y } };
                            target_segment = Segment{ .a = target_pos, .b = Point{ .x = target_pos.x + 1, .y = target_pos.y } };
                        }

                        if (event.button.button == SDL.SDL_BUTTON_LEFT) {
                            const click_pos = Point{ .x = @intToFloat(f32, event.button.x) / @intToFloat(f32, screen_width), .y = @intToFloat(f32, event.button.y) / @intToFloat(f32, screen_height) };
                            mouse_state.current = MouseState.ClicPos{ .pos = click_pos };
                            mouse_state.initial = mouse_state.current.?;
                        }
                    }
                    if (event.type == SDL.SDL_MOUSEBUTTONUP and event.button.which != zig_SDL_TOUCH_MOUSEID and event.button.button == SDL.SDL_BUTTON_LEFT) {
                        const click_pos = Point{ .x = @intToFloat(f32, event.button.x) / @intToFloat(f32, screen_width), .y = @intToFloat(f32, event.button.y) / @intToFloat(f32, screen_height) };
                        mouse_state.current = MouseState.ClicPos{ .pos = click_pos };

                        const a = mouse_state.initial.pos;
                        const b = mouse_state.current.?.pos;
                        ref_segment = Segment{ .a = Point{ .x = (a.x + b.x) / 2.0, .y = (a.y + b.y) / 2.0 }, .b = Point{ .x = std.math.max(a.x, b.x), .y = (a.y + b.y) / 2.0 } };
                        target_segment = Segment{ .a = Point{ .x = 0.5, .y = 0.5 }, .b = Point{ .x = 1, .y = 0.5 } };
                        mouse_state.current = null;
                    }
                    if (event.type == SDL.SDL_MOUSEMOTION and event.motion.which != zig_SDL_TOUCH_MOUSEID and (event.motion.state & (1 << (SDL.SDL_BUTTON_LEFT - 1)) != 0)) {
                        const click_pos = Point{ .x = @intToFloat(f32, event.motion.x) / @intToFloat(f32, screen_width), .y = @intToFloat(f32, event.motion.y) / @intToFloat(f32, screen_height) };
                        mouse_state.current = MouseState.ClicPos{ .pos = click_pos };
                    }

                    if (event.type == SDL.SDL_FINGERMOTION or event.type == SDL.SDL_FINGERDOWN or event.type == SDL.SDL_FINGERUP) {
                        if (event.type == SDL.SDL_FINGERDOWN) {
                            touch_state.addFinger(event.tfinger.fingerId).* = Point{ .x = event.tfinger.x, .y = event.tfinger.y };
                            touch_state.initial = touch_state.current;
                            touch_initial_mandelrect = mandel_compute_state.mandelrect;
                        }
                        if (event.type == SDL.SDL_FINGERUP) {
                            touch_state.subFinger(event.tfinger.fingerId);
                            touch_state.initial = touch_state.current;
                            touch_initial_mandelrect = mandel_compute_state.mandelrect;
                        }
                        if (event.type == SDL.SDL_FINGERMOTION) {
                            touch_state.getFinger(event.tfinger.fingerId).* = Point{ .x = event.tfinger.x, .y = event.tfinger.y };
                        }

                        if (touch_state.fingers >= 2) {
                            ref_segment = Segment{
                                .a = touch_state.initial[touch_state.fingers - 2].pos,
                                .b = touch_state.initial[touch_state.fingers - 1].pos,
                            };
                            target_segment = Segment{
                                .a = touch_state.current[touch_state.fingers - 2].pos,
                                .b = touch_state.current[touch_state.fingers - 1].pos,
                            };
                            transfo_ref_mandelrect = touch_initial_mandelrect;
                        }
                    }

                    if (target_segment) |tgt| {
                        const ref = ref_segment.?;

                        const ref_a = pointToMandel(transfo_ref_mandelrect, ref.a);
                        const ref_b = pointToMandel(transfo_ref_mandelrect, ref.b);
                        const tgt_a = pointToMandel(transfo_ref_mandelrect, tgt.a);
                        const tgt_b = pointToMandel(transfo_ref_mandelrect, tgt.b);

                        const a1 = Complex.div(Complex.sub(ref_a, ref_b), Complex.sub(tgt_a, tgt_b));
                        const a0 = Complex.sub(ref_a, Complex.mul(tgt_a, a1));
                        transfo = AffineTransfo{
                            .a0 = a0,
                            .a1 = a1,
                        };
                    }
                }

                if (transfo) |t| {
                    mandel_compute_state.mandelrect.origin = Complex.add(Complex.mul(transfo_ref_mandelrect.origin, t.a1), t.a0);
                    mandel_compute_state.mandelrect.axis_re = Complex.mul(transfo_ref_mandelrect.axis_re, t.a1);
                    mandel_compute_state.mandelrect.axis_im = Complex.mul(transfo_ref_mandelrect.axis_im, t.a1);

                    mandel_compute_state.dirty = .changed;
                }
            }
        }

        Viewport.beginFrame(viewport);

        if (show_dev_ui) {
            const tracy_imgui = traceEx(@src(), .{ .name = "imgui" });
            defer tracy_imgui.end();

            _ = Imgui.Begin("Parameters");
            defer Imgui.End();

            _ = Imgui.Checkbox("continuous refresh", &continuous_refresh);

            for ([_]*QualityParams{ &quality_preview, &quality_normal }) |it| {
                if (Imgui.CollapsingHeaderExt(it.label, .{ .DefaultOpen = true })) {
                    Imgui.PushIDStr(it.label);
                    defer Imgui.PopID();
                    const value_changed1 = Imgui.SliderInt("max iterations", &it.max_iter, 1, 50000);
                    const value_changed2 = Imgui.SliderInt("antialias", &it.supersamples, 1, 5);
                    const value_changed3 = Imgui.SliderInt("coarseness", &it.resolution_divider, 1, 8);
                    const value_changed4 = Imgui.InputIntExt("precison bits (16,32,64,128)", &it.precision_bits, 32, 1, .{});

                    if ((value_changed1 or value_changed2 or value_changed3 or value_changed4) and mandel_compute_state.dirty == .done) {
                        mandel_compute_state.dirty = .previewed;
                    }
                }
            }

            {
                var storage: [100]u8 = undefined;
                Imgui.Text(tagNameZ(mandel_compute_state.status, &storage));
            }

            if (mandel_compute_state.status == .idle and (mandel_compute_state.done_timestamp_ms > mandel_compute_state.previewed_timestamp_ms) and (mandel_compute_state.previewed_timestamp_ms > mandel_compute_state.changed_timestamp_ms)) {
                const preview_dur: f64 = @intToFloat(f64, mandel_compute_state.previewed_timestamp_ms - mandel_compute_state.changed_timestamp_ms) / 1000;
                const final_dur: f64 = @intToFloat(f64, mandel_compute_state.done_timestamp_ms - mandel_compute_state.previewed_timestamp_ms) / 1000;
                Imgui.Text("Latest computation: %.3fs (preview: %.3fs)", final_dur, preview_dur);
            } else {
                Imgui.Text("Latest computation: ...");
            }

            const imgui_io = Imgui.GetIO();
            Imgui.Text("Application average %.3f ms/frame (%.1f FPS)", @floatCast(f64, 1000.0 / imgui_io.Framerate), @floatCast(f64, imgui_io.Framerate));
        }

        // mandelbrot computer state
        switch (mandel_compute_state.status) {
            .idle => { // start a new computation if parameters dirty
                const tracy_compute = traceEx(@src(), .{ .name = "idle" });
                defer tracy_compute.end();

                switch (mandel_compute_state.dirty) {
                    .changed => {
                        mandel_compute_state.changed_timestamp_ms = @intCast(u64, std.time.milliTimestamp());

                        const d = @intCast(u32, quality_preview.resolution_divider);
                        mandel_levels_width = normaliseBufferDim(screen_width / d, mandel_max_width);
                        mandel_levels_height = normaliseBufferDim(screen_height / d, mandel_max_height);
                        mandel_compute_state.interrupt = false;
                        mandel_compute_state.callframe = async Mandelbrot.computeLevels(mandel_levels, mandel_levels_width, mandel_levels_height, mandel_compute_state.mandelrect, @intCast(u16, quality_preview.max_iter), @intCast(u32, quality_preview.supersamples), @intCast(u32, quality_preview.precision_bits), &mandel_compute_state.status, &mandel_compute_state.interrupt);

                        mandel_compute_state.dirty = .previewed;
                    },
                    .previewed => {
                        mandel_compute_state.previewed_timestamp_ms = @intCast(u64, std.time.milliTimestamp());

                        const d = @intCast(u32, quality_normal.resolution_divider);
                        const w = normaliseBufferDim(screen_width / d, mandel_max_width);
                        const h = normaliseBufferDim(screen_height / d, mandel_max_height);
                        if (continuous_refresh and (h != mandel_levels_height or w != mandel_levels_width))
                            Mandelbrot.rescaleLevels(mandel_levels, mandel_levels_width, mandel_levels_height, w, h);
                        mandel_levels_width = w;
                        mandel_levels_height = h;
                        mandel_compute_state.interrupt = false;
                        mandel_compute_state.callframe = async Mandelbrot.computeLevels(mandel_levels, mandel_levels_width, mandel_levels_height, mandel_compute_state.mandelrect, @intCast(u16, quality_normal.max_iter), @intCast(u32, quality_normal.supersamples), @intCast(u32, quality_normal.precision_bits), &mandel_compute_state.status, &mandel_compute_state.interrupt);

                        mandel_compute_state.dirty = .done;
                    },
                    .done => {},
                }
            },
            .computing => {
                const tracy_compute = traceEx(@src(), .{ .name = "computing" });
                defer tracy_compute.end();

                if (mandel_compute_state.dirty == .changed)
                    mandel_compute_state.interrupt = true;
                if (continuous_refresh) {
                    mandel_pixels_width = mandel_levels_width;
                    mandel_pixels_height = mandel_levels_height;
                    Mandelbrot.computeColors(mandel_levels, mandel_pixels, mandel_pixels_width, mandel_pixels_height);
                }
            },
            .done => { // finish the asynccall, present the result and get ready to make a new one.
                const tracy_compute = traceEx(@src(), .{ .name = "compute_done" });
                defer tracy_compute.end();

                await mandel_compute_state.callframe;
                mandel_compute_state.status = .idle;

                if (!mandel_compute_state.interrupt or true) {
                    mandel_pixels_width = mandel_levels_width;
                    mandel_pixels_height = mandel_levels_height;
                    Mandelbrot.computeColors(mandel_levels, mandel_pixels, mandel_pixels_width, mandel_pixels_height);
                }
                mandel_compute_state.done_timestamp_ms = @intCast(u64, std.time.milliTimestamp());
            },
        }

        // viewport update
        {
            const tracy_viewport = traceEx(@src(), .{ .name = "viewport" });
            defer tracy_viewport.end();

            const w = @intToFloat(f32, screen_width);
            const h = @intToFloat(f32, screen_height);

            {
                const corners = [4]Viewport.Vec2{
                    Viewport.Vec2{ .x = 0, .y = 0 },
                    Viewport.Vec2{ .x = w, .y = 0 },
                    Viewport.Vec2{ .x = w, .y = h },
                    Viewport.Vec2{ .x = 0, .y = h },
                };
                try Viewport.blitPixels(viewport, corners, std.mem.sliceAsBytes(mandel_pixels), mandel_pixels_width, mandel_pixels_height);
            }

            if (show_dev_ui) {
                var drawList = Imgui.GetForegroundDrawList().?;
                for (touch_state.current[0..touch_state.fingers]) |s| {
                    Imgui.DrawList.AddCircleExt(drawList, Imgui.Vec2{ .x = s.pos.x * w, .y = s.pos.y * h }, 40, 0xFFFF0000, 8, 3);
                }
                for (touch_state.initial[0..touch_state.fingers]) |s| {
                    Imgui.DrawList.AddCircleExt(drawList, Imgui.Vec2{ .x = s.pos.x * w, .y = s.pos.y * h }, 30, 0xFFAA8833, 8, 3);
                }
                if (mouse_state.current) |s| {
                    Imgui.DrawList.AddRectExt(drawList, Imgui.Vec2{ .x = mouse_state.initial.pos.x * w, .y = mouse_state.initial.pos.y * h }, Imgui.Vec2{ .x = s.pos.x * w, .y = s.pos.y * h }, 0xFFAA8833, 0, .{}, 3);
                }
            }
        }

        try Viewport.endFrame(viewport);
    }

    if (mandel_compute_state.status == .computing) {
        mandel_compute_state.interrupt = true;
        await mandel_compute_state.callframe;
    }
}
