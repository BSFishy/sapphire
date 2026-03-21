const std = @import("std");

const Dwarf = std.debug.Dwarf;
const Path = std.Build.Cache.Path;

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.args();
    _ = args.next();
    const input_path = args.next() orelse return usage();
    const output_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const cwd = std.fs.cwd();
    const output_file = try std.fs.createFileAbsolute(output_path, .{ .truncate = true });
    defer output_file.close();

    var parent_sections: Dwarf.SectionArray = Dwarf.null_section_array;
    var elf_module = try Dwarf.ElfModule.loadPath(
        gpa,
        .{ .root_dir = .{ .path = null, .handle = cwd }, .sub_path = input_path },
        null,
        null,
        &parent_sections,
        null,
    );
    defer elf_module.deinit(gpa);

    var buf: [1024]u8 = undefined;
    var file_writer = output_file.writer(&buf);

    var writer = &file_writer.interface;
    try writer.print(
        \\ pub const Symbol = struct {{
        \\     start: u64,
        \\     end: u64,
        \\     name: []const u8,
        \\     file_name: []const u8,
        \\ }};
        ,
        .{}
    );
    try writer.print("\n\npub const symbols: []const Symbol = &.{{\n", .{});

    for (elf_module.dwarf.func_list.items) |func| {
        const name = func.name orelse continue;
        const start = if (func.pc_range) |range| range.start else continue;
        const end = if (func.pc_range) |range| range.end else continue;

        const compile_unit = try elf_module.dwarf.findCompileUnit(start);
        const source_location = try elf_module.dwarf.getLineNumberInfo(gpa, compile_unit, start);

        try writer.print(
            "    .{{ .start = {}, .end = {}, .name = \"{s}\", .file_name = \"{s}\" }},\n",
            .{start, end, name, source_location.file_name}
        );
    }

    try writer.print("}};\n", .{});
    try writer.flush();
}

fn usage() !void {
    const stderr = std.fs.File.stderr();
    try stderr.writeAll(
        "usage: dwarf-extract <kernel.elf> <out-file>\n",
    );
    return error.InvalidArguments;
}
