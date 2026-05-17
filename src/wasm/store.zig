const std = @import("std");
const Module = @import("module.zig");
const wasm_types = @import("types.zig");
const value_types = @import("value.zig");
const Value = value_types.Value;

const Store = @This();

arena: std.heap.ArenaAllocator,

modules: std.ArrayListUnmanaged(*ModuleInst) = .empty,

tags: std.ArrayListUnmanaged(TagInst) = .empty,
globals: std.ArrayListUnmanaged(GlobalInst) = .empty,
mems: std.ArrayListUnmanaged(MemInst) = .empty,
tables: std.ArrayListUnmanaged(TableInst) = .empty,
funcs: std.ArrayListUnmanaged(FuncInst) = .empty,
datas: std.ArrayListUnmanaged(DataInst) = .empty,
elems: std.ArrayListUnmanaged(ElemInst) = .empty,

pub fn init(alloc: std.mem.Allocator) Store {
    return .{
        .arena = .init(alloc),
    };
}

pub fn deinit(self: *Store) void {
    self.arena.deinit();
}

fn allocator(self: *Store) std.mem.Allocator {
    return self.arena.allocator();
}

pub const ExportInst = struct {
    name: []const u8,
    addr: value_types.ExternAddr,
};

pub const ModuleInst = struct {
    types: []const wasm_types.RecursiveType,

    tags: []const value_types.TagAddr,
    globals: []const value_types.GlobalAddr,
    mems: []const value_types.MemAddr,
    tables: []const value_types.TableAddr,
    funcs: []const value_types.FuncAddr,
    datas: []const value_types.DataAddr,
    elems: []const value_types.ElemAddr,

    exports: []const ExportInst,

    pub fn invoke(self: *const ModuleInst, store: *Store, name: []const u8, args: []const Value) ![]Value {
        for (self.exports) |export_inst| {
            if (!std.mem.eql(u8, export_inst.name, name)) continue;

            switch (export_inst.addr) {
                .func => |func_addr| return store.invoke(func_addr, args),
                else => return error.ExportNotFunc,
            }
        }

        return error.ExportNotFound;
    }
};

pub const TagInst = struct {
    tag_type: wasm_types.TagType,
};

pub const GlobalInst = struct {
    global_type: wasm_types.GlobalType,
    value: Value,
};

pub const MemInst = struct {
    mem_type: wasm_types.Limits,
    bytes: []u8,
};

pub const TableInst = struct {
    table_type: wasm_types.TableType,
    refs: []Value,
};

pub const FuncInst = struct {
    module: *const ModuleInst,
    type_idx: u32,
    code: *const Module.Code,
};

pub const DataInst = struct {
    bytes: []u8,
};

pub const ElemInst = struct {
    refs: []Value,
};

const Frame = struct {
    module: *const ModuleInst,
    locals: []Value,
};

fn allocModule(self: *Store, inst: ModuleInst) !*ModuleInst {
    const module_inst = try self.allocator().create(ModuleInst);
    module_inst.* = inst;
    try self.modules.append(self.allocator(), module_inst);
    return module_inst;
}

fn allocTag(self: *Store, inst: TagInst) !value_types.TagAddr {
    try self.tags.append(self.allocator(), inst);
    return @enumFromInt(self.tags.items.len - 1);
}

fn allocGlobal(self: *Store, inst: GlobalInst) !value_types.GlobalAddr {
    try self.globals.append(self.allocator(), inst);
    return @enumFromInt(self.globals.items.len - 1);
}

fn allocMem(self: *Store, inst: MemInst) !value_types.MemAddr {
    try self.mems.append(self.allocator(), inst);
    return @enumFromInt(self.mems.items.len - 1);
}

fn allocTable(self: *Store, inst: TableInst) !value_types.TableAddr {
    try self.tables.append(self.allocator(), inst);
    return @enumFromInt(self.tables.items.len - 1);
}

