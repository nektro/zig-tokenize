const std = @import("std");
const tokenize = @import("tokenize");

pub fn main() !void {
    var file = try std.fs.cwd().openFile("example.js", .{});
    defer file.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var content = try file.reader().readAllAlloc(alloc, 1024);

    var tok_doc = try tokenize.do(alloc, "{}();,=+", content);
    defer tok_doc.deinit(alloc);
    std.log.info("Success!", .{});
    std.log.info("parsed {d} tokens", .{tok_doc.tokens.len});
    std.debug.print("\n", .{});

    for (tok_doc.tokens.items(.tag)) |item, i| {
        std.debug.print("{s}\t{s}\n", .{ @tagName(item), tok_doc.str(@intCast(u32, i)) });
    }
}
