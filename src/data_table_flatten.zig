const std = @import("std");

const Demo = @import("Demo.zig");

const Flattener = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    tables: *const std.StringArrayHashMap(*Demo.DataTables.SendTable),
    props: std.ArrayList(Demo.ProcessedClass.Prop),
    exclusions: std.ArrayList(Exclusion),

    fn deinit(self: Flattener) void {
        self.props.deinit();
        self.exclusions.deinit();
    }

    const Exclusion = struct {
        table: []const u8,
        prop: []const u8,
    };

    fn isExcluded(self: Flattener, table: []const u8, prop: []const u8) bool {
        for (self.exclusions.items) |excl| {
            if (std.mem.eql(u8, table, excl.table) and std.mem.eql(u8, prop, excl.prop)) return true;
        }
        return false;
    }

    const ProcessError = error{
        BadNestedTable,
        ArrayOfTables,
        UnparentedArrayElement,
        ArrayWithoutChild,
    } || std.mem.Allocator.Error;

    fn gather(self: *Flattener, table: *Demo.DataTables.SendTable, prefix: []const u8) ProcessError!void {
        var props_tmp = std.ArrayList(Demo.ProcessedClass.Prop).init(self.allocator);
        defer props_tmp.deinit();

        try self.iterate(&props_tmp, table, prefix);

        try self.props.appendSlice(props_tmp.items);
    }

    fn iterate(self: *Flattener, props: *std.ArrayList(Demo.ProcessedClass.Prop), table: *Demo.DataTables.SendTable, prefix: []const u8) ProcessError!void {
        var array_prop: ?Demo.ProcessedClass.Prop.SendInfo = null;

        for (table.props) |raw_prop| {
            if (raw_prop.info == .exclude) continue;
            if (self.isExcluded(table.name, raw_prop.name)) continue;

            if (raw_prop.info == .data_table) {
                if (array_prop != null) {
                    return error.UnparentedArrayElement;
                }

                if (raw_prop.flags.inside_array) {
                    return error.ArrayOfTables;
                }

                const nested = self.tables.get(raw_prop.info.data_table.name) orelse return error.BadNestedTable;
                const nested_prefix = try std.mem.concat(self.allocator, u8, &.{ prefix, raw_prop.name, "." });
                defer self.allocator.free(nested_prefix);

                if (raw_prop.flags.collapsible) {
                    try self.iterate(props, nested, nested_prefix);
                } else {
                    try self.gather(nested, nested_prefix);
                }
            } else {
                const send_info: Demo.ProcessedClass.Prop.SendInfo = switch (raw_prop.info) {
                    .int => |int| .{ .int = .{
                        .bits = int.bits,
                        .signed = int.signed,
                    } },
                    .float => |float| .{ .float = float },
                    .vec3 => |vec3| .{ .vec3 = vec3 },
                    .vec2 => |vec2| .{ .vec2 = vec2 },
                    .string => .string,
                    .array => |array| if (array_prop) |nested| blk: {
                        array_prop = null;
                        const nested_ptr = try self.arena.create(Demo.ProcessedClass.Prop.SendInfo);
                        nested_ptr.* = nested;
                        break :blk .{ .array = .{
                            .length = array.length,
                            .elem = nested_ptr,
                        } };
                    } else return error.ArrayWithoutChild,
                    .data_table => unreachable,
                    .exclude => unreachable,
                };

                if (array_prop != null) {
                    return error.UnparentedArrayElement;
                }

                if (raw_prop.flags.inside_array) {
                    array_prop = send_info;
                } else {
                    const full_name = try std.mem.concat(self.arena, u8, &.{ prefix, raw_prop.name });
                    try props.append(.{
                        .name = full_name,
                        .priority = if (raw_prop.flags.changes_often) std.math.min(raw_prop.priority, 64) else raw_prop.priority,
                        .info = send_info,
                        .flags = .{
                            .proxy_always_yes = raw_prop.flags.proxy_always_yes,
                        },
                    });
                }
            }
        }
    }

    const ScanExcludesError = error{
        BadNestedTable,
        ArrayOfTables,
        UnparentedArrayElement,
        ArrayWithoutChild,
    } || std.mem.Allocator.Error;

    fn scanExcludes(self: *Flattener, table: *Demo.DataTables.SendTable) ScanExcludesError!void {
        for (table.props) |raw_prop| {
            switch (raw_prop.info) {
                .data_table => |dt| {
                    const nested = self.tables.get(dt.name) orelse return error.BadNestedTable;
                    try self.scanExcludes(nested);
                },
                .exclude => |exclude| {
                    try self.exclusions.append(.{
                        .table = exclude.table,
                        .prop = raw_prop.name,
                    });
                },
                else => {},
            }
        }
    }

    fn run(
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        tables: *const std.StringArrayHashMap(*Demo.DataTables.SendTable),
        root_name: []const u8,
    ) ![]Demo.ProcessedClass.Prop {
        if (tables.get(root_name)) |root_table| {
            var flattener = Flattener{
                .allocator = allocator,
                .arena = arena,
                .tables = tables,
                .props = std.ArrayList(Demo.ProcessedClass.Prop).init(allocator),
                .exclusions = std.ArrayList(Exclusion).init(allocator),
            };
            defer flattener.deinit();

            try flattener.scanExcludes(root_table);

            try flattener.gather(root_table, "");
            return flattener.props.toOwnedSlice();
        } else {
            return error.BadServerClass;
        }
    }
};

pub fn processDataTables(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *Demo.DemoState) !void {
    // clear existing classes (TODO: refactor to allow incremental changes, in which
    // case we shouldn't do this - have DemoState.initDataTables do it instead)
    state.processed_classes.clearRetainingCapacity();

    // iterate over classes
    for (state.server_classes.values()) |class| {
        const props = try Flattener.run(allocator, arena, &state.send_tables, class.table_name);
        defer allocator.free(props);

        var priorities_mask: u256 = 0;
        for (props) |prop| {
            priorities_mask |= @as(u256, 1) << prop.priority;
        }

        var sorted_count: usize = 0;
        var priority: u9 = 0;
        while (priority < 256) : (priority += 1) {
            if (priorities_mask & (@as(u256, 1) << @intCast(u8, priority)) != 0) {
                // perform swapification
                for (props[sorted_count..]) |*prop| {
                    if (prop.priority == priority) {
                        std.mem.swap(Demo.ProcessedClass.Prop, prop, &props[sorted_count]);
                        sorted_count += 1;
                    }
                }
            }
        }

        std.debug.assert(sorted_count == props.len);

        // convert to a hashmap - alloc directly on arena since we'll only do one allocation
        var prop_map = std.StringArrayHashMap(Demo.ProcessedClass.Prop).init(arena);
        try prop_map.ensureTotalCapacity(props.len);
        for (props) |prop| {
            prop_map.putAssumeCapacityNoClobber(prop.name, prop);
        }

        try state.processed_classes.put(class.class_name, .{
            .name = class.class_name,
            .props = prop_map,
        });
    }
}
