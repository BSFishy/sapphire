const std = @import("std");
const wasm = @import("wasm");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    var args = init.minimal.args.iterateAllocator(init.gpa) catch unreachable;
    _ = args.next();
    const input_file_name = args.next() orelse {
        std.debug.print("Please specify a wasm module\n", .{});
        return error.invalidArgs;
    };

    const cwd = std.Io.Dir.cwd();
    const contents = cwd.readFileAlloc(init.io, input_file_name, init.arena.allocator(), .unlimited)
        catch std.debug.panic("reading input wasm file {s}", .{input_file_name});

    const sparse_module = wasm.SparseModule.decode(gpa, contents) catch |err| {
        std.debug.print("Failed to read wasm module: {any}\n", .{err});
        return err;
    };

    var store: wasm.Store = .init(gpa);
    const module_inst = try store.instantiate(&sparse_module);
    const results = try module_inst.invoke(&store, "add", &.{
        .{ .i32 = 2 },
        .{ .i32 = 3 },
    });

    for (results, 0..) |value, i| {
        std.debug.print("add result {}: {any}\n", .{i, value});
    }

    std.debug.print("Hello world! {}\n", .{wasm.add(1, 2)});
}
