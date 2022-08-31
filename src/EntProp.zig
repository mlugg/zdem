const std = @import("std");
const Demo = @import("Demo.zig");

idx: u32,
value: Value,

pub const Value = union(enum) {
    int: i128,
    float: f32,
    vec3: [3]f32,
    vec2: [2]f32,
    string: []u8,
    array: []Value,

    pub fn zero(info: Demo.ProcessedClass.Prop.SendInfo) Value {
        return switch (info) {
            .int => .{ .int = 0 },
            .float => .{ .float = 0 },
            .vec3 => .{ .vec3 = .{ 0, 0, 0 } },
            .vec2 => .{ .vec2 = .{ 0, 0 } },
            .string => .{ .string = &.{} },
            .array => .{ .array = &.{} },
        };
    }

    pub fn format(value: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, w: anytype) !void {
        _ = options;
        _ = fmt;
        switch (value) {
            .int => |x| try std.fmt.format(w, "{}", .{x}),
            .float => |x| try std.fmt.format(w, "{}", .{x}),
            .vec3 => |x| try std.fmt.format(w, "{any}", .{x}),
            .vec2 => |x| try std.fmt.format(w, "{any}", .{x}),
            .string => |x| try std.fmt.format(w, "{s}", .{x}),
            .array => |x| try std.fmt.format(w, "array {any}", .{x}),
        }
    }
};
