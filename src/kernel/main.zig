const builtin = @import("builtin");
const std = @import("std");
const wasm = @import("wasm");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const memory = @import("memory.zig");
const Frame = memory.Frame;

pub const debug = struct {
    pub const SelfInfo = @import("self_info.zig");

    const debug_info_buffer_size = 8 * 1024 * 1024;

    const S = struct {
        var debug_info_buffer: [debug_info_buffer_size]u8 align(@alignOf(usize)) = undefined;
        var debug_info_fba: std.heap.FixedBufferAllocator = .init(&debug_info_buffer);
    };

    pub fn getDebugInfoAllocator() std.mem.Allocator {
        return S.debug_info_fba.allocator();
    }

    pub fn printLineFromFile(io: std.Io, writer: *std.Io.Writer, source_location: std.debug.SourceLocation) !void {
        _ = io;
        _ = writer;
        _ = source_location;
        return error.FileNotFound;
    }
};

pub const std_options_debug_io: std.Io = .failing;

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(5);
export var memory_map: limine.MemoryMapFeature linksection(".limine_requests") = .{
    .revision = 0,
};

pub export var executable_file: limine.ExecutableFileFeature linksection(".limine_requests") = .{
    .revision = 0,
};

pub export var executable_address: limine.ExecutableAddressFeature linksection(".limine_requests") = .{
    .revision = 0,
};

export var hhdm: extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64,
    response: ?*extern struct {
        revision: u64,
        offset: u64,
    } = null,
} linksection(".limine_requests") = .{
    .revision = 0,
};

fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            .loongarch64 => asm volatile ("idle 0"),
            else => unreachable,
        }
    }
}

fn qemuExit(code: u32) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const port: u16 = 0xf4;
            asm volatile ("outl %eax, %dx"
                :
                : [val] "{eax}" (code),
                  [port] "{dx}" (port),
            );
        },
        else => {},
    }

    hcf();
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, first_trace_addr: ?usize) noreturn {
    serial.log("\n!KERNEL PANIC!\n", .{});
    serial.log("{s}\n", .{msg});

    if (error_return_trace) |t| if (t.index > 0) {
        serial.log("error return context:\n", .{});
        std.debug.writeErrorReturnTrace(t, serial.TERMINAL)
            catch serial.log("failed to write error return trace\n", .{});
        serial.log("\nstack trace:\n", .{});
    };

    std.debug.writeCurrentStackTrace(.{
        .first_address = first_trace_addr orelse @returnAddress(),
        .allow_unsafe_unwind = true,
    }, serial.TERMINAL) catch serial.log("failed to write current stack trace\n", .{});

    qemuExit(0x10);
}

export fn _start() noreturn {
    serial.setupSerial();

    main() catch |err| std.debug.panic("failed to run kernel: {any}", .{err});
    hcf();
}

fn verifyEnvironment() !void {
    if (!base_revision.isValid()) {
        @panic("invalid limine boot");
    }

    if (base_revision.isSupported()) {
        serial.log("Invalid Limine revision. Please use Limine revision 5 or newer.\n", .{});
        return error.errors;
    }
}

fn setupMemory() !void {
    serial.log("HELLO {*}!\n", .{&main});

    const mm_response = memory_map.response orelse return error.errors;
    const entries = mm_response.entries[0..mm_response.entry_count];
    for (entries) |entry| {
        serial.log(" mm entry 0x{x}-0x{x}, {s}\n", .{ entry.base, entry.base + entry.length, @tagName(entry.type) });
    }

    const hhdm_response = hhdm.response orelse return error.errors;
    serial.log("offset: 0x{x}\n", .{hhdm_response.offset});

    var heap_allocator: memory.HeapAllocator = .initAll(entries, hhdm_response.offset);

    {
        const heap_ptr = heap_allocator.alloc(64) orelse return error.insufficientMemory;
        defer heap_allocator.free(heap_ptr);
        serial.log("heap alloc @ 0x{x}\n", .{@intFromPtr(heap_ptr)});
    }

    {
        const heap_ptr = heap_allocator.alloc(64) orelse return error.insufficientMemory;
        defer heap_allocator.free(heap_ptr);
        serial.log("heap alloc @ 0x{x}\n", .{@intFromPtr(heap_ptr)});

        {
            const heap_ptr2 = heap_allocator.alloc(64) orelse return error.insufficientMemory;
            defer heap_allocator.free(heap_ptr2);
            serial.log("heap alloc @ 0x{x}\n", .{@intFromPtr(heap_ptr2)});
        }
    }
}

fn main() !void {
    try verifyEnvironment();
    try setupMemory();

    serial.log("Result is {}\n", .{wasm.add(1, 2)});
    serial.log("Finished boot sequence. Ready to run some code!\n", .{});
    return error.invalid;
}
