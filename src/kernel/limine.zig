const std = @import("std");

pub const RequestsStartMarker = extern struct {
    marker: [4]u64 = .{
        0xf6b8f4b39de7d1ae,
        0xfab91a6940fcb9cf,
        0x785c6ed015d3e316,
        0x181e920a7852b9d9,
    },
};

pub const RequestsEndMarker = extern struct {
    marker: [2]u64 = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

pub const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64,

    pub fn init(revision: u64) @This() {
        return .{ .revision = revision };
    }

    pub fn loadedRevision(self: @This()) u64 {
        return self.magic[1];
    }

    pub fn isValid(self: @This()) bool {
        return self.magic[1] != 0x6a7b384944536bdc;
    }

    pub fn isSupported(self: @This()) bool {
        return self.revision == 0;
    }
};
