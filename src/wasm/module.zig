const std = @import("std");
const wasm_types = @import("types.zig");
const Expr = @import("instructions.zig").Expr;

const Module = @This();

// TODO: This is a pretty dumb implementation. The proper std.Io.Reader
// interface should be preferred, allowing error.ReadFailed instead of expecting
// the reader to be a std.Io.Reader.fixed.
// TODO: The decoder should also operate in a single pass, decoding, validating,
// then instantiating in one operation. The operation should be to take a reader
// and produce an instantiated module, ready to be executed.
// TODO: List lengths should be used as a rough gauge for module size. More
// trusted modules should be allowed more elements so as to not starve CPU.
// Otherwise a malicious actor may upload a massive module that starves the CPU
// of a server.
pub const ImportIdentifier = struct {
    namespace: []const u8,
    identifier: []const u8,
};

const ImportMap = std.HashMapUnmanaged(
    ImportIdentifier,
    wasm_types.ExternType,
    struct {
        const Context = @This();
        pub const hash = struct {
            fn hash(ctx: Context, key: ImportIdentifier) u64 {
                _ = ctx;
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key.namespace);
                hasher.update(key.identifier);
                return hasher.final();
            }
        }.hash;
        pub const eql = std.hash_map.getAutoEqlFn(ImportIdentifier, Context);
    },
    std.hash_map.default_max_load_percentage
);

pub const Table = struct {
    table_type: wasm_types.TableType,
    expr: Expr,
};

pub const Global = struct {
    global_type: wasm_types.GlobalType,
    expr: Expr,
};

pub const Export = struct {
    name: []const u8,
    desc: union(enum) {
        func: u32,
        table: u32,
        memory: u32,
        global: u32,
        tag: u32,
    },
};

pub const Elem = struct {
    type_info: union(enum) {
        elemkind_funcref,
        ref_type: wasm_types.RefType,
    },
    init: union(enum) {
        func_indices: std.ArrayListUnmanaged(u32),
        exprs: std.ArrayListUnmanaged(Expr),
    },
    mode: union(enum) {
        passive,
        declare,
        active: struct {
            table_idx: u32,
            offset: Expr,
        },
    },
};

pub const Code = struct {
    locals: std.ArrayListUnmanaged(wasm_types.ValType),
    expr: Expr,
};

pub const Data = struct {
    bytes: []const u8,
    mode: union(enum) {
        passive,
        active: struct {
            mem_idx: u32,
            offset: Expr,
        },
    },
};

arena: std.heap.ArenaAllocator,

custom_sections: std.StringHashMapUnmanaged([]const u8) = .empty,
types: std.ArrayListUnmanaged(wasm_types.RecursiveType) = .empty,
imports: ImportMap = .empty,
functions: std.ArrayListUnmanaged(u32) = .empty,
tables: std.ArrayListUnmanaged(Table) = .empty,
memories: std.ArrayListUnmanaged(wasm_types.Limits) = .empty,
tags: std.ArrayListUnmanaged(wasm_types.TagType) = .empty,
globals: std.ArrayListUnmanaged(Global) = .empty,
exports: std.ArrayListUnmanaged(Export) = .empty,
start: ?u32 = null,
elements: std.ArrayListUnmanaged(Elem) = .empty,
data_count: ?u32 = null,
codes: std.ArrayListUnmanaged(Code) = .empty,
data_segments: std.ArrayListUnmanaged(Data) = .empty,

