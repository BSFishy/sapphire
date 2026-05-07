const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");

pub const BlockType = union(enum) {
    empty,
    val_type: types.ValType,
    type_idx: u32,

    pub fn decode(reader: *std.Io.Reader) !BlockType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };

        return switch (discriminator) {
            0x40 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .empty;
            },
            0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x74, 0x73, 0x72, 0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x64, 0x63 => .{ .val_type = try types.ValType.decode(reader) },
            else => blk: {
                const type_idx = reader.takeLeb128(i33)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidInstruction,
                        else => unreachable,
                    };

                if (type_idx < 0 or type_idx > std.math.maxInt(u32)) return error.invalidInstruction;
                break :blk .{ .type_idx = @intCast(type_idx) };
            },
        };
    }
};

pub const MemArg = struct {
    mem_idx: u32,
    @"align": u32,
    offset: u64,

    fn decode(reader: *std.Io.Reader) !MemArg {
        const n = reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidInstruction,
                else => unreachable,
            };

        if (n < (1 << 6)) {
            const offset = reader.takeLeb128(u64)
                catch |err| switch (err) {
                    error.EndOfStream, error.Overflow => return error.invalidInstruction,
                    else => unreachable,
                };
            return .{ .mem_idx = 0, .@"align" = n, .offset = offset };
        }

        if (n < (1 << 7)) {
            const mem_idx = reader.takeLeb128(u32)
                catch |err| switch (err) {
                    error.EndOfStream, error.Overflow => return error.invalidInstruction,
                    else => unreachable,
                };
            const offset = reader.takeLeb128(u64)
                catch |err| switch (err) {
                    error.EndOfStream, error.Overflow => return error.invalidInstruction,
                    else => unreachable,
                };
            return .{ .mem_idx = mem_idx, .@"align" = n - (1 << 6), .offset = offset };
        }

        return error.invalidInstruction;
    }
};

pub const Catch = union(enum) {
    tag: struct {
        tag_idx: u32,
        label_idx: u32,
    },
    tag_ref: struct {
        tag_idx: u32,
        label_idx: u32,
    },
    all: u32,
    all_ref: u32,

    fn decode(reader: *std.Io.Reader) !Catch {
        const opcode = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };

        return switch (opcode) {
            0x00 => .{ .tag = .{ .tag_idx = try Instr.decodeIndex(reader), .label_idx = try Instr.decodeIndex(reader) } },
            0x01 => .{ .tag_ref = .{ .tag_idx = try Instr.decodeIndex(reader), .label_idx = try Instr.decodeIndex(reader) } },
            0x02 => .{ .all = try Instr.decodeIndex(reader) },
            0x03 => .{ .all_ref = try Instr.decodeIndex(reader) },
            else => return error.invalidInstruction,
        };
    }
};

