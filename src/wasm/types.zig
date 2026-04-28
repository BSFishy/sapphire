const std = @import("std");

const NumType = enum {
    i32,
    i64,
    f32,
    f64,

    fn decode(reader: *std.Io.Reader) !NumType {
        const discriminator = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            else => return error.invalidType,
        };
    }
};

const VecType = enum {
    v128,

    fn decode(reader: *std.Io.Reader) !VecType {
        const discriminator = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x7B => .v128,
            else => return error.invalidType,
        };
    }
};

const HeapType = union(enum) {
    type_idx: u32,
    noexn,
    nofunc,
    noextern,
    none,
    func,
    @"extern",
    any,
    eq,
    i31,
    @"struct",
    array,
    exn,

    fn decode(reader: *std.Io.Reader) !HeapType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x74 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .noexn;
            },
            0x73 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .nofunc;
            },
            0x72 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .noextern;
            },
            0x71 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .none;
            },
            0x70 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .func;
            },
            0x6F => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .@"extern";
            },
            0x6E => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .any;
            },
            0x6D => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .eq;
            },
            0x6C => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .i31;
            },
            0x6B => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .@"struct";
            },
            0x6A => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .array;
            },
            0x69 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .exn;
            },
            else => .{
                .type_idx = reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidType,
                        else => unreachable,
                    },
            },
        };
    }
};

const RefType = struct {
    heap_type: HeapType,
    nullable: bool,

    fn decode(reader: *std.Io.Reader) !RefType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x74 => .{ .heap_type = .noexn, .nullable = true },
            0x73 => .{ .heap_type = .nofunc, .nullable = true },
            0x72 => .{ .heap_type = .noextern, .nullable = true },
            0x71 => .{ .heap_type = .none, .nullable = true },
            0x70 => .{ .heap_type = .func, .nullable = true },
            0x6F => .{ .heap_type = .@"extern", .nullable = true },
            0x6E => .{ .heap_type = .any, .nullable = true },
            0x6D => .{ .heap_type = .eq, .nullable = true },
            0x6C => .{ .heap_type = .i31, .nullable = true },
            0x6B => .{ .heap_type = .@"struct", .nullable = true },
            0x6A => .{ .heap_type = .array, .nullable = true },
            0x69 => .{ .heap_type = .exn, .nullable = true },
            0x64 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .{ .heap_type = try HeapType.decode(reader), .nullable = false };
            },
            0x63 => blk: {
                _ = reader.takeByte() catch unreachable;
                break :blk .{ .heap_type = try HeapType.decode(reader), .nullable = true };
            },
            else => return error.invalidType,
        };
    }
};

const ValType = union(enum) {
    num: NumType,
    vec: VecType,
    ref: RefType,

    fn decode(reader: *std.Io.Reader) !ValType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x7F, 0x7E, 0x7D, 0x7C => .{ .num = try NumType.decode(reader) },
            0x7B => .{ .vec = try VecType.decode(reader) },
            0x74, 0x73, 0x72, 0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x64, 0x63 => .{ .ref = try RefType.decode(reader) },
            else => return error.invalidType,
        };
    }
};

const PackType = enum {
    i8,
    i16,

    fn decode(reader: *std.Io.Reader) !PackType {
        const discriminator = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x78 => .i8,
            0x77 => .i16,
            else => return error.invalidType,
        };
    }
};

const StorageType = union(enum) {
    val: ValType,
    pack: PackType,

    fn decode(reader: *std.Io.Reader) !StorageType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x78, 0x77 => .{ .pack = try PackType.decode(reader) },
            else => .{ .val = try ValType.decode(reader) },
        };
    }
};

const FieldType = struct {
    storage_type: StorageType,
    mutable: bool,

    fn decode(reader: *std.Io.Reader) !FieldType {
        const storage_type = try StorageType.decode(reader);
        const mutability = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (mutability) {
            0x00 => .{ .storage_type = storage_type, .mutable = false },
            0x01 => .{ .storage_type = storage_type, .mutable = true },
            else => return error.invalidType,
        };
    }
};

const ResultType = struct {
    val_types: []const ValType,

    fn decode(gpa: std.mem.Allocator, reader: *std.Io.Reader) !ResultType {
        const len = reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidType,
                else => unreachable,
            };

        var val_types: std.ArrayListUnmanaged(ValType) = .empty;
        for (0..len) |_| {
            val_types.append(gpa, try ValType.decode(reader)) catch unreachable;
        }

        return .{
            .val_types = val_types.toOwnedSlice(gpa) catch unreachable,
        };
    }
};