pub fn deinit(self: *const Module) void {
    self.arena.deinit();
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Module {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_allocator.deinit();

    if (data.len < 4) return error.invalidMagic;
    if (data[0] != 0x00) return error.invalidMagic;
    if (data[1] != 0x61) return error.invalidMagic;
    if (data[2] != 0x73) return error.invalidMagic;
    if (data[3] != 0x6D) return error.invalidMagic;

    if (data.len < 8) return error.invalidVersion;
    if (data[4] != 0x01) return error.invalidVersion;
    if (data[5] != 0x00) return error.invalidVersion;
    if (data[6] != 0x00) return error.invalidVersion;
    if (data[7] != 0x00) return error.invalidVersion;

    var reader = std.Io.Reader.fixed(data[8..]);
    var module: Module = .{ .arena = arena_allocator };

    try module.decodeCustomSec(&reader);
    try module.decodeTypeSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeImportSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeFuncSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeTableSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeMemorySec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeTagSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeGlobalSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeExportSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeStartSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeElemSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeDataCountSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeCodeSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);
    try module.decodeDataSec(&reader);
    // TODO: yield here

    try module.decodeCustomSec(&reader);

    const remainingBytes = reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidModule;

    return module;
}

fn readSectionHeader(reader: *std.Io.Reader, expected_id: u8) !?u32 {
    const section_id = reader.peekByte()
        catch |err| switch (err) {
            error.EndOfStream => return null,
            else => unreachable,
        };

    if (section_id != expected_id) return null;
    _ = reader.takeByte() catch unreachable;

    return reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };
}

fn readName(reader: *std.Io.Reader) ![]const u8 {
    const len = reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.Overflow => return error.invalidName,
            else => unreachable,
        };

    const data = reader.take(len)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidName,
            else => unreachable,
        };

    if (!std.unicode.utf8ValidateSlice(data)) return error.invalidName;
    return data;
}

fn decodeCustomSec(self: *Module, reader: *std.Io.Reader) !void {
    while (true) {
        const section_length = try readSectionHeader(reader, 0x00) orelse return;
        const data = reader.take(section_length)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidSection,
                else => unreachable,
            };

        var data_reader = std.Io.Reader.fixed(data);
        const name = readName(&data_reader)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidSection,
                else => return err,
            };

        const remaining = data_reader.discardRemaining() catch unreachable;
        const content = data[data.len - remaining ..];

        self.custom_sections.put(self.arena.allocator(), name, content) catch unreachable;
    }
}

fn decodeTypeSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x01) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    self.types.appendSlice(gpa, try wasm_types.RecursiveType.decode(gpa, data)) catch unreachable;
}

fn decodeImportSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x02) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const import_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidImportSection,
            else => unreachable,
        };

    for (0..import_count) |_| {
        const namespace = readName(&data_reader)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidImportSection,
                else => return err,
            };

        const identifier = readName(&data_reader)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidImportSection,
                else => return err,
            };

        const extern_type = try wasm_types.ExternType.decode(&data_reader);

        self.imports.put(gpa, .{ .namespace = namespace, .identifier = identifier }, extern_type) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidImportSection;
}

fn decodeFuncSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x03) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidFuncSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const func_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidFuncSection,
            else => unreachable,
        };

    for (0..func_count) |_| {
        const type_idx = data_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidFuncSection,
                else => unreachable,
            };

        self.functions.append(gpa, type_idx) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidFuncSection;
}

fn decodeTableSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x04) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidFuncSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const table_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidTableSection,
            else => unreachable,
        };

    for (0..table_count) |_| {
        const discriminator = data_reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidTableSection,
                else => unreachable,
            };

        if (discriminator == 0x40) {
            _ = data_reader.takeByte() catch unreachable;
            const check = data_reader.takeByte()
                catch |err| switch (err) {
                    error.EndOfStream => return error.invalidTableSection,
                    else => unreachable,
                };

            if (check != 0x00) return error.invalidTableSection;

            const table_type = try wasm_types.TableType.decode(&data_reader);
            const expr = try Expr.decode(gpa, &data_reader);

            self.tables.append(gpa, .{ .table_type = table_type, .expr = expr }) catch unreachable;
            continue;
        }

        const table_type = try wasm_types.TableType.decode(&data_reader);
        const ref_type = table_type.ref_type;
        const heap_type = ref_type.heap_type;
        self.tables.append(gpa, .{
            .table_type = table_type,
            .expr = .single(gpa, .{ .ref_null = heap_type }),
        }) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidFuncSection;
}

