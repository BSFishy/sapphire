const std = @import("std");
const wasm = @import("wasm");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.argsWithAllocator(gpa) catch std.debug.panic("reading arguments", .{});
    _ = args.next();
    const input_file_name = args.next() orelse {
        std.debug.print("Please specify a wasm module\n", .{});
        return error.invalidArgs;
    };

    const cwd = std.fs.cwd();
    const contents = cwd.readFileAlloc(gpa, input_file_name, 2 * 1024 * 1024)
        catch std.debug.panic("reading input wasm file {s}", .{input_file_name});

    const sparse_module = wasm.SparseModule.decode(gpa, contents) catch |err| {
        std.debug.print("Failed to read wasm module: {any}\n", .{err});
        return err;
    };

    var iterator = sparse_module.custom_sections.iterator();
    while (iterator.next()) |section| {
        const key = section.key_ptr.*;
        const value = section.value_ptr.*;

        std.debug.print("custom section {s}: {}\n", .{key, value.len});
    }

    std.debug.print("Hello world! {}\n", .{wasm.add(1, 2)});
}
