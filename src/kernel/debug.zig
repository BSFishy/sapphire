const std = @import("std");
const serial = @import("serial.zig");

pub fn printStackTrace(ra: ?usize) void {
    var it = std.debug.StackIterator.init(ra, null);
    while (it.next()) |return_address| {
        serial.log("0x{x}\n", .{return_address});
    }
}