fn allocFunc(self: *Store, inst: FuncInst) !value_types.FuncAddr {
    try self.funcs.append(self.allocator(), inst);
    return @enumFromInt(self.funcs.items.len - 1);
}

fn allocData(self: *Store, inst: DataInst) !value_types.DataAddr {
    try self.datas.append(self.allocator(), inst);
    return @enumFromInt(self.datas.items.len - 1);
}

fn allocElem(self: *Store, inst: ElemInst) !value_types.ElemAddr {
    try self.elems.append(self.allocator(), inst);
    return @enumFromInt(self.elems.items.len - 1);
}

// TODO: this should likely dupe any ptrs/slices from the module but whatever
// poc mode or whatever
pub fn instantiate(self: *Store, module: *const Module) !ModuleInst {
    if (module.imports.count() != 0) return error.ImportsUnsupported;
    if (module.functions.items.len != module.codes.items.len) return error.InvalidModule;

    const gpa = self.allocator();

    var tags: std.ArrayListUnmanaged(value_types.TagAddr) = .empty;
    for (module.tags.items) |tag_type| {
        tags.append(gpa, try self.allocTag(.{ .tag_type = tag_type })) catch unreachable;
    }

    const globals: std.ArrayListUnmanaged(value_types.GlobalAddr) = .empty;
    var mems: std.ArrayListUnmanaged(value_types.MemAddr) = .empty;
    const tables: std.ArrayListUnmanaged(value_types.TableAddr) = .empty;
    var funcs: std.ArrayListUnmanaged(value_types.FuncAddr) = .empty;
    const datas: std.ArrayListUnmanaged(value_types.DataAddr) = .empty;
    const elems: std.ArrayListUnmanaged(value_types.ElemAddr) = .empty;

    for (module.memories.items) |memory_type| {
        const min_pages: usize = switch (memory_type.flag) {
            .i32, .i32_with_maximum, .i64, .i64_with_maximum => @intCast(memory_type.minimum),
        };
        const bytes = gpa.alloc(u8, min_pages * 65536) catch unreachable;
        @memset(bytes, 0);
        mems.append(gpa, try self.allocMem(.{ .mem_type = memory_type, .bytes = bytes })) catch unreachable;
    }

    const module_inst_ptr = try self.allocModule(.{
        .types = module.types.items,
        .tags = tags.items,
        .globals = globals.items,
        .mems = mems.items,
        .tables = tables.items,
        .funcs = funcs.items,
        .datas = datas.items,
        .elems = elems.items,
        .exports = &.{},
    });

    for (module.functions.items, module.codes.items) |type_idx, *code| {
        funcs.append(gpa, try self.allocFunc(.{
            .module = module_inst_ptr,
            .type_idx = type_idx,
            .code = code,
        })) catch unreachable;
    }

    var exports: std.ArrayListUnmanaged(ExportInst) = .empty;
    for (module.exports.items) |export_inst| {
        exports.append(gpa, .{
            .name = export_inst.name,
            .addr = try resolveExportAddr(export_inst, funcs.items, tables.items, mems.items, globals.items, tags.items),
        }) catch unreachable;
    }

    module_inst_ptr.* = .{
        .types = module.types.items,
        .tags = tags.items,
        .globals = globals.items,
        .mems = mems.items,
        .tables = tables.items,
        .funcs = funcs.items,
        .datas = datas.items,
        .elems = elems.items,
        .exports = exports.items,
    };

    return module_inst_ptr.*;
}

