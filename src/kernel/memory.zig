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

fn inRegion(start: usize, end: usize, address: usize) bool {
    return start <= address and address < end;
}

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
    const Allocated = struct {
        order: usize,
        start_idx: usize,
    };
    const State = union(enum) {
        free: Free,
        allocated: Allocated,
    };

    state: ?State,

    region: usize,
    flags: Flags,
    address: usize,

    pub fn isContiguous(self: *const Frame, other: *const Frame, order: usize) bool {
        const lower = if (self.address > other.address) other else self;
        const higher = if (self.address < other.address) other else self;

        // NOTE: assumes 4KiB frames
        const size = std.math.pow(usize, 2, order) * 0x1000;
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
            const entry_start = entry.start(0x1000);
            const entry_end = entry.end(0x1000);
            const aligned_size: u64 = std.mem.alignForward(u64, @intCast(size), 0x1000);
            if (entry_end - entry_start < aligned_size) continue;

            return .{
                .base = entry_start,
                .length = aligned_size,
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

    fn markAllocated(self: *FrameAllocator, frame_idx: usize, order: usize) void {
        var frame = &self.frames[frame_idx];
        frame.state = .{ .allocated = .{ .order = order, .start_idx = frame_idx } };
        frame.allocate();
    }

    fn freelistPop(self: *FrameAllocator, rank: usize) ?usize {
        if (rank >= ranks) std.debug.panic("invalid rank size {}", .{rank});

        const head_idx = self.free_list[rank] orelse return null;
        var head_frame = &self.frames[head_idx];
        const head_state = head_frame.state orelse std.debug.panic("frame {} on freelist has no state", .{head_idx});
        const head_free = switch (head_state) {
            .free => |free_state| free_state,
            .allocated => std.debug.panic("frame {} on freelist is allocated", .{head_idx}),
        };

        self.free_list[rank] = head_free.next_free;
        if (head_free.next_free) |next_idx| {
            const next_frame = &self.frames[next_idx];
            var next_state = next_frame.state orelse std.debug.panic("attempted to update next free frame on invalid frame", .{});
            switch (next_state) {
                .free => |*next_free| next_free.previous_free = null,
                .allocated => std.debug.panic("attempted to update next free frame on allocated frame", .{}),
            }
        }

        head_frame.state = null;
        head_frame.deallocate();

        return head_idx;
    }

    fn freelistRemove(self: *FrameAllocator, rank: usize, frame_idx: usize) void {
        if (rank >= ranks) std.debug.panic("invalid rank size {}", .{rank});

        var frame = &self.frames[frame_idx];
        const frame_state = frame.state orelse std.debug.panic("attempted to remove free frame with no state", .{});
        const frame_free = switch (frame_state) {
            .free => |free_state| free_state,
            .allocated => std.debug.panic("attempted to remove allocated frame from freelist", .{}),
        };
        if (frame_free.order != rank) std.debug.panic("freelist remove order mismatch {} != {}", .{ frame_free.order, rank });

        if (frame_free.previous_free) |prev_idx| {
            const prev_frame = &self.frames[prev_idx];
            var prev_state = prev_frame.state orelse std.debug.panic("invalid previous free frame", .{});
            switch (prev_state) {
                .free => |*prev_free| prev_free.next_free = frame_free.next_free,
                .allocated => std.debug.panic("previous free frame is allocated", .{}),
            }
        } else {
            self.free_list[rank] = frame_free.next_free;
        }

        if (frame_free.next_free) |next_idx| {
            const next_frame = &self.frames[next_idx];
            var next_state = next_frame.state orelse std.debug.panic("invalid next free frame", .{});
            switch (next_state) {
                .free => |*next_free| next_free.previous_free = frame_free.previous_free,
                .allocated => std.debug.panic("next free frame is allocated", .{}),
            }
        }

        frame.state = null;
        frame.deallocate();
    }

    fn freelistPush(self: *FrameAllocator, rank: usize, frame_idx: usize) void {
        if (rank >= ranks) std.debug.panic("invalid rank size {}", .{rank});

        var frame = &self.frames[frame_idx];
        frame.deallocate();
        frame.state = .{ .free = .{ .order = rank, .next_free = self.free_list[rank], .previous_free = null } };

        if (self.free_list[rank]) |old_head_idx| {
            const old_head = &self.frames[old_head_idx];
            var old_head_state = old_head.state orelse std.debug.panic("attempted to update free list head on invalid frame", .{});
            switch (old_head_state) {
                .free => |*old_head_free| old_head_free.previous_free = frame_idx,
                .allocated => std.debug.panic("attempted to update free list head on allocated frame", .{}),
            }
        }

        self.free_list[rank] = frame_idx;
    }

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
            const entry_start = entry.start(0x1000);
            const entry_end = entry.end(0x1000);
            var entry_frame_count: usize = @intCast((entry_end - entry_start) / 0x1000);

            var start_address = entry_start;
            while (entry_frame_count > 0) {
                const inFrameAllocator = inRegion(region.base, region.base + frame_list_size, start_address);
                var run_size = blk: {
                    var len: usize = 1;
                    while (true) : (len += 1) {
                        const next_address = start_address + len * 0x1000;
                        if (next_address >= entry_end) break :blk len;

                        const idxInFrameAllocator = inRegion(region.base, region.base + frame_list_size, next_address);
                        if (inFrameAllocator != idxInFrameAllocator) break :blk len;
                    }
                };
                if (run_size == 0) std.debug.panic("invalid region 0x{x} size of zero", .{start_address});

                while (run_size > 0) {
                    const order = @min(std.math.log2(run_size), ranks - 1);
                    const order_frame_size = std.math.pow(usize, 2, order);
                    entry_frame_count -= order_frame_size;

                    const start_frame_idx = frame_idx;
                    const state = if (!inFrameAllocator) blk: {
                        const next_free = free_list[order];
                        if (next_free) |next_free_idx| {
                            const next_free_frame = &frames[next_free_idx];
                            var next_free_state = next_free_frame.state orelse std.debug.panic("attempted to insert next free frame on invalid frame", .{});
                            switch (next_free_state) {
                                .free => |*next_free_frame_free| next_free_frame_free.previous_free = start_frame_idx,
                                .allocated => std.debug.panic("attempted to insert next free frame on allocated frame", .{}),
                            }
                        }

                        free_list[order] = start_frame_idx;
                        break :blk Frame.State{ .free = .{ .order = order, .next_free = next_free, .previous_free = null } };
                    } else null;

                    for (0..order_frame_size) |i| {
                        frames[start_frame_idx + i] = .{
                            .state = if (i == 0) state else null,
                            .region = region_idx,
                            .flags = blk: {
                                var flags = Frame.Flags.initEmpty();
                                if (inFrameAllocator) flags.set(Flag.reserved.value());
                                break :blk flags;
                            },
                            .address = start_address + i * 0x1000,
                        };

                        frame_idx += 1;
                    }

                    start_address += order_frame_size * 0x1000;
                    run_size -= order_frame_size;
                }
            }
        }

        if (frame_idx != frame_count) std.debug.panic("didnt write enough frames. expected {} but wrote {}", .{ frame_count, frame_idx });
        return .{
            .frames = frames[0..frame_count],
            .free_list = free_list,
        };
    }

    fn allocRank(self: *FrameAllocator, rank: usize) ?usize {
        // happy path there is a free block at the desired rank
        if (self.freelistPop(rank)) |rank_free| {
            self.markAllocated(rank_free, rank);
            return rank_free;
        }

        if (rank + 1 == ranks) return null;

        const higher_rank = self.allocRank(rank + 1) orelse return null;
        const rank_size = std.math.pow(usize, 2, rank);
        const buddy_idx = higher_rank + rank_size;

        if (buddy_idx >= self.frames.len) return null;
        self.freelistPush(rank, buddy_idx);

        self.markAllocated(higher_rank, rank);

        return higher_rank;
    }

    pub fn allocFrame(self: *FrameAllocator) ?usize {
        const frame_idx = self.allocRank(0) orelse return null;
        const frame = self.frames[frame_idx];
        return frame.address;
    }

    pub fn allocContiguous(self: *FrameAllocator, count: usize) ?usize {
        const rank = std.math.log2(count);
        if (rank >= ranks) return null;

        const frame_idx = self.allocRank(rank) orelse return null;
        const frame = self.frames[frame_idx];
        return frame.address;
    }

    pub fn free(self: *FrameAllocator, address: usize) void {
        if (address % 0x1000 != 0) std.debug.panic("invalid address to free {}", .{address});

        var low: usize = 0;
        var high: usize = self.frames.len;
        var frame_idx: ?usize = null;
        while (low < high) {
            const mid = (low + high) / 2;
            const mid_address = self.frames[mid].address;
            if (mid_address == address) {
                frame_idx = mid;
                break;
            }

            if (mid_address < address) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        const start_idx = frame_idx orelse std.debug.panic("attempted to free non-frame address {}", .{address});
        var frame = &self.frames[start_idx];
        const state = frame.state orelse std.debug.panic("attempted to free frame with no state {}", .{address});
        const allocated = switch (state) {
            .allocated => |alloc| alloc,
            .free => std.debug.panic("attempted to free free frame {}", .{address}),
        };
        if (allocated.start_idx != start_idx) std.debug.panic("attempted to free non-start frame {}", .{address});

        var order = allocated.order;
        frame.state = null;
        frame.deallocate();

        var base_idx = start_idx;
        var base_address = frame.address;
        while (order + 1 < ranks) : (order += 1) {
            const size_bytes = (std.math.pow(usize, 2, order)) * 0x1000;
            const buddy_address = base_address ^ size_bytes;

            var buddy_low: usize = 0;
            var buddy_high: usize = self.frames.len;
            var buddy_idx: ?usize = null;
            while (buddy_low < buddy_high) {
                const mid = (buddy_low + buddy_high) / 2;
                const mid_address = self.frames[mid].address;
                if (mid_address == buddy_address) {
                    buddy_idx = mid;
                    break;
                }

                if (mid_address < buddy_address) {
                    buddy_low = mid + 1;
                } else {
                    buddy_high = mid;
                }
            }

            const buddy_frame_idx = buddy_idx orelse break;
            const buddy_frame = &self.frames[buddy_frame_idx];
            const buddy_state = buddy_frame.state orelse break;
            const buddy_free = switch (buddy_state) {
                .free => |buddy_free_state| buddy_free_state,
                .allocated => break,
            };
            if (buddy_free.order != order) break;

            self.freelistRemove(order, buddy_frame_idx);
            if (buddy_address < base_address) {
                base_idx = buddy_frame_idx;
                base_address = buddy_address;
            }
        }

        self.freelistPush(order, base_idx);
    }
};
