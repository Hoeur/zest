const std = @import("std");

const package: struct {
    name: @EnumLiteral(),
    version: []const u8,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
    fingerprint: u64,
} = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No target or optimize here, so projects importing zest choose their own.
    const zest = b.addModule("zest", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const self_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(self_tests).step);

    addExample(b, "demo", "Run the example tests", zest, target, optimize);
    addExample(b, "failures", "Show failure output (these tests fail on purpose)", zest, target, optimize);

    addUiTest(b, test_step, "src/ui/state.zig", target, optimize);
    addUiTest(b, test_step, "src/ui/layout.zig", target, optimize);
    if (target.result.os.tag == .windows) addUi(b, target, optimize);
    addCli(b, test_step, target, optimize);
}

fn addCli(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const options = b.addOptions();
    options.addOption([]const u8, "version", package.version);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "ztest", .root_module = root });
    b.installArtifact(exe);

    const run_cli = b.addRunArtifact(exe);
    run_cli.addPassthruArgs();
    b.step("run", "Run the ztest CLI").dependOn(&run_cli.step);

    const tests = b.addTest(.{ .root_module = root });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addUiTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addUi(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "ztest-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.subsystem = .windows;
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/ui/assets/ztest.rc") });
    for ([_][]const u8{ "user32", "gdi32", "gdiplus", "dwmapi", "shlwapi" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(exe);
    b.step("ui", "Run the desktop app").dependOn(&b.addRunArtifact(exe).step);
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    description: []const u8,
    zest: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zest", .module = zest }},
        }),
    });
    const run_example = b.addRunArtifact(exe);
    run_example.addPassthruArgs();
    b.step(name, description).dependOn(&run_example.step);
}
