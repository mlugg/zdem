const std = @import("std");

const Demo = @import("Demo.zig");

name: []u8,
server_entries: []Entry,
client_entries: ?[]Entry,

parsed: union(enum) {
    none,
    instance_baseline: struct {
        classes: []Baseline,
    },
},

pub const Entry = struct {
    name: []u8,
    data: ?[]u8,
};

pub const Baseline = struct {
    props: []Demo.EntProp.Value, // guaranteed to have the same length as class.props
};
