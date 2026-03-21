const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const ranks = @import("options").ranks;

const Flag = enum(usize) {
    reserved,
    allocated,

    // NOTE: keep this at the end
    max,

    fn value(self: Flag) usize {
        return @intFromEnum(self);
    }
};

pub fn regionContainsRegion(address: usize, end_address: usize, start: usize, end: usize) bool {
    if (end < address) {
        return false;
    }

    if (start > end_address) {
        return false;
    }

    return true;
}

pub const Frame = struct {
    // TODO: rethink about flags. i feel like there is certainly a better
    // interface to interact with these like this.
    const Flags = std.StaticBitSet(Flag.max.value());
    const Free = struct {
        order: usize,
        next_free: ?usize,
        previous_free: ?usize,
    };

    free: ?Free,

    region: usize,
    flags: Flags,
    address: usize,

    pub fn isContiguous(self: *const Frame, other: *const Frame) bool {
        const lower = if (self.address > other.address) other else self;
        const higher = if (self.address < other.address) other else self;

        // NOTE: assumes 4KiB frames
        const size = std.math.pow(usize, 2, self.order) * 0x1000;
        return (lower.address + size) == higher.address;
    }

    pub fn containsRegion(self: *const Frame, start: usize, end: usize) bool {
        const address = self.address;
        // NOTE: assumes 4KiB frames
        const end_address = address + 0x1000;

        if (end < address) {
            return false;
        }

        if (start > end_address) {
            return false;
        }

        return true;
    }

    pub fn reserved(self: *Frame) void {
        self.flags.set(Flag.reserved.value());
    }

    pub fn allocate(self: *Frame) void {
        self.flags.set(Flag.allocated.value());
    }

    pub fn deallocate(self: *Frame) void {
        self.flags.unset(Flag.allocated.value());
    }

    pub fn isAllocated(self: *Frame) bool {
        self.flags.isSet(Flag.allocated.value());
    }
};

const PhysicalMemoryManager = struct {
    const Entry = limine.MemoryMapFeature.Response.Entry;

    entries: []const *Entry,
    offset: u64,

    fn count_usable_frames(self: *const PhysicalMemoryManager) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.type != .usable) continue;

            // NOTE: assuming 4KiB frames
            count += entry.len() / 4096;
        }

        return count;
    }

    fn find_region_for_size(self: *const PhysicalMemoryManager, size: usize) ?limine.MemoryMapFeature.Response.Entry {
        // NOTE: this function currently just finds the first memory map entry
        // that is usable and can fit the data. I'm not sure if there is a
        // better way to find a region, but this should be fine I think.
        for (self.entries) |entry| {
            if (entry.type != .usable) continue;
            if (entry.length < size) continue;

            const address = entry.base;
            const length = entry.length;

            entry.base = address + size;
            entry.length = length - size;

            return .{
                .base = address,
                .length = size,
                .type = .usable,
            };
        }

        return null;
    }
};

fn newFreeList() [ranks]?usize {
    var free_list: [ranks]?usize = undefined;
    for (0..ranks) |i| {
        free_list[i] = null;
    }

    return free_list;
}

pub const FrameAllocator = struct {
    frames: []Frame,
    free_list: [ranks]?usize,

    pub fn init(entries: []const *PhysicalMemoryManager.Entry, offset: u64) !FrameAllocator {
        const pmm: PhysicalMemoryManager = .{
            .entries = entries,
            .offset = offset,
        };

        const frame_count = pmm.count_usable_frames();
        const frame_list_size = frame_count * @sizeOf(Frame);

        const region = pmm.find_region_for_size(frame_list_size) orelse
            return error.couldNotFindFrame;

        var frames: [*]Frame = @ptrFromInt(region.base + offset);
        var free_list = newFreeList();

        var frame_idx: usize = 0;
        var region_idx: usize = 0;
        for (pmm.entries) |entry| {
            if (entry.type != .usable) continue;
            defer region_idx += 1;

            // NOTE: assuming 4KiB frames
            var entry_frame_count = entry.len() / 4096;
            var frame_address = entry.start(4096);

            while (entry_frame_count > 0) {
                const order = @min(std.math.log2(entry_frame_count), ranks-1);
                const order_frame_size = std.math.pow(usize, 2, order);
                entry_frame_count -= order_frame_size;
                // NOTE: assuming 4KiB frames
                defer frame_address += entry_frame_count * 4096;

                const start_frame_idx = frame_idx;
                var free: ?Frame.Free = null;

                const next_free = free_list[order];
                free = .{
                    .order = order,
                    .next_free = next_free,
                    .previous_free = null,
                };

                if (next_free) |next_free_idx| {
                    var next_free_frame = &frames[next_free_idx];
                    if (next_free_frame.free) |*next_free_frame_free| {
                        next_free_frame_free.previous_free = start_frame_idx;
                    } else {
                        std.debug.panic("attempted to insert next free frame on invalid frame", .{});
                    }
                }

                free_list[order] = start_frame_idx;
                for (0..order_frame_size) |i| {
                    frames[start_frame_idx+i] = .{
                        .free = if (i == 0) free else null,
                        .region = region_idx,
                        .flags = .initEmpty(),
                        // NOTE: assuming 4KiB frames
                        .address = frame_address + i * 0x1000,
                    };

                    frame_idx += 1;
                }
            }
        }

        serial.log("{} vs {}\n", .{frame_idx, frame_count});
        std.debug.assert(frame_idx == frame_count);
        return .{
            .frames = frames[0..frame_count],
            .free_list = free_list,
        };
    }

    // TODO: feels like this should have a different interface?
    pub fn allocFrame(self: *FrameAllocator) ?usize {
        _ = self;
        return null;
    }

    // TODO: feels like this should have a different interface?
    pub fn allocContiguous(self: *FrameAllocator) ?usize {
        _ = self;
        @panic("todo");
    }
};
