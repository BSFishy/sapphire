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

pub const MemoryMapFeature = extern struct {
    pub const Response = extern struct {
        pub const Entry = extern struct {
            base: u64,
            length: u64,
            type: enum(u64) {
                usable                = 0,
                reserved              = 1,
                acpiReclaimable       = 2,
                acpiNvs               = 3,
                badMemory             = 4,
                bootloaderReclaimable = 5,
                executableAndModules  = 6,
                framebuffer           = 7,
                reservedMapping       = 8,
            },

            pub inline fn start(self: *const Entry, frame_size: u64) u64 {
                return std.mem.alignForward(u64, self.base, frame_size);
            }

            pub inline fn end(self: *const Entry, frame_size: u64) u64 {
                return std.mem.alignBackward(u64, self.base + self.length, frame_size);
            }

            pub inline fn len(self: *const Entry) u64 {
                // NOTE: assumes 4KiB frames
                const frame_start = self.start(4096);
                const frame_end = self.end(4096);
                return frame_end - frame_start;
            }
        };

        revision: u64,
        entry_count: u64,
        entries: [*]*Entry,
    };

    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64,
    response: ?*Response = null,
};
