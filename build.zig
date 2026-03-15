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
    qemu(b, .{ .arch = arch, .iso_path = iso_path });
}

fn kernelModule(b: *std.Build, opts: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    arch: Arch,
    ranks: usize,
}) std.Build.LazyPath {
    const sapphire_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const options = b.addOptions();
    options.addOption(usize, "ranks", opts.ranks);
    sapphire_module.addOptions("options", options);

    switch (opts.arch) {
        .x86_64 => {
            sapphire_module.red_zone = false;
            sapphire_module.code_model = .kernel;
        },
        else => {},
    }

    const sapphire = b.addExecutable(.{
        .name = "sapphire",
        .root_module = sapphire_module,

        // seems there is a bug somewhere in the self-hosted zig compiler. using
        // llvm for now until we can get a build working with the zig compiler.
        .use_llvm = true,
    });

    sapphire.setLinkerScript(b.path(b.fmt("linker-scripts/linker-{s}.lds", .{@tagName(opts.arch)})));
    b.installArtifact(sapphire);

    return sapphire.getEmittedBin();
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
                "-as", "mkisofs", "-R", "-r", "-J", "-b", "boot/limine/limine-bios-cd.bin",
                "-no-emul-boot", "-boot-load-size", "4", "-boot-info-table", "-hfsplus",
                "-apm-block-size", "2048", "--efi-boot", "boot/limine/limine-uefi-cd.bin",
                "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
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
                "-as", "mkisofs", "-R", "-r", "-J",
                "--efi-boot", "boot/limine/limine-uefi-cd.bin",
                "-efi-boot-part", "--efi-boot-image", "--protective-msdos-label",
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
}) void {
    const qemu_step = b.step("qemu", "Run sapphire in a qemu virtual machine");
    const qemu_command = b.addSystemCommand(&.{switch (opts.arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        .loongarch64 => "qemu-system-loongarch64",
    }});

    const machine = switch (opts.arch) {
        .x86_64 => "q35",
        .aarch64,
        .riscv64,
        .loongarch64 => "virt",
    };


    const cpu = if (opts.arch.toStd() == builtin.cpu.arch)
            "max"
        else
            switch (opts.arch) {
                .x86_64 => "qemu64",
                .aarch64 => "cortex-a72",
                .riscv64 => "rv64",
                .loongarch64 => "la464",
            };

    qemu_command.addArgs(&.{
        "-M", machine,
        "-cpu", cpu,
        "-serial", "stdio",
        "-display", "none",
        "-boot", "d",
        "-d", "guest_errors",
        "-no-reboot"
    });

    qemu_command.addArg("-cdrom");
    qemu_command.addFileArg(opts.iso_path);

    qemu_step.dependOn(&qemu_command.step);
}
