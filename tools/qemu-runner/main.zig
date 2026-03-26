const std = @import("std");

const Dwarf = std.debug.Dwarf;

var got_sigint = std.atomic.Value(bool).init(false);

const PanicState = enum {
    searching,
    got_panic,
    collecting,
    done,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.args();
    _ = args.next();

    var kernel_path: ?[]const u8 = null;
    var qemu_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer qemu_args.deinit(gpa);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--kernel")) {
            kernel_path = args.next() orelse return usage();
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |qemu_arg| {
                try qemu_args.append(gpa, qemu_arg);
            }
            break;
        }
        return usage();
    }

    const kernel = kernel_path orelse return usage();
    if (qemu_args.items.len == 0) return usage();

    var child = std.process.Child.init(qemu_args.items, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    var state: PanicState = .searching;
    var panic_message: ?[]const u8 = null;
    var addresses: std.ArrayListUnmanaged(u64) = .empty;
    defer addresses.deinit(gpa);
    var symbolicated = false;

    var read_buffer: [4096]u8 = undefined;
    var pending_out: std.ArrayListUnmanaged(u8) = .empty;
    var pending_err: std.ArrayListUnmanaged(u8) = .empty;
    defer pending_out.deinit(gpa);
    defer pending_err.deinit(gpa);

    var stdout_open = true;
    var stderr_open = true;
    const stdout_fd = child.stdout.?.handle;
    const stderr_fd = child.stderr.?.handle;

    while (stdout_open or stderr_open) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = if (stdout_open) stdout_fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (stderr_open) stderr_fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = try std.posix.poll(&fds, -1);

        if (stdout_open and (fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = try std.posix.read(stdout_fd, &read_buffer);
            if (n == 0) {
                stdout_open = false;
            } else {
                try stdout.writeAll(read_buffer[0..n]);
                try processChunk(gpa, read_buffer[0..n], &pending_out, &state, &panic_message, &addresses);
                if (state == .done and !symbolicated and panic_message != null and addresses.items.len > 0) {
                    try stdout.writeAll("\nSymbolicated stack trace:\n");
                    try stdout.print("panic: {s}\n", .{panic_message.?});
                    try symbolicate(stdout, gpa, kernel, addresses.items);
                    symbolicated = true;
                    try waitForSigint();
                }
            }
        }

        if (stderr_open and (fds[1].revents & std.posix.POLL.IN) != 0) {
            const n = try std.posix.read(stderr_fd, &read_buffer);
            if (n == 0) {
                stderr_open = false;
            } else {
                try stdout.writeAll(read_buffer[0..n]);
                try processChunk(gpa, read_buffer[0..n], &pending_err, &state, &panic_message, &addresses);
                if (state == .done and !symbolicated and panic_message != null and addresses.items.len > 0) {
                    try stdout.writeAll("\nSymbolicated stack trace:\n");
                    try stdout.print("panic: {s}\n", .{panic_message.?});
                    try symbolicate(stdout, gpa, kernel, addresses.items);
                    symbolicated = true;
                    try waitForSigint();
                }
            }
        }
    }

    if (pending_out.items.len > 0) {
        try handleLine(gpa, pending_out.items, &state, &panic_message, &addresses);
    }
    if (pending_err.items.len > 0) {
        try handleLine(gpa, pending_err.items, &state, &panic_message, &addresses);
    }

    const term = try child.wait();
    const exit_code = exitCode(term);

    if (!symbolicated and panic_message != null and addresses.items.len > 0) {
        try stdout.writeAll("\nSymbolicated stack trace:\n");
        try stdout.print("panic: {s}\n", .{panic_message.?});
        try symbolicate(stdout, gpa, kernel, addresses.items);
        try waitForSigint();
    }

    if (panic_message) |msg| {
        gpa.free(msg);
    }

    std.process.exit(exit_code);
}

fn waitForSigint() !void {
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);

    while (!got_sigint.load(.seq_cst)) {
        _ = std.os.linux.pause();
    }

    std.process.exit(1);
}

fn handleSigint(_: c_int) callconv(.c) void {
    got_sigint.store(true, .seq_cst);
}

fn usage() !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: qemu-runner --kernel <kernel.elf> -- <qemu> [args...]\n");
    return error.InvalidArguments;
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => 128,
        .Stopped => 128,
        .Unknown => 1,
    };
}

fn processChunk(
    gpa: std.mem.Allocator,
    chunk: []const u8,
    pending: *std.ArrayListUnmanaged(u8),
    state: *PanicState,
    panic_message: *?[]const u8,
    addresses: *std.ArrayListUnmanaged(u64),
) !void {
    try pending.appendSlice(gpa, chunk);
    while (std.mem.indexOfScalar(u8, pending.items, '\n')) |idx| {
        const line = pending.items[0..idx];
        try handleLine(gpa, line, state, panic_message, addresses);
        const remaining = pending.items[idx + 1 ..];
        std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
        pending.items.len = remaining.len;
    }
}

fn handleLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    state: *PanicState,
    panic_message: *?[]const u8,
    addresses: *std.ArrayListUnmanaged(u64),
) !void {
    if (state.* == .done) return;

    const trimmed = std.mem.trim(u8, line, " \t\r");
    switch (state.*) {
        .searching => {
            if (std.mem.eql(u8, trimmed, "!KERNEL PANIC!")) {
                state.* = .got_panic;
            }
        },
        .got_panic => {
            panic_message.* = try gpa.dupe(u8, trimmed);
            state.* = .collecting;
        },
        .collecting => {
            const addr = parseAddress(trimmed) orelse {
                state.* = .done;
                return;
            };
            if (addr == 0) {
                state.* = .done;
                return;
            }
            try addresses.append(gpa, addr);
        },
        .done => {},
    }
}

fn parseAddress(line: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, "0x")) return null;
    return std.fmt.parseInt(u64, line, 0) catch null;
}

fn symbolicate(
    stdout: *std.Io.Writer,
    gpa: std.mem.Allocator,
    kernel_path: []const u8,
    addresses: []const u64,
) !void {
    var parent_sections: Dwarf.SectionArray = Dwarf.null_section_array;
    var elf_module = try Dwarf.ElfModule.loadPath(
        gpa,
        .{ .root_dir = .{ .path = null, .handle = std.fs.cwd() }, .sub_path = kernel_path },
        null,
        null,
        &parent_sections,
        null,
    );
    defer elf_module.deinit(gpa);

    for (addresses) |addr| {
        const symbol = elf_module.getSymbolAtAddress(gpa, addr) catch {
            try stdout.print("0x{x}: <no symbol>\n", .{addr});
            continue;
        };
        const src = symbol.source_location orelse std.debug.SourceLocation.invalid;
        const file_name = if (src.file_name.len == 0) "???" else src.file_name;
        const func_name = if (symbol.name.len == 0) "???" else symbol.name;
        try stdout.print(
            "0x{x}: {s}:{d}:{d} in {s}\n",
            .{ addr, file_name, src.line, src.column, func_name },
        );
    }
}