pub const Instr = union(enum) {
    const BrOnCast = struct {
        label_idx: u32,
        from: types.RefType,
        to: types.RefType,
    };

    // parametric instructions
    @"unreachable",
    nop,
    drop,
    select: std.ArrayListUnmanaged(types.ValType),

    // control instructions
    block: struct {
        block_type: BlockType,
        instructions: std.ArrayListUnmanaged(Instr),
    },
    loop: struct {
        block_type: BlockType,
        instructions: std.ArrayListUnmanaged(Instr),
    },
    @"if": struct {
        block_type: BlockType,
        instructions: std.ArrayListUnmanaged(Instr),
        @"else": std.ArrayListUnmanaged(Instr),
    },
    throw: u32,
    throw_ref,
    br: u32,
    br_if: u32,
    br_table: struct {
        table: std.ArrayListUnmanaged(u32),
        index: u32,
    },
    @"return",
    call: u32,
    try_table: struct {
        block_type: BlockType,
        catches: std.ArrayListUnmanaged(Catch),
        instructions: std.ArrayListUnmanaged(Instr),
    },
    br_on_null: u32,
    br_on_non_null: u32,
    br_on_cast: BrOnCast,
    br_on_cast_fail: BrOnCast,
    call_indirect: struct {
        type_idx: u32,
        table_idx: u32,
    },
    return_call: u32,
    return_call_indirect: struct {
        type_idx: u32,
        table_idx: u32,
    },
    call_ref: u32,
    return_call_ref: u32,

    // variable instructions
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    global_get: u32,
    global_set: u32,

    // table instructions
    table_get: u32,
    table_set: u32,
    table_init: struct {
        elem_idx: u32,
        table_idx: u32,
    },
    elem_drop: u32,
    table_copy: struct {
        dst_table_idx: u32,
        src_table_idx: u32,
    },
    table_grow: u32,
    table_size: u32,
    table_fill: u32,

    // memory instructions
    i32_load: MemArg,
    i64_load: MemArg,
    f32_load: MemArg,
    f64_load: MemArg,
    i32_load8_s: MemArg,
    i32_load8_u: MemArg,
    i32_load16_s: MemArg,
    i32_load16_u: MemArg,
    i64_load8_s: MemArg,
    i64_load8_u: MemArg,
    i64_load16_s: MemArg,
    i64_load16_u: MemArg,
    i64_load32_s: MemArg,
    i64_load32_u: MemArg,
    i32_store: MemArg,
    i64_store: MemArg,
    f32_store: MemArg,
    f64_store: MemArg,
    i32_store8: MemArg,
    i32_store16: MemArg,
    i64_store8: MemArg,
    i64_store16: MemArg,
    i64_store32: MemArg,
    memory_size: u32,
    memory_grow: u32,
    memory_init: struct {
        data_idx: u32,
        mem_idx: u32,
    },
    data_drop: u32,
    memory_copy: struct {
        dst_mem_idx: u32,
        src_mem_idx: u32,
    },
    memory_fill: u32,

    // reference instructions
    ref_null: types.HeapType,
    ref_is_null,
    ref_func: u32,
    ref_eq,
    ref_as_non_null,
    ref_test_non_null: types.HeapType,
    ref_test_nullable: types.HeapType,
    ref_cast_non_null: types.HeapType,
    ref_cast_nullable: types.HeapType,

    // aggregate instructions
    struct_new: u32,
    struct_new_default: u32,
    struct_get: struct {
        type_idx: u32,
        field_idx: u32,
    },
    struct_get_s: struct {
        type_idx: u32,
        field_idx: u32,
    },
    struct_get_u: struct {
        type_idx: u32,
        field_idx: u32,
    },
    struct_set: struct {
        type_idx: u32,
        field_idx: u32,
    },
    array_new: u32,
    array_new_default: u32,
    array_new_fixed: struct {
        type_idx: u32,
        len: u32,
    },
    array_new_data: struct {
        type_idx: u32,
        data_idx: u32,
    },
    array_new_elem: struct {
        type_idx: u32,
        elem_idx: u32,
    },
    array_get: u32,
    array_get_s: u32,
    array_get_u: u32,
    array_set: u32,
    array_len,
    array_fill: u32,
    array_copy: struct {
        dst_type_idx: u32,
        src_type_idx: u32,
    },
    array_init_data: struct {
        type_idx: u32,
        data_idx: u32,
    },
    array_init_elem: struct {
        type_idx: u32,
        elem_idx: u32,
    },
    any_convert_extern,
    extern_convert_any,
    ref_i31,
    i31_get_s,
    i31_get_u,

    // numeric instructions
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,
    i32_eqz,
    i32_eq,
    i32_ne,
    i32_lt_s,
    i32_lt_u,
    i32_gt_s,
    i32_gt_u,
    i32_le_s,
    i32_le_u,
    i32_ge_s,
    i32_ge_u,
    i64_eqz,
    i64_eq,
    i64_ne,
    i64_lt_s,
    i64_lt_u,
    i64_gt_s,
    i64_gt_u,
    i64_le_s,
    i64_le_u,
    i64_ge_s,
    i64_ge_u,
    f32_eq,
    f32_ne,
    f32_lt,
    f32_gt,
    f32_le,
    f32_ge,
    f64_eq,
    f64_ne,
    f64_lt,
    f64_gt,
    f64_le,
    f64_ge,
    i32_clz,
    i32_ctz,
    i32_popcnt,
    i32_add,
    i32_sub,
    i32_mul,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i32_and,
    i32_or,
    i32_xor,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,
    i64_clz,
    i64_ctz,
    i64_popcnt,
    i64_add,
    i64_sub,
    i64_mul,
    i64_div_s,
    i64_div_u,
    i64_rem_s,
    i64_rem_u,
    i64_and,
    i64_or,
    i64_xor,
    i64_shl,
    i64_shr_s,
    i64_shr_u,
    i64_rotl,
    i64_rotr,
    f32_abs,
    f32_neg,
    f32_ceil,
    f32_floor,
    f32_trunc,
    f32_nearest,
    f32_sqrt,
    f32_add,
    f32_sub,
    f32_mul,
    f32_div,
    f32_min,
    f32_max,
    f32_copysign,
    f64_abs,
    f64_neg,
    f64_ceil,
    f64_floor,
    f64_trunc,
    f64_nearest,
    f64_sqrt,
    f64_add,
    f64_sub,
    f64_mul,
    f64_div,
    f64_min,
    f64_max,
    f64_copysign,
    i32_wrap_i64,
    i32_trunc_s_f32,
    i32_trunc_u_f32,
    i32_trunc_s_f64,
    i32_trunc_u_f64,
    i64_extend_s_i32,
    i64_extend_u_i32,
    i64_trunc_s_f32,
    i64_trunc_u_f32,
    i64_trunc_s_f64,
    i64_trunc_u_f64,
    f32_convert_s_i32,
    f32_convert_u_i32,
    f32_convert_s_i64,
    f32_convert_u_i64,
    f32_demote_f64,
    f64_convert_s_i32,
    f64_convert_u_i32,
    f64_convert_s_i64,
    f64_convert_u_i64,
    f64_promote_f32,
    i32_reinterpret_f32,
    i64_reinterpret_f64,
    f32_reinterpret_i32,
    f64_reinterpret_i64,
    i32_extend8_s,
    i32_extend16_s,
    i64_extend8_s,
    i64_extend16_s,
    i64_extend32_s,
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i64_trunc_sat_f32_s,
    i64_trunc_sat_f32_u,
    i64_trunc_sat_f64_s,
    i64_trunc_sat_f64_u,

    // vector instructions
    simd: simd.Instr,

    pub fn decode(gpa: std.mem.Allocator, reader: *std.Io.Reader) anyerror!Instr {
        const opcode = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };

        return switch (opcode) {
            0x00 => .@"unreachable",
            0x01 => .nop,
            0x1A => .drop,
            0x1B => .{ .select = .empty },
            0x1C => blk: {
                const len = reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidInstruction,
                        else => unreachable,
                    };

                var val_types: std.ArrayListUnmanaged(types.ValType) = .empty;
                for (0..len) |_| {
                    val_types.append(gpa, try types.ValType.decode(reader)) catch unreachable;
                }

                break :blk .{ .select = val_types };
            },

            0x02 => .{ .block = .{
                .block_type = try BlockType.decode(reader),
                .instructions = try decodeInstructionSequence(gpa, reader, false),
            } },
            0x03 => .{ .loop = .{
                .block_type = try BlockType.decode(reader),
                .instructions = try decodeInstructionSequence(gpa, reader, false),
            } },
            0x04 => blk: {
                const block_type = try BlockType.decode(reader);
                const instructions = try decodeInstructionSequence(gpa, reader, true);

                const delimiter = reader.takeByte()
                    catch |err| switch (err) {
                        error.EndOfStream => return error.invalidInstruction,
                        else => unreachable,
                    };

                switch (delimiter) {
                    0x05 => {
                        const else_instructions = try decodeInstructionSequence(gpa, reader, false);
                        break :blk .{ .@"if" = .{
                            .block_type = block_type,
                            .instructions = instructions,
                            .@"else" = else_instructions,
                        } };
                    },
                    0x0B => {
                        break :blk .{ .@"if" = .{
                            .block_type = block_type,
                            .instructions = instructions,
                            .@"else" = .empty,
                        } };
                    },
                    else => return error.invalidInstruction,
                }
            },
            0x08 => .{ .throw = try decodeIndex(reader) },
            0x0A => .throw_ref,
            0x0C => .{ .br = try decodeIndex(reader) },
            0x0D => .{ .br_if = try decodeIndex(reader) },
            0x0E => blk: {
                const len = try decodeIndex(reader);
                var table: std.ArrayListUnmanaged(u32) = .empty;
                for (0..len) |_| {
                    table.append(gpa, try decodeIndex(reader)) catch unreachable;
                }

                break :blk .{ .br_table = .{
                    .table = table,
                    .index = try decodeIndex(reader),
                } };
            },
            0x0F => .@"return",
            0x10 => .{ .call = try decodeIndex(reader) },
            0x11 => .{ .call_indirect = .{
                .type_idx = try decodeIndex(reader),
                .table_idx = try decodeIndex(reader),
            } },
            0x12 => .{ .return_call = try decodeIndex(reader) },
            0x13 => .{ .return_call_indirect = .{
                .type_idx = try decodeIndex(reader),
                .table_idx = try decodeIndex(reader),
            } },
            0x14 => .{ .call_ref = try decodeIndex(reader) },
            0x15 => .{ .return_call_ref = try decodeIndex(reader) },
            0x1F => blk: {
                const block_type = try BlockType.decode(reader);
                const len = try decodeIndex(reader);

                var catches: std.ArrayListUnmanaged(Catch) = .empty;
                for (0..len) |_| {
                    catches.append(gpa, try Catch.decode(reader)) catch unreachable;
                }

                break :blk .{ .try_table = .{
                    .block_type = block_type,
                    .catches = catches,
                    .instructions = try decodeInstructionSequence(gpa, reader, false),
                } };
            },
            0xD5 => .{ .br_on_null = try decodeIndex(reader) },
            0xD6 => .{ .br_on_non_null = try decodeIndex(reader) },
            0x20 => .{ .local_get = try decodeIndex(reader) },
            0x21 => .{ .local_set = try decodeIndex(reader) },
            0x22 => .{ .local_tee = try decodeIndex(reader) },
            0x23 => .{ .global_get = try decodeIndex(reader) },
            0x24 => .{ .global_set = try decodeIndex(reader) },
            0x25 => .{ .table_get = try decodeIndex(reader) },
            0x26 => .{ .table_set = try decodeIndex(reader) },
            0x28 => .{ .i32_load = try MemArg.decode(reader) },
            0x29 => .{ .i64_load = try MemArg.decode(reader) },
            0x2A => .{ .f32_load = try MemArg.decode(reader) },
            0x2B => .{ .f64_load = try MemArg.decode(reader) },
            0x2C => .{ .i32_load8_s = try MemArg.decode(reader) },
            0x2D => .{ .i32_load8_u = try MemArg.decode(reader) },
            0x2E => .{ .i32_load16_s = try MemArg.decode(reader) },
            0x2F => .{ .i32_load16_u = try MemArg.decode(reader) },
            0x30 => .{ .i64_load8_s = try MemArg.decode(reader) },
            0x31 => .{ .i64_load8_u = try MemArg.decode(reader) },
            0x32 => .{ .i64_load16_s = try MemArg.decode(reader) },
            0x33 => .{ .i64_load16_u = try MemArg.decode(reader) },
            0x34 => .{ .i64_load32_s = try MemArg.decode(reader) },
            0x35 => .{ .i64_load32_u = try MemArg.decode(reader) },
            0x36 => .{ .i32_store = try MemArg.decode(reader) },
            0x37 => .{ .i64_store = try MemArg.decode(reader) },
            0x38 => .{ .f32_store = try MemArg.decode(reader) },
            0x39 => .{ .f64_store = try MemArg.decode(reader) },
            0x3A => .{ .i32_store8 = try MemArg.decode(reader) },
            0x3B => .{ .i32_store16 = try MemArg.decode(reader) },
            0x3C => .{ .i64_store8 = try MemArg.decode(reader) },
            0x3D => .{ .i64_store16 = try MemArg.decode(reader) },
            0x3E => .{ .i64_store32 = try MemArg.decode(reader) },
            0x3F => .{ .memory_size = try decodeIndex(reader) },
            0x40 => .{ .memory_grow = try decodeIndex(reader) },
            0x41 => .{ .i32_const = try reader.takeLeb128(i32) },
            0x42 => .{ .i64_const = try reader.takeLeb128(i64) },
            0x43 => .{ .f32_const = try decodeF32(reader) },
            0x44 => .{ .f64_const = try decodeF64(reader) },
            0x45 => .i32_eqz,
            0x46 => .i32_eq,
            0x47 => .i32_ne,
            0x48 => .i32_lt_s,
            0x49 => .i32_lt_u,
            0x4A => .i32_gt_s,
            0x4B => .i32_gt_u,
            0x4C => .i32_le_s,
            0x4D => .i32_le_u,
            0x4E => .i32_ge_s,
            0x4F => .i32_ge_u,
            0x50 => .i64_eqz,
            0x51 => .i64_eq,
            0x52 => .i64_ne,
            0x53 => .i64_lt_s,
            0x54 => .i64_lt_u,
            0x55 => .i64_gt_s,
            0x56 => .i64_gt_u,
            0x57 => .i64_le_s,
            0x58 => .i64_le_u,
            0x59 => .i64_ge_s,
            0x5A => .i64_ge_u,
            0x5B => .f32_eq,
            0x5C => .f32_ne,
            0x5D => .f32_lt,
            0x5E => .f32_gt,
            0x5F => .f32_le,
            0x60 => .f32_ge,
            0x61 => .f64_eq,
            0x62 => .f64_ne,
            0x63 => .f64_lt,
            0x64 => .f64_gt,
            0x65 => .f64_le,
            0x66 => .f64_ge,
            0x67 => .i32_clz,
            0x68 => .i32_ctz,
            0x69 => .i32_popcnt,
            0x6A => .i32_add,
            0x6B => .i32_sub,
            0x6C => .i32_mul,
            0x6D => .i32_div_s,
            0x6E => .i32_div_u,
            0x6F => .i32_rem_s,
            0x70 => .i32_rem_u,
            0x71 => .i32_and,
            0x72 => .i32_or,
            0x73 => .i32_xor,
            0x74 => .i32_shl,
            0x75 => .i32_shr_s,
            0x76 => .i32_shr_u,
            0x77 => .i32_rotl,
            0x78 => .i32_rotr,
            0x79 => .i64_clz,
            0x7A => .i64_ctz,
            0x7B => .i64_popcnt,
            0x7C => .i64_add,
            0x7D => .i64_sub,
            0x7E => .i64_mul,
            0x7F => .i64_div_s,
            0x80 => .i64_div_u,
            0x81 => .i64_rem_s,
            0x82 => .i64_rem_u,
            0x83 => .i64_and,
            0x84 => .i64_or,
            0x85 => .i64_xor,
            0x86 => .i64_shl,
            0x87 => .i64_shr_s,
            0x88 => .i64_shr_u,
            0x89 => .i64_rotl,
            0x8A => .i64_rotr,
            0x8B => .f32_abs,
            0x8C => .f32_neg,
            0x8D => .f32_ceil,
            0x8E => .f32_floor,
            0x8F => .f32_trunc,
            0x90 => .f32_nearest,
            0x91 => .f32_sqrt,
            0x92 => .f32_add,
            0x93 => .f32_sub,
            0x94 => .f32_mul,
            0x95 => .f32_div,
            0x96 => .f32_min,
            0x97 => .f32_max,
            0x98 => .f32_copysign,
            0x99 => .f64_abs,
            0x9A => .f64_neg,
            0x9B => .f64_ceil,
            0x9C => .f64_floor,
            0x9D => .f64_trunc,
            0x9E => .f64_nearest,
            0x9F => .f64_sqrt,
            0xA0 => .f64_add,
            0xA1 => .f64_sub,
            0xA2 => .f64_mul,
            0xA3 => .f64_div,
            0xA4 => .f64_min,
            0xA5 => .f64_max,
            0xA6 => .f64_copysign,
            0xA7 => .i32_wrap_i64,
            0xA8 => .i32_trunc_s_f32,
            0xA9 => .i32_trunc_u_f32,
            0xAA => .i32_trunc_s_f64,
            0xAB => .i32_trunc_u_f64,
            0xAC => .i64_extend_s_i32,
            0xAD => .i64_extend_u_i32,
            0xAE => .i64_trunc_s_f32,
            0xAF => .i64_trunc_u_f32,
            0xB0 => .i64_trunc_s_f64,
            0xB1 => .i64_trunc_u_f64,
            0xB2 => .f32_convert_s_i32,
            0xB3 => .f32_convert_u_i32,
            0xB4 => .f32_convert_s_i64,
            0xB5 => .f32_convert_u_i64,
            0xB6 => .f32_demote_f64,
            0xB7 => .f64_convert_s_i32,
            0xB8 => .f64_convert_u_i32,
            0xB9 => .f64_convert_s_i64,
            0xBA => .f64_convert_u_i64,
            0xBB => .f64_promote_f32,
            0xBC => .i32_reinterpret_f32,
            0xBD => .i64_reinterpret_f64,
            0xBE => .f32_reinterpret_i32,
            0xBF => .f64_reinterpret_i64,
            0xC0 => .i32_extend8_s,
            0xC1 => .i32_extend16_s,
            0xC2 => .i64_extend8_s,
            0xC3 => .i64_extend16_s,
            0xC4 => .i64_extend32_s,
            0xD0 => .{ .ref_null = try types.HeapType.decode(reader) },
            0xD1 => .ref_is_null,
            0xD2 => .{ .ref_func = try decodeIndex(reader) },
            0xD3 => .ref_eq,
            0xD4 => .ref_as_non_null,
            0xFB => switch (try decodeIndex(reader)) {
                0 => .{ .struct_new = try decodeIndex(reader) },
                1 => .{ .struct_new_default = try decodeIndex(reader) },
                2 => .{ .struct_get = .{
                    .type_idx = try decodeIndex(reader),
                    .field_idx = try decodeIndex(reader),
                } },
                3 => .{ .struct_get_s = .{
                    .type_idx = try decodeIndex(reader),
                    .field_idx = try decodeIndex(reader),
                } },
                4 => .{ .struct_get_u = .{
                    .type_idx = try decodeIndex(reader),
                    .field_idx = try decodeIndex(reader),
                } },
                5 => .{ .struct_set = .{
                    .type_idx = try decodeIndex(reader),
                    .field_idx = try decodeIndex(reader),
                } },
                6 => .{ .array_new = try decodeIndex(reader) },
                7 => .{ .array_new_default = try decodeIndex(reader) },
                8 => .{ .array_new_fixed = .{
                    .type_idx = try decodeIndex(reader),
                    .len = try decodeIndex(reader),
                } },
                9 => .{ .array_new_data = .{
                    .type_idx = try decodeIndex(reader),
                    .data_idx = try decodeIndex(reader),
                } },
                10 => .{ .array_new_elem = .{
                    .type_idx = try decodeIndex(reader),
                    .elem_idx = try decodeIndex(reader),
                } },
                11 => .{ .array_get = try decodeIndex(reader) },
                12 => .{ .array_get_s = try decodeIndex(reader) },
                13 => .{ .array_get_u = try decodeIndex(reader) },
                14 => .{ .array_set = try decodeIndex(reader) },
                15 => .array_len,
                16 => .{ .array_fill = try decodeIndex(reader) },
                17 => .{ .array_copy = .{
                    .dst_type_idx = try decodeIndex(reader),
                    .src_type_idx = try decodeIndex(reader),
                } },
                18 => .{ .array_init_data = .{
                    .type_idx = try decodeIndex(reader),
                    .data_idx = try decodeIndex(reader),
                } },
                19 => .{ .array_init_elem = .{
                    .type_idx = try decodeIndex(reader),
                    .elem_idx = try decodeIndex(reader),
                } },
                20 => .{ .ref_test_non_null = try types.HeapType.decode(reader) },
                21 => .{ .ref_test_nullable = try types.HeapType.decode(reader) },
                22 => .{ .ref_cast_non_null = try types.HeapType.decode(reader) },
                23 => .{ .ref_cast_nullable = try types.HeapType.decode(reader) },
                24 => .{ .br_on_cast = try decodeBrOnCast(reader) },
                25 => .{ .br_on_cast_fail = try decodeBrOnCast(reader) },
                26 => .any_convert_extern,
                27 => .extern_convert_any,
                28 => .ref_i31,
                29 => .i31_get_s,
                30 => .i31_get_u,
                else => return error.invalidInstruction,
            },
            0xFC => switch (try decodeIndex(reader)) {
                0 => .i32_trunc_sat_f32_s,
                1 => .i32_trunc_sat_f32_u,
                2 => .i32_trunc_sat_f64_s,
                3 => .i32_trunc_sat_f64_u,
                4 => .i64_trunc_sat_f32_s,
                5 => .i64_trunc_sat_f32_u,
                6 => .i64_trunc_sat_f64_s,
                7 => .i64_trunc_sat_f64_u,
                8 => .{ .memory_init = .{
                    .data_idx = try decodeIndex(reader),
                    .mem_idx = try decodeIndex(reader),
                } },
                9 => .{ .data_drop = try decodeIndex(reader) },
                10 => .{ .memory_copy = .{
                    .dst_mem_idx = try decodeIndex(reader),
                    .src_mem_idx = try decodeIndex(reader),
                } },
                11 => .{ .memory_fill = try decodeIndex(reader) },
                12 => .{ .table_init = .{
                    .elem_idx = try decodeIndex(reader),
                    .table_idx = try decodeIndex(reader),
                } },
                13 => .{ .elem_drop = try decodeIndex(reader) },
                14 => .{ .table_copy = .{
                    .dst_table_idx = try decodeIndex(reader),
                    .src_table_idx = try decodeIndex(reader),
                } },
                15 => .{ .table_grow = try decodeIndex(reader) },
                16 => .{ .table_size = try decodeIndex(reader) },
                17 => .{ .table_fill = try decodeIndex(reader) },
                else => return error.invalidInstruction,
            },
            0xFD => .{ .simd = try simd.Instr.decode(reader) },
            else => return error.invalidInstruction,
        };
    }

    fn decodeInstructionSequence(gpa: std.mem.Allocator, reader: *std.Io.Reader, allow_else: bool) !std.ArrayListUnmanaged(Instr) {
        var instructions: std.ArrayListUnmanaged(Instr) = .empty;

        while (true) {
            const opcode = reader.peekByte()
                catch |err| switch (err) {
                    error.EndOfStream => return error.invalidInstruction,
                    else => unreachable,
                };

            switch (opcode) {
                0x0B => {
                    _ = reader.takeByte() catch unreachable;
                    return instructions;
                },
                0x05 => {
                    if (!allow_else) return error.invalidInstruction;
                    return instructions;
                },
                else => instructions.append(gpa, try decode(gpa, reader)) catch unreachable,
            }
        }
    }

    fn decodeIndex(reader: *std.Io.Reader) !u32 {
        return reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidInstruction,
                else => unreachable,
            };
    }

    fn decodeF32(reader: *std.Io.Reader) !f32 {
        const bytes = reader.take(4)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };
        const bits = std.mem.readInt(u32, bytes[0..4], .little);
        return @bitCast(bits);
    }

    fn decodeF64(reader: *std.Io.Reader) !f64 {
        const bytes = reader.take(8)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };
        const bits = std.mem.readInt(u64, bytes[0..8], .little);
        return @bitCast(bits);
    }

    fn decodeBrOnCast(reader: *std.Io.Reader) !BrOnCast {
        const castop = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };

        const from_nullable = switch (castop) {
            0x00, 0x02 => false,
            0x01, 0x03 => true,
            else => return error.invalidInstruction,
        };
        const to_nullable = switch (castop) {
            0x00, 0x01 => false,
            0x02, 0x03 => true,
            else => unreachable,
        };

        return .{
            .label_idx = try decodeIndex(reader),
            .from = .{ .heap_type = try types.HeapType.decode(reader), .nullable = from_nullable },
            .to = .{ .heap_type = try types.HeapType.decode(reader), .nullable = to_nullable },
        };
    }
};

pub const Expr = struct {
    instructions: std.ArrayListUnmanaged(Instr) = .empty,

    pub fn decode(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Expr {
        var expr: Expr = .{};
        while (true) {
            const discriminator = reader.peekByte()
                catch |err| switch (err) {
                    error.EndOfStream => return error.invalidExpression,
                    else => unreachable,
                };

            if (discriminator == 0x0B) {
                _ = reader.takeByte() catch unreachable;
                return expr;
            }

            expr.instructions.append(gpa, try Instr.decode(gpa, reader)) catch unreachable;
        }
    }

    pub fn single(gpa: std.mem.Allocator, instr: Instr) Expr {
        var expr: Expr = .{};
        expr.instructions.append(gpa, instr) catch unreachable;

        return expr;
    }
};