fn decodeMemorySec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x05) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const memory_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..memory_count) |_| {
        self.memories.append(gpa, try wasm_types.Limits.decode(&data_reader)) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeTagSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x0D) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const tag_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..tag_count) |_| {
        self.tags.append(gpa, try wasm_types.TagType.decode(&data_reader)) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeGlobalSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x06) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const global_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..global_count) |_| {
        const global_type = try wasm_types.GlobalType.decode(&data_reader);
        const expr = try Expr.decode(gpa, &data_reader);
        self.globals.append(gpa, .{ .global_type = global_type, .expr = expr }) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeExportSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x07) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const export_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..export_count) |_| {
        const name = readName(&data_reader)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidSection,
                else => return err,
            };

        const kind = data_reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidSection,
                else => unreachable,
            };

        const idx = data_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            };

        self.exports.append(gpa, .{
            .name = name,
            .desc = switch (kind) {
                0x00 => .{ .func = idx },
                0x01 => .{ .table = idx },
                0x02 => .{ .memory = idx },
                0x03 => .{ .global = idx },
                0x04 => .{ .tag = idx },
                else => return error.invalidSection,
            },
        }) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeStartSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x08) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    var data_reader = std.Io.Reader.fixed(data);
    self.start = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeElemSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x09) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const elem_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..elem_count) |_| {
        const flags = data_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            };

        const elem: Elem = switch (flags) {
            0 => blk: {
                const offset = try Expr.decode(gpa, &data_reader);
                break :blk .{
                    .type_info = .elemkind_funcref,
                    .init = .{ .func_indices = try decodeElemFuncIndexList(gpa, &data_reader) },
                    .mode = .{ .active = .{ .table_idx = 0, .offset = offset } },
                };
            },
            1 => blk: {
                try decodeElemKind(&data_reader);
                break :blk .{
                    .type_info = .elemkind_funcref,
                    .init = .{ .func_indices = try decodeElemFuncIndexList(gpa, &data_reader) },
                    .mode = .passive,
                };
            },
            2 => blk: {
                const table_idx = data_reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidSection,
                        else => unreachable,
                    };
                const offset = try Expr.decode(gpa, &data_reader);
                try decodeElemKind(&data_reader);
                break :blk .{
                    .type_info = .elemkind_funcref,
                    .init = .{ .func_indices = try decodeElemFuncIndexList(gpa, &data_reader) },
                    .mode = .{ .active = .{ .table_idx = table_idx, .offset = offset } },
                };
            },
            3 => blk: {
                try decodeElemKind(&data_reader);
                break :blk .{
                    .type_info = .elemkind_funcref,
                    .init = .{ .func_indices = try decodeElemFuncIndexList(gpa, &data_reader) },
                    .mode = .declare,
                };
            },
            4 => blk: {
                const offset = try Expr.decode(gpa, &data_reader);
                break :blk .{
                    .type_info = .{ .ref_type = .{ .heap_type = .func, .nullable = true } },
                    .init = .{ .exprs = try decodeElemExprList(gpa, &data_reader) },
                    .mode = .{ .active = .{ .table_idx = 0, .offset = offset } },
                };
            },
            5 => .{
                .type_info = .{ .ref_type = try wasm_types.RefType.decode(&data_reader) },
                .init = .{ .exprs = try decodeElemExprList(gpa, &data_reader) },
                .mode = .passive,
            },
            6 => blk: {
                const table_idx = data_reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidSection,
                        else => unreachable,
                    };
                const offset = try Expr.decode(gpa, &data_reader);
                break :blk .{
                    .type_info = .{ .ref_type = try wasm_types.RefType.decode(&data_reader) },
                    .init = .{ .exprs = try decodeElemExprList(gpa, &data_reader) },
                    .mode = .{ .active = .{ .table_idx = table_idx, .offset = offset } },
                };
            },
            7 => .{
                .type_info = .{ .ref_type = try wasm_types.RefType.decode(&data_reader) },
                .init = .{ .exprs = try decodeElemExprList(gpa, &data_reader) },
                .mode = .declare,
            },
            else => return error.invalidSection,
        };

        self.elements.append(gpa, elem) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeElemKind(reader: *std.Io.Reader) !void {
    const kind = reader.takeByte()
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };
    if (kind != 0x00) return error.invalidSection;
}

