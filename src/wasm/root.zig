const std = @import("std");
const RecursiveType = @import("types.zig").RecursiveType;

pub fn add(a: u32, b: u32) u32 {
    return a + b;
}

pub const SparseModule = struct {
    allocator: std.heap.ArenaAllocator,

    custom_sections: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    types: std.ArrayListUnmanaged(RecursiveType) = .empty,

    pub fn deinit(self: *const SparseModule) void {
        self.allocator.deinit();
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !SparseModule {
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
        var module: SparseModule = .{ .allocator = arena_allocator };

        try module.decodeCustomSec(&reader);
        try module.decodeTypeSec(&reader);

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

    fn decodeCustomSec(self: *SparseModule, reader: *std.Io.Reader) !void {
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

            const content = data_reader.take(data.len - name.len)
                catch |err| switch (err) {
                    error.EndOfStream => return error.invalidSection,
                    else => unreachable,
                };

            self.custom_sections.put(self.allocator.allocator(), name, content) catch unreachable;
        }
    }

    fn decodeTypeSec(self: *SparseModule, reader: *std.Io.Reader) !void {
        while (true) {
            const section_length = try readSectionHeader(reader, 0x01) orelse return;
            const data = reader.take(section_length)
                catch |err| switch (err) {
                    error.EndOfStream => return error.invalidSection,
                    else => unreachable,
                };

            const gpa = self.allocator.allocator();
            const types = try RecursiveType.decode(gpa, data);
            self.types.appendSlice(gpa, types) catch unreachable;
        }
    }
};