fn resolveExportAddr(
    export_inst: Module.Export,
    funcs: []const value_types.FuncAddr,
    tables: []const value_types.TableAddr,
    mems: []const value_types.MemAddr,
    globals: []const value_types.GlobalAddr,
    tags: []const value_types.TagAddr,
) !value_types.ExternAddr {
    return switch (export_inst.desc) {
        .func => |idx| blk: {
            if (idx >= funcs.len) return error.InvalidModule;
            break :blk .{ .func = funcs[idx] };
        },
        .table => |idx| blk: {
            if (idx >= tables.len) return error.InvalidModule;
            break :blk .{ .table = tables[idx] };
        },
        .memory => |idx| blk: {
            if (idx >= mems.len) return error.InvalidModule;
            break :blk .{ .mem = mems[idx] };
        },
        .global => |idx| blk: {
            if (idx >= globals.len) return error.InvalidModule;
            break :blk .{ .global = globals[idx] };
        },
        .tag => |idx| blk: {
            if (idx >= tags.len) return error.InvalidModule;
            break :blk .{ .tag = tags[idx] };
        },
    };
}

fn defaultValueForType(val_type: wasm_types.ValType) !Value {
    return switch (val_type) {
        .num => |num| switch (num) {
            .i32 => .{ .i32 = 0 },
            .i64 => .{ .i64 = 0 },
            .f32 => .{ .f32 = 0 },
            .f64 => .{ .f64 = 0 },
        },
        .ref => .ref_null,
        .vec => return error.Unimplemented,
    };
}

fn valueMatchesType(value: Value, val_type: wasm_types.ValType) bool {
    return switch (val_type) {
        .num => |num| switch (num) {
            .i32 => value == .i32,
            .i64 => value == .i64,
            .f32 => value == .f32,
            .f64 => value == .f64,
        },
        .ref => switch (value) {
            .ref_null, .ref_i31, .ref_struct, .ref_array, .ref_func, .ref_exn, .ref_host, .ref_external => true,
            else => false,
        },
        .vec => false,
    };
}

fn popValue(stack: *std.ArrayListUnmanaged(Value)) !Value {
    return stack.pop() orelse error.StackUnderflow;
}

fn popI32(stack: *std.ArrayListUnmanaged(Value)) !i32 {
    const value = try popValue(stack);
    return switch (value) {
        .i32 => |i| i,
        else => error.TypeMismatch,
    };
}

fn invoke(self: *Store, func_addr: value_types.FuncAddr, args: []const Value) ![]Value {
    const gpa = self.allocator();
    const func = self.funcs.items[@intFromEnum(func_addr)];
    const func_type = try wasm_types.resolveFuncType(func.module.types, func.type_idx);

    if (args.len != func_type.params.len) return error.InvalidArgs;
    for (args, func_type.params) |arg, param| {
        if (!valueMatchesType(arg, param)) return error.TypeMismatch;
    }

    const local_count = args.len + func.code.locals.items.len;
    const locals = gpa.alloc(Value, local_count) catch unreachable;
    @memcpy(locals[0..args.len], args);
    for (func.code.locals.items, args.len..) |val_type, i| {
        locals[i] = try defaultValueForType(val_type);
    }

    const frame: Frame = .{
        .module = func.module,
        .locals = locals,
    };
    _ = frame;

    var stack: std.ArrayListUnmanaged(Value) = .empty;

    for (func.code.expr.instructions.items) |instr| {
        switch (instr) {
            .local_get => |idx| {
                if (idx >= locals.len) return error.InvalidLocalIdx;
                stack.append(gpa, locals[idx]) catch unreachable;
            },
            .i32_add => {
                const rhs = try popI32(&stack);
                const lhs = try popI32(&stack);
                stack.append(gpa, .{ .i32 = lhs + rhs }) catch unreachable;
            },
            else => {
                std.debug.print("unimplemented instr: {s}\n", .{@tagName(instr)});
                return error.UnimplementedInstruction;
            },
        }
    }

    if (stack.items.len != func_type.results.len) return error.InvalidResultCount;
    for (stack.items, func_type.results) |result, expected| {
        if (!valueMatchesType(result, expected)) return error.TypeMismatch;
    }

    const results = gpa.alloc(Value, stack.items.len) catch unreachable;
    @memcpy(results, stack.items);
    return results;
}