fn decodeElemFuncIndexList(gpa: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayListUnmanaged(u32) {
    const len = reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    var indices: std.ArrayListUnmanaged(u32) = .empty;
    for (0..len) |_| {
        indices.append(gpa, reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            }) catch unreachable;
    }
    return indices;
}

fn decodeElemExprList(gpa: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayListUnmanaged(Expr) {
    const len = reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    var exprs: std.ArrayListUnmanaged(Expr) = .empty;
    for (0..len) |_| {
        exprs.append(gpa, try Expr.decode(gpa, reader)) catch unreachable;
    }
    return exprs;
}

fn decodeDataCountSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x0C) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    var data_reader = std.Io.Reader.fixed(data);
    self.data_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeCodeSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x0A) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const code_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..code_count) |_| {
        const code_len = data_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            };

        const code_bytes = data_reader.take(code_len)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidSection,
                else => unreachable,
            };

        var code_reader = std.Io.Reader.fixed(code_bytes);
        const local_decl_count = code_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            };

        var locals: std.ArrayListUnmanaged(wasm_types.ValType) = .empty;
        for (0..local_decl_count) |_| {
            const n = code_reader.takeLeb128(u32)
                catch |err| switch (err) {
                    error.EndOfStream, error.Overflow => return error.invalidSection,
                    else => unreachable,
                };
            const val_type = try wasm_types.ValType.decode(&code_reader);
            for (0..n) |_| {
                locals.append(gpa, val_type) catch unreachable;
            }
        }

        const expr = try Expr.decode(gpa, &code_reader);

        const remaining_code_bytes = code_reader.discardRemaining() catch unreachable;
        if (remaining_code_bytes != 0) return error.invalidSection;

        self.codes.append(gpa, .{ .locals = locals, .expr = expr }) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeDataSec(self: *Module, reader: *std.Io.Reader) !void {
    const section_length = try readSectionHeader(reader, 0x0B) orelse return;
    const data = reader.take(section_length)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const gpa = self.arena.allocator();
    var data_reader = std.Io.Reader.fixed(data);

    const data_count = data_reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    for (0..data_count) |_| {
        const flags = data_reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidSection,
                else => unreachable,
            };

        const segment: Data = switch (flags) {
            0 => blk: {
                const offset = try Expr.decode(gpa, &data_reader);
                const bytes = try decodeByteList(gpa, &data_reader);
                break :blk .{ .bytes = bytes, .mode = .{ .active = .{ .mem_idx = 0, .offset = offset } } };
            },
            1 => .{ .bytes = try decodeByteList(gpa, &data_reader), .mode = .passive },
            2 => blk: {
                const mem_idx = data_reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidSection,
                        else => unreachable,
                    };
                const offset = try Expr.decode(gpa, &data_reader);
                const bytes = try decodeByteList(gpa, &data_reader);
                break :blk .{ .bytes = bytes, .mode = .{ .active = .{ .mem_idx = mem_idx, .offset = offset } } };
            },
            else => return error.invalidSection,
        };

        self.data_segments.append(gpa, segment) catch unreachable;
    }

    const remainingBytes = data_reader.discardRemaining() catch unreachable;
    if (remainingBytes != 0) return error.invalidSection;
}

fn decodeByteList(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]const u8 {
    const len = reader.takeLeb128(u32)
        catch |err| switch (err) {
            error.EndOfStream, error.Overflow => return error.invalidSection,
            else => unreachable,
        };

    const bytes = reader.take(len)
        catch |err| switch (err) {
            error.EndOfStream => return error.invalidSection,
            else => unreachable,
        };

    const out = gpa.alloc(u8, bytes.len) catch unreachable;
    @memcpy(out, bytes);
    return out;
}
