const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");

const Flag = enum(usize) {
    reserved,
    allocated,

    // NOTE: keep this at the end
    max,

    fn value(self: Flag) usize {
        return @intFromEnum(self);
    }
};

pub const Frame = struct {
    const Flags = std.StaticBitSet(Flag.max.value());

    order: u8,
    flags: Flags,
    address: usize,

    pub fn reserved(address: usize) Frame {
        var flags: Flags = .initEmpty();
        flags.set(Flag.reserved.value());

        return .{
            .order = 0,
            .flags = flags,
            .address = address
        };
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

pub fn createFrameList(entries: []const *PhysicalMemoryManager.Entry, offset: u64) ![]Frame {
    const pmm: PhysicalMemoryManager = .{
        .entries = entries,
        .offset = offset,
    };

    const frame_count = pmm.count_usable_frames();
    const frame_list_size = frame_count * @sizeOf(Frame);

    const region = pmm.find_region_for_size(frame_list_size) orelse
        return error.couldNotFindFrame;

    var frames: [*]Frame = @ptrFromInt(region.base + offset);
    const frames_start_address = @intFromPtr(frames);
    const frames_end_address = frames_start_address + frame_list_size;

    var frame_idx: usize = 0;
    for (pmm.entries) |entry| {
        if (entry.type != .usable) continue;

        // NOTE: assuming 4KiB frames
        const entry_frame_count = entry.len() / 4096;
        const entry_start = entry.start(4096);

        for (0..entry_frame_count) |idx| {
            var flags: Frame.Flags = .initEmpty();
            const address = entry_start + idx * 4096;

            if (address >= frames_start_address and address <= frames_end_address) {
                flags.set(Flag.reserved.value());
            }

            frames[frame_idx] = .{
                .order = 0,
                .flags = flags,
                .address = address,
            };

            frame_idx += 1;
        }
    }

    return frames[0..frame_count];
}

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

    fn find_region_for_size(self: *const PhysicalMemoryManager, size: usize) ?*limine.MemoryMapFeature.Response.Entry {
        // NOTE: this function currently just finds the first memory map entry
        // that is usable and can fit the data. I'm not sure if there is a
        // better way to find a region, but this should be fine I think.
        for (self.entries) |entry| {
            if (entry.type != .usable) continue;
            if (entry.length < size) continue;

            return entry;
        }

        return null;
    }
};
