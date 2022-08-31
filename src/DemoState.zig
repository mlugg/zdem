const std = @import("std");

const Demo = @import("Demo.zig");
const processDataTables = @import("data_table_flatten.zig").processDataTables;

const DemoState = @This();

const max_frames = 128; // dear fucking god i hope this is enough fuck you valve

custom_data_callbacks: ?[][]u8,

send_tables: std.StringArrayHashMap(*Demo.DataTables.SendTable),
server_classes: std.StringArrayHashMap(*Demo.DataTables.ServerClass),
processed_classes: std.StringArrayHashMap(Demo.ProcessedClass),

string_tables: std.StringArrayHashMap(*Demo.StringTable),

cur_server_tick: u32,

_allocator: std.mem.Allocator,

// We can't stack allocate this because it's literally several megabytes
_frames: []Demo.EntityFrame, // length = max_frames*2
_first_frame: usize,
_frame_count: usize,

pub fn entityFrames(self: *DemoState) []Demo.EntityFrame {
    return self._frames[self._first_frame .. self._first_frame + self._frame_count];
}

pub fn lastEntityFrame(self: *DemoState) ?Demo.EntityFrame {
    const frames = self.entityFrames();
    return if (frames.len == 0) null else frames[frames.len - 1];
}

pub fn addEntityFrame(self: *DemoState, frame: Demo.EntityFrame) void {
    if (self._frame_count == max_frames) {
        if (self._first_frame == max_frames) {
            std.mem.copy(Demo.EntityFrame, self._frames[0..], self._frames[max_frames + 1 ..]);
            self._first_frame = 0;
        } else {
            self._first_frame += 1;
        }
    } else {
        self._frame_count += 1;
    }

    self._frames[self._first_frame + self._frame_count - 1] = frame;
}

pub fn init(allocator: std.mem.Allocator) !DemoState {
    return .{
        .custom_data_callbacks = null,
        .send_tables = std.StringArrayHashMap(*Demo.DataTables.SendTable).init(allocator),
        .server_classes = std.StringArrayHashMap(*Demo.DataTables.ServerClass).init(allocator),
        .processed_classes = std.StringArrayHashMap(Demo.ProcessedClass).init(allocator),
        .string_tables = std.StringArrayHashMap(*Demo.StringTable).init(allocator),
        .cur_server_tick = 0,
        ._allocator = allocator,
        ._frames = try allocator.alloc(Demo.EntityFrame, max_frames * 2),
        ._first_frame = 0,
        ._frame_count = 0,
    };
}

pub fn deinit(self: *DemoState) void {
    self.send_tables.deinit();
    self.server_classes.deinit();
    self.processed_classes.deinit();
    self.string_tables.deinit();
    self._allocator.free(self._frames);
}

pub fn initDataTables(
    self: *DemoState,
    dt: Demo.DataTables,
    raw_allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
) !void {
    self.send_tables.clearRetainingCapacity();
    self.server_classes.clearRetainingCapacity();
    self.processed_classes.clearRetainingCapacity();

    for (dt.send_tables) |*st| {
        try self.send_tables.put(st.name, st);
    }

    for (dt.server_classes) |*sc| {
        try self.server_classes.put(sc.class_name, sc);
    }

    try processDataTables(raw_allocator, arena, self);
}

pub fn getBaseline(self: *DemoState, class_idx: u32) ![]Demo.EntProp.Value {
    if (self.string_tables.get("instancebaseline")) |st| {
        switch (st.parsed) {
            .instance_baseline => |baselines| {
                if (class_idx < baselines.classes.len) {
                    return baselines.classes[class_idx].props;
                }
                return error.ClassOutOfRange;
            },
            else => return error.RawEntityBaselines,
        }
    } else {
        return error.NoBaslines;
    }
}
