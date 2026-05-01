const std = @import("std");
const limine = @import("limine.zig");

pub const HeapAllocator = struct {
    const Header = struct {
        size: usize,
        is_free: bool,
        next: ?*Header,
    };

    const Region = struct {
        start: usize,
        end: usize,
    };

    pub const Entry = limine.MemoryMapFeature.Response.Entry;

    head: ?*Header,

    fn alignUp(value: usize, alignment: usize) usize {
        return std.mem.alignForward(usize, value, alignment);
    }

    fn alignDown(value: usize, alignment: usize) usize {
        return std.mem.alignBackward(usize, value, alignment);
    }

    fn overlaps(a: Region, b: Region) bool {
        return a.start < b.end and b.start < a.end;
    }

    fn addRegion(self: *HeapAllocator, start: usize, end: usize) void {
        const region_size = end - start;
        if (region_size <= @sizeOf(Header)) return;

        const header: *Header = @ptrFromInt(start);
        header.* = .{
            .size = region_size - @sizeOf(Header),
            .is_free = true,
            .next = self.head,
        };

        self.head = header;
    }

    pub fn initAll(entries: []const *Entry, hhdm_offset: u64) HeapAllocator {
        var allocator: HeapAllocator = .{ .head = null };
        const alignment = @max(@alignOf(Header), @alignOf(usize));

        for (entries) |entry| {
            if (entry.type != .usable) continue;

            const phys_start = alignUp(@intCast(entry.base), alignment);
            const phys_end = alignDown(@intCast(entry.base + entry.length), alignment);
            if (phys_end <= phys_start) continue;

            const virt_start = phys_start + @as(usize, @intCast(hhdm_offset));
            const virt_end = phys_end + @as(usize, @intCast(hhdm_offset));
            allocator.addRegion(virt_start, virt_end);
        }

        return allocator;
    }

    pub fn initWithReserved(entries: []const *Entry, hhdm_offset: u64, reserved: []const Region) HeapAllocator {
        var allocator: HeapAllocator = .{ .head = null };
        const alignment = @max(@alignOf(Header), @alignOf(usize));

        for (entries) |entry| {
            if (entry.type != .usable) continue;

            var segments: [4]Region = .{
                .{ .start = alignUp(@intCast(entry.base), alignment), .end = alignDown(@intCast(entry.base + entry.length), alignment) },
                .{ .start = 0, .end = 0 },
                .{ .start = 0, .end = 0 },
                .{ .start = 0, .end = 0 },
            };
            var segment_count: usize = 1;

            for (reserved) |res| {
                var i: usize = 0;
                while (i < segment_count) : (i += 1) {
                    const seg = segments[i];
                    if (seg.end <= seg.start) continue;
                    if (!overlaps(seg, res)) continue;

                    const left = Region{ .start = seg.start, .end = @min(seg.end, res.start) };
                    const right = Region{ .start = @max(seg.start, res.end), .end = seg.end };

                    segments[i] = left;
                    if (right.end > right.start and segment_count < segments.len) {
                        segments[segment_count] = right;
                        segment_count += 1;
                    }
                }
            }

            for (segments[0..segment_count]) |seg| {
                if (seg.end <= seg.start) continue;
                const virt_start = seg.start + @as(usize, @intCast(hhdm_offset));
                const virt_end = seg.end + @as(usize, @intCast(hhdm_offset));
                allocator.addRegion(virt_start, virt_end);
            }
        }

        return allocator;
    }

    pub fn alloc(self: *HeapAllocator, size: usize) ?*u8 {
        const alignment = @max(@alignOf(Header), @alignOf(usize));
        const want = alignUp(size, alignment);

        var cur = self.head;
        while (cur) |header| {
            if (header.is_free and header.size >= want) {
                const remaining = header.size - want;
                if (remaining > @sizeOf(Header) + alignment) {
                    const next_header_addr = @intFromPtr(header) + @sizeOf(Header) + want;
                    const next_header: *Header = @ptrFromInt(next_header_addr);
                    next_header.* = .{
                        .size = remaining - @sizeOf(Header),
                        .is_free = true,
                        .next = header.next,
                    };
                    header.size = want;
                    header.next = next_header;
                }

                header.is_free = false;
                return @ptrCast(@as(*u8, @ptrFromInt(@intFromPtr(header) + @sizeOf(Header))));
            }

            cur = header.next;
        }

        return null;
    }

    pub fn free(self: *HeapAllocator, ptr: ?*u8) void {
        _ = self;
        if (ptr == null) return;
        const header: *Header = @ptrFromInt(@intFromPtr(ptr.?) - @sizeOf(Header));
        header.is_free = true;
    }
};
