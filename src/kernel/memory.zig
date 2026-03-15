const std = @import("std");

const Flag = enum(usize) {
    reserved,
    allocated,

    // NOTE: keep this at the end
    max,

    fn value(self: Flag) usize {
        return @intFromEnum(self);
    }
};

pub const Page = struct {
    order: u8,
    flags: std.StaticBitSet(Flag.max.value()),
    address: usize,

    pub fn allocate(self: *Page) void {
        self.flags.set(Flag.allocated.value());
    }

    pub fn deallocate(self: *Page) void {
        self.flags.unset(Flag.allocated.value());
    }

    pub fn isAllocated(self: *Page) bool {
        self.flags.isSet(Flag.allocated.value());
    }
};
