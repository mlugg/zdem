const std = @import("std");
const Demo = @import("Demo.zig");

pub fn main() anyerror!void {
    //var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    //defer _ = gpa.deinit();

    var f = try std.fs.cwd().openFile("test.dem", .{});
    defer f.close();

    var br = std.io.bufferedReader(f.reader());

    //const demo = try Demo.parse(gpa.allocator(), br.reader());
    const demo = try Demo.parse(std.heap.c_allocator, br.reader());
    defer demo.deinit();

    //try std.io.getStdOut().writer().print("{}\n", .{demo});
    //try std.io.getStdOut().writer().print("TOTAL REQUESTED BYTES: {}\n", .{gpa.total_requested_bytes});
}
