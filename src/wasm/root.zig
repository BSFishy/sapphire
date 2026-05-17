const std = @import("std");
pub const SparseModule = @import("module.zig");
pub const Store = @import("store.zig");

pub fn add(a: u32, b: u32) u32 {
    return a + b;
}
