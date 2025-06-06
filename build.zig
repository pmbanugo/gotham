const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Build options for uSockets
    const use_ssl = b.option(bool, "ssl", "Enable SSL support") orelse false;
    const ssl_backend = b.option(enum { openssl, wolfssl }, "ssl-backend", "SSL backend to use") orelse .openssl;
    const use_io_uring = b.option(bool, "io-uring", "Enable io_uring support (Linux only)") orelse false;

    // Get uSockets dependency
    const usockets_dep = b.dependency("usockets", .{});

    // Create uSockets static library
    const usockets_lib = b.addStaticLibrary(.{
        .name = "usockets",
        .target = target,
        .optimize = optimize,
    });

    // Add C source files
    usockets_lib.addCSourceFiles(.{
        .root = usockets_dep.path(""),
        .files = &.{
            "src/bsd.c",
            "src/context.c",
            "src/loop.c",
            "src/quic.c",
            "src/socket.c",
            "src/udp.c",
            "src/eventing/epoll_kqueue.c",
            "src/eventing/gcd.c",
            "src/eventing/libuv.c",
            "src/crypto/openssl.c",
            // "src/crypto/wolfssl.c",
            "src/io_uring/io_loop.c",
            "src/io_uring/io_socket.c",
            "src/io_uring/io_context.c",
        },
        .flags = &.{
            "-std=c11",
            // "-fno-sanitize=address",
        },
    });

    // Add C++ source files separately
    usockets_lib.addCSourceFiles(.{
        .root = usockets_dep.path(""),
        .files = &.{
            "src/crypto/sni_tree.cpp",
        },
        .flags = &.{
            // "-fno-sanitize=address",
        },
    });

    // Platform-specific event loop selection
    switch (target.result.os.tag) {
        .linux => {
            if (use_io_uring) {
                usockets_lib.root_module.addCMacro("LIBUS_USE_IO_URING", "1");
                usockets_lib.linkSystemLibrary("uring");
            } else {
                usockets_lib.root_module.addCMacro("LIBUS_USE_EPOLL", "1");
            }
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            usockets_lib.root_module.addCMacro("LIBUS_USE_KQUEUE", "1");
        },
        else => {
            usockets_lib.root_module.addCMacro("LIBUS_USE_EPOLL", "1");
        },
    }

    // SSL configuration
    if (use_ssl) {
        switch (ssl_backend) {
            .openssl => {
                usockets_lib.root_module.addCMacro("LIBUS_USE_OPENSSL", "1");
                usockets_lib.linkSystemLibrary("ssl");
                usockets_lib.linkSystemLibrary("crypto");
            },
            .wolfssl => {
                usockets_lib.root_module.addCMacro("LIBUS_USE_WOLFSSL", "1");
                usockets_lib.linkSystemLibrary("wolfssl");
            },
        }
        // Need C++ for SSL support (as per Makefile)
        usockets_lib.linkLibCpp();
    } else {
        usockets_lib.root_module.addCMacro("LIBUS_NO_SSL", "1");
    }

    // Add include directory
    usockets_lib.addIncludePath(usockets_dep.path("src"));

    // Link standard libraries
    usockets_lib.linkLibC();
    if (target.result.os.tag != .windows) {
        usockets_lib.linkSystemLibrary("pthread");
    }

    // Install the uSockets library
    b.installArtifact(usockets_lib);

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("gotham_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "gotham",
        .root_module = lib_mod,
    });

    // Link uSockets to the library
    lib.linkLibrary(usockets_lib);
    lib.addIncludePath(usockets_dep.path("src"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "gotham",
        .root_module = exe_mod,
    });

    // Link uSockets to the executable
    exe.linkLibrary(usockets_lib);
    exe.addIncludePath(usockets_dep.path("src"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