const CompType = union(enum) {
    array: FieldType,
    @"struct": []const FieldType,
    func: struct {
        args: ResultType,
        results: ResultType,
    },

    fn decode(gpa: std.mem.Allocator, reader: *std.Io.Reader) !CompType {
        const discriminator = reader.takeByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        return switch (discriminator) {
            0x5E => .{ .array = try FieldType.decode(reader) },
            0x5F => blk: {
                const len = reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidType,
                        else => unreachable,
                    };

                var fields: std.ArrayListUnmanaged(FieldType) = .empty;
                for (0..len) |_| {
                    fields.append(gpa, try FieldType.decode(reader)) catch unreachable;
                }

                break :blk .{ .@"struct" = fields.toOwnedSlice(gpa) catch unreachable };
            },
            0x60 => .{
                .func = .{
                    .args = try ResultType.decode(gpa, reader),
                    .results = try ResultType.decode(gpa, reader),
                },
            },
            else => return error.invalidType,
        };
    }
};

const SubType = struct {
    comp_type: CompType,
    uses: []const u32,
    final: bool,

    fn decode(gpa: std.mem.Allocator, reader: *std.Io.Reader) !SubType {
        const discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        var comp_type: CompType = undefined;
        var uses: std.ArrayListUnmanaged(u32) = .empty;
        var final = true;

        foo: switch (discriminator) {
            0x4F => {
                _ = reader.takeByte() catch unreachable;

                const len = reader.takeLeb128(u32)
                    catch |err| switch (err) {
                        error.EndOfStream, error.Overflow => return error.invalidType,
                        else => unreachable,
                    };

                for (0..len) |_| {
                    const idx = reader.takeLeb128(u32)
                        catch |err| switch (err) {
                            error.EndOfStream, error.Overflow => return error.invalidType,
                            else => unreachable,
                        };

                    uses.append(gpa, idx) catch unreachable;
                }

                continue :foo 0x00;
            },
            0x50 => {
                final = false;
                continue :foo 0x4F;
            },
            else => {
                comp_type = try CompType.decode(gpa, reader);
            },
        }

        return .{
            .comp_type = comp_type,
            .uses = uses.toOwnedSlice(gpa) catch unreachable,
            .final = final,
        };
    }
};

pub const RecursiveType = struct {
    sub_types: []const SubType,

    // NOTE: assumes `gpa` is an arena allocator
    pub fn decode(gpa: std.mem.Allocator, data: []const u8) ![]RecursiveType {
        var types: std.ArrayListUnmanaged(RecursiveType) = .empty;
        var reader = std.Io.Reader.fixed(data);

        const len = reader.takeLeb128(u32)
            catch |err| switch (err) {
                error.EndOfStream, error.Overflow => return error.invalidTypeSection,
                else => unreachable,
            };

        for (0..len) |_| {
            types.append(gpa, try decodeRecursiveType(gpa, &reader)) catch unreachable;
        }

        const remaining_length = reader.discardRemaining() catch unreachable;
        if (remaining_length != 0) return error.invalidTypes;

        return types.toOwnedSlice(gpa) catch unreachable;
    }

    fn decodeRecursiveType(gpa: std.mem.Allocator, reader: *std.Io.Reader) !RecursiveType {
        const list_discriminator = reader.peekByte()
            catch |err| switch (err) {
                error.EndOfStream => return error.invalidType,
                else => unreachable,
            };

        var sub_types: std.ArrayListUnmanaged(SubType) = .empty;

        if (list_discriminator == 0x4E) {
            _ = reader.takeByte() catch unreachable;

            const list_len = reader.takeLeb128(u32)
                catch |err| switch (err) {
                    error.EndOfStream, error.Overflow => return error.invalidType,
                    else => unreachable,
                };

            for (0..list_len) |_| {
                sub_types.append(gpa, try SubType.decode(gpa, reader)) catch unreachable;
            }
        } else {
            sub_types.append(gpa, try SubType.decode(gpa, reader)) catch unreachable;
        }

        return .{
            .sub_types = sub_types.toOwnedSlice(gpa) catch unreachable,
        };
    }
};
