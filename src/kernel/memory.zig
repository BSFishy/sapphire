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

pub const Frame = struct {
    const Flags = std.StaticBitSet(Flag.max.value());

    order: usize,
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
        if (address < start) {
            return false;
        }

        if (address > end) {
            return false;
        }

        return true;
    }

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

pub fn newFrameAllocator(entries: []const *PhysicalMemoryManager.Entry, offset: u64) !FrameAllocator {
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

    var capacities: [ranks]usize = undefined;
    for (0..ranks) |i| {
        capacities[i] = 0;
    }

    var frame_idx: usize = 0;
    for (pmm.entries) |entry| {
        if (entry.type != .usable) continue;

        // NOTE: assuming 4KiB frames
        const entry_frame_count = entry.len() / 4096;
        const entry_start = entry.start(4096);

        var entry_frame_counter = entry_frame_count;
        while (entry_frame_counter > 0) {
            const order = std.math.log2(entry_frame_counter);
            const order_size = std.math.pow(u64, 2, order);

            capacities[order] += 1;
            entry_frame_counter -= order_size;
        }

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

    inline for (1..ranks) |i| {
        const order = ranks - i;
        capacities[order-1] += capacities[order] * 2;
    }

    var size: usize = 0;
    inline for (capacities) |cap| {
        size += cap * @sizeOf(usize);
    }

    const free_region = pmm.find_region_for_size(size) orelse return error.insufficientMemory;
    var free_lists: [ranks][*]usize = undefined;
    var region_offset: usize = 0;
    inline for (0..ranks, capacities) |order, cap| {
        free_lists[order] = @ptrFromInt(free_region.base + region_offset + offset);
        region_offset += cap * @sizeOf(usize);
    }

    var lengths: [ranks]usize = undefined;
    inline for (0..ranks) |i| {
        lengths[i] = 0;
    }

    var frame_allocator: FrameAllocator = .{
        .frames = frames[0..frame_count],
        .free_lists = free_lists,
        .lengths = lengths,
    };

    for (frames, 0..frame_count) |*te, i| {
        if (te.containsRegion(free_region.base, free_region.base + size)) {
            te.flags.set(Flag.reserved.value());
            continue;
        }

        frame_allocator.insert(0, i);
    }

    return frame_allocator;
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

            entry.type = .reserved;
            return entry;
        }

        return null;
    }
};

pub const FrameAllocator = struct {
    const Self = @This();

    frames: []Frame,
    // TODO: realistically, we could probably get away with a u32 here and
    // cut this memory usage in half. ill need to think about if that is
    // really the case.
    free_lists: [ranks][*]usize,
    lengths: [ranks]usize,

    pub fn allocFrame(self: *Self) ?usize {
        return self.alloc(0);
    }

    pub fn allocContiguous(self: *Self, count: usize) ?usize {
        // TODO: this could actually be a lot more optimized, where we
        // actually only allocate the number of frames we need instead of
        // the smallest order that fits. i dont need contiguous memory much
        // at the moment but when that day comes, here is my message to you:
        // i have decided this is your problem. X3
        const order = std.math.log2(count);
        return self.alloc(order);
    }

    fn alloc(self: *Self, order: usize) ?usize {
        if (order >= ranks) std.debug.panic("invalid order {}", .{order});

        if (self.lengths[order] == 0) {
            if (order+1 == ranks) return null;

            const frame = self.alloc(order+1) orelse return null;
            const buddy = if (frame % 2 == 0) frame + 1 else frame - 1;

            self.frames[frame].order = order;
            self.frames[buddy].order = order;

            self.frames[frame].allocate();
            self.insert(order, buddy);

            return frame;
        }

        const free_list = self.free_lists[order];
        const frame = free_list[self.lengths[order]];
        self.lengths[order] -= 1;

        self.frames[frame].order = order;
        self.frames[frame].allocate();

        return frame;
    }

    fn insert(self: *Self, order: usize, frame: usize) void {
        std.debug.assert(order < ranks);

        const free_list = self.free_lists[order];
        const length = self.lengths[order];
        for (free_list, 0..length) |element, i| {
            if (element <= frame) {
                continue;
            }

            @memcpy(free_list[i+1 .. length+1], free_list[i..length]);
            free_list[i] = frame;
            return;
        }

        free_list[length] = frame;
        self.lengths[order] += 1;
    }

    pub fn free(self: *Self, frame_idx: usize) void {
        const buddy_idx = if (frame_idx % 2 == 0) frame_idx + 1 else frame_idx - 1;

        const frame = &self.frames[frame_idx];
        const buddy = self.frames[buddy_idx];

        const order = frame.order;
        if (!frame.isContiguous(&buddy)) {
            self.insert(order, frame_idx);
            return;
        }

        if (order+1 != ranks) {
            const free_list = self.free_lists[order];
            const length = self.lengths[order];
            for (free_list, 0..length) |element, i| {
                if (element != buddy_idx) continue;

                @memcpy(free_list[i..length-1], free_list[i+1..length]);
                self.lengths[order] -= 1;

                frame.order += 1;
                self.free(frame_idx);

                return;
            }
        }

        self.insert(order, frame_idx);
    }
};
