const std = @import("std");
const builtin = @import("builtin");

/// A list of architectures supported by the kernel.
const Arch = enum {
    x86_64,
    aarch64,
    riscv64,
    loongarch64,

    /// Convert the architecture to an std.Target.Cpu.Arch.
    fn toStd(self: @This()) std.Target.Cpu.Arch {
        return switch (self) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .riscv64 => .riscv64,
            .loongarch64 => .loongarch64,
        };
    }
};

/// Create a target query for the given architecture.
/// The target needs to disable some features that are not supported
/// in a bare-metal environment, such as SSE or AVX on x86_64.
fn targetQueryForArch(arch: Arch) std.Target.Query {
    var query: std.Target.Query = .{
        .cpu_arch = arch.toStd(),
        .os_tag = .freestanding,
        .abi = .none,
    };

    switch (arch) {
        .x86_64 => {
            const Target = std.Target.x86;

            query.cpu_features_add = Target.featureSet(&.{ .popcnt, .soft_float });
            query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });
        },
        .aarch64 => {
            const Target = std.Target.aarch64;

            query.cpu_features_add = Target.featureSet(&.{});
            query.cpu_features_sub = Target.featureSet(&.{ .fp_armv8, .crypto, .neon });
        },
        .riscv64 => {
            const Target = std.Target.riscv;

            query.cpu_features_add = Target.featureSet(&.{});
            query.cpu_features_sub = Target.featureSet(&.{.d});
        },
        .loongarch64 => {},
    }

    return query;
}

pub fn build(b: *std.Build) void {
    const arch = b.option(Arch, "arch", "Architecture to build the kernel for") orelse .x86_64;
    const ranks = b.option(usize, "ranks", "Number of ranks in the frame allocator") orelse 10;

    const query = targetQueryForArch(arch);
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel_path = kernelModule(b, .{ .target = target, .optimize = optimize, .arch = arch, .ranks = ranks });
    const iso_path = iso(b, .{ .kernel_path = kernel_path, .arch = arch });
    qemu(b, .{ .arch = arch, .iso_path = iso_path, .kernel_path = kernel_path });

    myModuleWasm(b, .{ .optimize = optimize });
}

fn configureKernelModule(module: *std.Build.Module, arch: Arch) void {
    switch (arch) {
        .x86_64 => {
            module.red_zone = false;
            module.code_model = .kernel;
        },
        else => {},
    }
}

const KernelBuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    arch: Arch,
    ranks: usize,
};

fn kernelModule(b: *std.Build, opts: KernelBuildOptions) std.Build.LazyPath {
    const options = b.addOptions();
    options.addOption(usize, "ranks", opts.ranks);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    kernel_module.addOptions("options", options);
    configureKernelModule(kernel_module, opts.arch);

    const kernel = b.addExecutable(.{
        .name = "sapphire",
        .root_module = kernel_module,

        // seems there is a bug somewhere in the self-hosted zig compiler. using
        // llvm for now until we can get a build working with the zig compiler.
        .use_llvm = true,
    });

    kernel.setLinkerScript(b.path(b.fmt("linker-scripts/linker-{s}.lds", .{@tagName(opts.arch)})));

    b.installArtifact(kernel);
    return kernel.getEmittedBin();
}

