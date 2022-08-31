const std = @import("std");

const Demo = @import("Demo.zig");

const EntityFrame = @This();

server_tick: u32 = 0,
entities: [2048]?Entity = [_]?Entity{null} ** 2048,

pub const Entity = struct {
    class_idx: u32,
    serial: u10,
    in_pvs: bool,
    props: []Demo.EntProp.Value, // indices correspond to prop indices in the class
};

pub fn reset(self: *EntityFrame) void {
    std.mem.set(?Entity, self.entities, null);
}
