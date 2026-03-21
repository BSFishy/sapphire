const std = @import("std");
const builtin = @import("builtin");

var kernel_panic_allocator_bytes: [100 * 1024]u8 = undefined;
var kernel_panic_allocator_state = std.heap.FixedBufferAllocator.init(kernel_panic_allocator_bytes[0..]);
const kernel_panic_allocator = &kernel_panic_allocator_state.allocator;

extern var __debug_info_start: u8;
extern var __debug_info_end: u8;
extern var __debug_abbrev_start: u8;
extern var __debug_abbrev_end: u8;
extern var __debug_str_start: u8;
extern var __debug_str_end: u8;
extern var __debug_line_start: u8;
extern var __debug_line_end: u8;
extern var __debug_ranges_start: u8;
extern var __debug_ranges_end: u8;

fn dwarfSectionFromSymbolAbs(start: *u8, end: *u8) std.debug.Dwarf.Section {
    return std.debug.Dwarf.Section{
        .offset = 0,
        .size = @intFromPtr(end) - @intFromPtr(start),
    };
}

fn dwarfSectionFromSymbol(start: *u8, end: *u8) std.debug.Dwarf.Section {
    return std.debug.Dwarf.Section{
        .offset = @intFromPtr(start),
        .size = @intFromPtr(end) - @intFromPtr(start),
    };
}

pub fn getSelfDebugInfo() !*std.debug.Dwarf {
    const S = struct {
        var have_self_debug_info = false;
        var self_debug_info: std.debug.Dwarf = undefined;

        var in_stream_state = std.io.InStream(anyerror){ .readFn = readFn };
        var in_stream_pos: usize = 0;
        const in_stream = &in_stream_state;

        fn readFn(self: *std.io.InStream(anyerror), buffer: []u8) anyerror!usize {
            _ = self;
            const ptr = @as([*]const u8, @ptrFromInt(in_stream_pos));
            @memcpy(buffer.ptr[0..buffer.len], ptr[0..buffer.len]);
            in_stream_pos += buffer.len;
            return buffer.len;
        }

        const SeekableStream = std.io.SeekableStream(anyerror, anyerror);
        var seekable_stream_state = SeekableStream{
            .seekToFn = seekToFn,
            .seekForwardFn = seekForwardFn,

            .getPosFn = getPosFn,
            .getEndPosFn = getEndPosFn,
        };
        const seekable_stream = &seekable_stream_state;

        fn seekToFn(self: *SeekableStream, pos: usize) anyerror!void {
            _ = self;
            in_stream_pos = pos;
        }
        fn seekForwardFn(self: *SeekableStream, pos: isize) anyerror!void {
            _ = self;
            in_stream_pos = @as(usize, @bitCast(@as(isize, @bitCast(in_stream_pos)) +% pos));
        }
        fn getPosFn(self: *SeekableStream) anyerror!usize {
            _ = self;
            return in_stream_pos;
        }
        fn getEndPosFn(self: *SeekableStream) anyerror!usize {
            _ = self;
            return @intFromPtr(&__debug_ranges_end);
        }
    };
    if (S.have_self_debug_info) return &S.self_debug_info;

    S.self_debug_info = std.debug.Dwarf{
        // .dwarf_seekable_stream = S.seekable_stream,
        // .dwarf_in_stream = S.in_stream,
        .endian = builtin.Endian.Little,
        // .debug_info = dwarfSectionFromSymbol(&__debug_info_start, &__debug_info_end),
        // .debug_abbrev = dwarfSectionFromSymbolAbs(&__debug_abbrev_start, &__debug_abbrev_end),
        // .debug_str = dwarfSectionFromSymbolAbs(&__debug_str_start, &__debug_str_end),
        // .debug_line = dwarfSectionFromSymbol(&__debug_line_start, &__debug_line_end),
        // .debug_ranges = dwarfSectionFromSymbolAbs(&__debug_ranges_start, &__debug_ranges_end),
        .abbrev_table_list = undefined,
        .compile_unit_list = undefined,
    };
    try S.self_debug_info.open(kernel_panic_allocator);
    // try std.debug.openDwarfDebugInfo(&S.self_debug_info, kernel_panic_allocator);
    return &S.self_debug_info;
}
