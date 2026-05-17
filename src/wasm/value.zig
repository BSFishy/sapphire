const std = @import("std");

pub const FuncAddr = enum(usize) { _ };
pub const TableAddr = enum(usize) { _ };
pub const MemAddr = enum(usize) { _ };
pub const GlobalAddr = enum(usize) { _ };
pub const TagAddr = enum(usize) { _ };
pub const ElemAddr = enum(usize) { _ };
pub const DataAddr = enum(usize) { _ };
pub const StructAddr = enum(usize) { _ };
pub const ArrayAddr = enum(usize) { _ };
pub const ExnAddr = enum(usize) { _ };
pub const HostAddr = enum(usize) { _ };

pub const ExternAddr = union(enum) {
    func: FuncAddr,
    table: TableAddr,
    mem: MemAddr,
    global: GlobalAddr,
    tag: TagAddr,
};

pub const Value = union(enum) {
    // number types
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,

    // vector types
    // TODO: implement this correctly
    // v128: [4]u32,

    ref_i31: u31,
    ref_null,
    ref_struct: StructAddr,
    ref_array: ArrayAddr,
    ref_func: FuncAddr,
    ref_exn: ExnAddr,
    ref_host: HostAddr,
    ref_external: ExternAddr,
};
