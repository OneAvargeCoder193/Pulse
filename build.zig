const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    target = b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = target.result.os.tag,
        .abi = .gnu,
    });

    const exe = b.addExecutable(.{
        .name = "pulse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    exe.use_lld = true;
    exe.use_llvm = true;

    exe.root_module.addIncludePath(.{.cwd_relative = "LLVM/include"});
    exe.root_module.addLibraryPath(.{.cwd_relative = "LLVM/bin"});
    
    exe.root_module.linkSystemLibrary("LLVM-C", .{});

    exe.root_module.addImport("args", b.dependency("args", .{
        .target = target,
        .optimize = optimize
    }).module("args"));

    b.installBinFile("LLVM/bin/LLVM-C.dll", "LLVM-C.dll");
    
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if(b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
