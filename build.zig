const builtin = @import("builtin");
const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const windows = b.option(bool, "windows", "compile windows build") orelse false;
    const use_bundled_deps = b.option(bool, "bundled-deps", "use bundled deps (default for windows build)") orelse windows;

    var target = b.standardTargetOptions(.{});
    if (windows)
        target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        };

    const exe = b.addExecutable("mandelbrot-explorer", "src/main.zig");

    if (use_bundled_deps) {
        exe.addSystemIncludeDir("deps/VulkanSDK/include");
        exe.addSystemIncludeDir("deps/SDL2-x86_64-w64-mingw32/include");
        exe.addLibPath("deps/SDL2-x86_64-w64-mingw32/lib");
        exe.addLibPath("deps/VulkanSDK/lib"); // renamming vulkan-1.lib to libvulkan.a appears to work...
    }

    exe.addIncludeDir("src/");
    exe.addIncludeDir("deps/imgui/");
    exe.addCSourceFile("deps/imgui/cimgui.cpp", &[_][]const u8{}); // "-D_DEBUG"
    exe.addCSourceFile("src/imgui_impl_main.cpp", &[_][]const u8{});
    exe.addCSourceFile("src/imgui_impl_sdl.cpp", &[_][]const u8{});
    exe.addCSourceFile("deps/imgui//imgui.cpp", &[_][]const u8{});
    exe.addCSourceFile("deps/imgui//imgui_draw.cpp", &[_][]const u8{});
    exe.addCSourceFile("deps/imgui//imgui_widgets.cpp", &[_][]const u8{});

    exe.linkSystemLibrary(if (windows) "SDL2.dll" else "SDL2");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("stdc++");
    exe.linkLibC();

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
