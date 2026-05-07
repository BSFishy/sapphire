const std = @import("std");

pub const Opcode = std.wasm.SimdOpcode;

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

pub const Immediate = union(enum) {
    none,
    memarg: MemArg,
    lane_idx: u8,
    memarg_lane: struct {
        memarg: MemArg,
        lane_idx: u8,
    },
    shuffle: [16]u8,
    v128_const: u128,
};

pub const Instr = struct {
    op: Opcode,
    immediate: Immediate,

    pub fn decode(reader: *std.Io.Reader) !Instr {
        const subopcode = reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidInstruction,
                else => unreachable,
            };

        const op: Opcode = @enumFromInt(subopcode);

        return .{
            .op = op,
            .immediate = switch (op) {
                .v128_load,
                .v128_load8x8_s,
                .v128_load8x8_u,
                .v128_load16x4_s,
                .v128_load16x4_u,
                .v128_load32x2_s,
                .v128_load32x2_u,
                .v128_load8_splat,
                .v128_load16_splat,
                .v128_load32_splat,
                .v128_load64_splat,
                .v128_store,
                .v128_load32_zero,
                .v128_load64_zero,
                => .{ .memarg = try MemArg.decode(reader) },

                .v128_const => .{ .v128_const = try decodeU128(reader) },
                .i8x16_shuffle => .{ .shuffle = try decodeLane16(reader) },

                .i8x16_extract_lane_s,
                .i8x16_extract_lane_u,
                .i8x16_replace_lane,
                .i16x8_extract_lane_s,
                .i16x8_extract_lane_u,
                .i16x8_replace_lane,
                .i32x4_extract_lane,
                .i32x4_replace_lane,
                .i64x2_extract_lane,
                .i64x2_replace_lane,
                .f32x4_extract_lane,
                .f32x4_replace_lane,
                .f64x2_extract_lane,
                .f64x2_replace_lane,
                => .{ .lane_idx = try decodeLaneIdx(reader) },

                .v128_load8_lane,
                .v128_load16_lane,
                .v128_load32_lane,
                .v128_load64_lane,
                .v128_store8_lane,
                .v128_store16_lane,
                .v128_store32_lane,
                .v128_store64_lane,
                => .{ .memarg_lane = .{ .memarg = try MemArg.decode(reader), .lane_idx = try decodeLaneIdx(reader) } },

                else => .none,
            },
        };
    }

    fn decodeLaneIdx(reader: *std.Io.Reader) !u8 {
        return reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };
    }

    fn decodeLane16(reader: *std.Io.Reader) ![16]u8 {
        var lanes: [16]u8 = undefined;
        for (&lanes) |*lane| lane.* = try decodeLaneIdx(reader);
        return lanes;
    }

    fn decodeU128(reader: *std.Io.Reader) !u128 {
        const bytes = reader.take(16)
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidInstruction,
                else => unreachable,
            };
        return std.mem.readInt(u128, bytes[0..16], .little);
    }
};