fn myModuleWasm(b: *std.Build, opts: struct {
    optimize: std.builtin.OptimizeMode,
}) void {
    const wasm_query: std.Target.Query = .{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const wasm_target = b.resolveTargetQuery(wasm_query);

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/my-module/main.zig"),
        .target = wasm_target,
        .optimize = opts.optimize,
    });

    const wasm = b.addExecutable(.{
        .name = "my_module",
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.link_gc_sections = false;

    const install_wasm = b.addInstallFileWithDir(wasm.getEmittedBin(), .prefix, "share/my_module.wasm");
    b.getInstallStep().dependOn(&install_wasm.step);
}

fn iso(b: *std.Build, opts: struct {
    kernel_path: std.Build.LazyPath,
    arch: Arch,
    limine_share_path: ?[]const u8 = undefined,
}) std.Build.LazyPath {
    const limine_share_path = std.process.getEnvVarOwned(b.allocator, "LIMINE_SHARE_PATH") catch @panic("Invalid limine share path");
    defer b.allocator.free(limine_share_path);

    const limine_share = std.fs.openDirAbsolute(limine_share_path, .{}) catch unreachable;

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(opts.kernel_path, "boot/kernel.elf");
    _ = wf.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");

    const iso_name = b.fmt("sapphire-{s}.iso", .{@tagName(opts.arch)});
    const iso_path = switch (opts.arch) {
        .x86_64 => blk: {
            _ = copyFile(b, wf, limine_share, "limine-bios.sys", "boot/limine/limine-bios.sys");
            _ = copyFile(b, wf, limine_share, "limine-bios-cd.bin", "boot/limine/limine-bios-cd.bin");
            _ = copyFile(b, wf, limine_share, "limine-uefi-cd.bin", "boot/limine/limine-uefi-cd.bin");

            _ = copyFile(b, wf, limine_share, "BOOTX64.EFI", "EFI/BOOT/BOOTX64.EFI");
            _ = copyFile(b, wf, limine_share, "BOOTIA32.EFI", "EFI/BOOT/BOOTIA32.EFI");

            const xorriso = b.addSystemCommand(&.{"xorriso"});
            xorriso.addArgs(&.{
                "-as",           "mkisofs",                        "-R",             "-r",               "-J",                       "-b",              "boot/limine/limine-bios-cd.bin",
                "-no-emul-boot", "-boot-load-size",                "4",              "-boot-info-table", "-hfsplus",                 "-apm-block-size", "2048",
                "--efi-boot",    "boot/limine/limine-uefi-cd.bin", "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
            });
            xorriso.addDirectoryArg(wf.getDirectory());
            xorriso.addArg("-o");
            break :blk xorriso.addOutputFileArg(iso_name);
        },
        else => blk: {
            const boot_efi = switch (opts.arch) {
                .aarch64 => "BOOTAA64.EFI",
                .riscv64 => "BOOTRISCV64.EFI",
                .loongarch64 => "BOOTLOONGARCH64.EFI",
                else => unreachable,
            };

            _ = copyFile(b, wf, limine_share, "limine-uefi-cd.bin", "boot/limine/limine-uefi-cd.bin");
            _ = copyFile(b, wf, limine_share, boot_efi, b.fmt("EFI/BOOT/{s}", .{boot_efi}));

            const xorriso = b.addSystemCommand(&.{"xorriso"});
            xorriso.addArgs(&.{
                "-as",        "mkisofs",                        "-R",             "-r",               "-J",
                "--efi-boot", "boot/limine/limine-uefi-cd.bin", "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
            });
            xorriso.addDirectoryArg(wf.getDirectory());
            xorriso.addArg("-o");
            break :blk xorriso.addOutputFileArg(iso_name);
        },
    };

    const limine = b.addSystemCommand(&.{"limine"});
    limine.addArgs(&.{ "bios-install", "--quiet" });
    limine.addFileArg(iso_path);

    var iso_run = b.step("iso", "Build a bootable iso");
    var install_step = b.addInstallFileWithDir(iso_path, .prefix, b.fmt("share/sapphire-{s}.iso", .{@tagName(opts.arch)}));
    install_step.step.dependOn(&limine.step);
    iso_run.dependOn(&install_step.step);

    return iso_path;
}

fn copyFile(b: *std.Build, wf: *std.Build.Step.WriteFile, dir: std.fs.Dir, file: []const u8, sub_path: []const u8) std.Build.LazyPath {
    const file_contents = dir.readFileAlloc(b.allocator, file, 1024 * 1024 * 1024) catch unreachable;
    defer b.allocator.free(file_contents);

    return wf.add(sub_path, file_contents);
}

fn qemu(b: *std.Build, opts: struct {
    arch: Arch,
    iso_path: std.Build.LazyPath,
    kernel_path: std.Build.LazyPath,
}) void {
    const qemu_step = b.step("qemu", "Run sapphire in a qemu virtual machine");
    const qemu_command = switch (opts.arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        .loongarch64 => "qemu-system-loongarch64",
    };

    const machine = switch (opts.arch) {
        .x86_64 => "q35",
        .aarch64, .riscv64, .loongarch64 => "virt",
    };

    const cpu = if (opts.arch.toStd() == builtin.cpu.arch)
        "max"
    else switch (opts.arch) {
        .x86_64 => "qemu64",
        .aarch64 => "cortex-a72",
        .riscv64 => "rv64",
        .loongarch64 => "la464",
    };

    const panic_runner = b.addExecutable(.{
        .name = "qemu-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qemu-runner/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const run = b.addRunArtifact(panic_runner);
    run.addArg("--kernel");
    run.addFileArg(opts.kernel_path);
    run.addArg("--");
    run.addArg(qemu_command);
    run.addArgs(&.{ "-M", machine, "-cpu", cpu, "-serial", "stdio", "-display", "none", "-boot", "d", "-d", "guest_errors", "-no-reboot" });
    if (opts.arch == .x86_64) {
        run.addArgs(&.{ "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04" });
    }

    run.addArg("-cdrom");
    run.addFileArg(opts.iso_path);

    qemu_step.dependOn(&run.step);
}
