const std = @import("std");
const DataTables = @import("data_table.zig").DataTables;
const FloatSendInfo = @import("data_table.zig").FloatSendInfo;

const RawFlags = packed struct {
    unsigned: bool,
    coord: bool,
    no_scale: bool,
    round_down: bool,
    round_up: bool,
    normal: bool,
    exclude: bool,
    xyze: bool,
    inside_array: bool,
    proxy_always_yes: bool,
    is_vector_elem: bool,
    collapsible: bool,
    coord_mp: bool,
    coord_mp_low_precision: bool,
    coord_mp_integral: bool,
    cell_coord: bool,
    cell_coord_low_precision: bool,
    cell_coord_integral: bool,
    changes_often: bool,
    _pad: u13,
};

const RawType = enum(u5) {
    int,
    float,
    vec3,
    vec2,
    string,
    array,
    data_table,
};

pub fn DataTableParser(comptime BitReader: type) type {
    return struct {
        raw_allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        br: BitReader,

        const Self = @This();

        pub fn parseSendTable(self: *Self) !DataTables.SendTable {
            const needs_decoder = try self.br.readBool();
            const name = try self.readString();

            const num_props = try self.br.readInt(u10);
            const props = try self.arena.alloc(DataTables.SendTable.Prop, num_props);
            for (props) |*prop| {
                const raw_type = std.meta.intToEnum(RawType, try self.br.readInt(u5)) catch {
                    return error.BadSendPropType;
                };
                prop.name = try self.readString();
                const raw_flags = @bitCast(RawFlags, @as(u32, try self.br.readInt(u19)));
                prop.priority = try self.br.readInt(u8);
                prop.flags = .{
                    .inside_array = raw_flags.inside_array,
                    .proxy_always_yes = raw_flags.proxy_always_yes,
                    .collapsible = raw_flags.collapsible,
                    .changes_often = raw_flags.changes_often,
                };

                if (raw_flags.exclude and raw_type != .data_table) {
                    prop.info = .{ .exclude = .{
                        .table = try self.readString(),
                    } };
                } else {
                    prop.info = switch (raw_type) {
                        .int => blk: {
                            // low and high are meaningless for ints
                            try self.br.reader().skipBytes(8, .{});
                            break :blk .{ .int = .{
                                .bits = try self.br.readInt(u7),
                                .signed = !raw_flags.unsigned,
                            } };
                        },
                        .float, .vec3, .vec2 => blk: {
                            const low = try self.br.readFloat(f32);
                            const high = try self.br.readFloat(f32);
                            const bits = try self.br.readInt(u7);

                            const send_info: FloatSendInfo = if (raw_flags.coord)
                                .coord
                            else if (raw_flags.coord_mp)
                                .coord_mp
                            else if (raw_flags.coord_mp_low_precision)
                                .coord_mp_low_precision
                            else if (raw_flags.coord_mp_integral)
                                .coord_mp_integral
                            else if (raw_flags.no_scale)
                                .no_scale
                            else if (raw_flags.normal)
                                .normal
                            else if (raw_flags.cell_coord) FloatSendInfo{
                                .cell_coord = .{ .bits = bits },
                            } else if (raw_flags.cell_coord_low_precision) FloatSendInfo{
                                .cell_coord_low_precision = .{ .bits = bits },
                            } else if (raw_flags.cell_coord_integral) FloatSendInfo{
                                .cell_coord_integral = .{ .bits = bits },
                            } else FloatSendInfo{
                                .ranged = .{
                                    .low = low,
                                    .high = high,
                                    .bits = bits,
                                    .round_up = raw_flags.round_up,
                                    .round_down = raw_flags.round_down,
                                },
                            };

                            break :blk switch (raw_type) {
                                .float => DataTables.SendTable.Prop.Info{ .float = send_info },
                                .vec3 => DataTables.SendTable.Prop.Info{ .vec3 = send_info },
                                .vec2 => DataTables.SendTable.Prop.Info{ .vec2 = send_info },
                                else => unreachable,
                            };
                        },
                        .string => blk: {
                            try self.br.reader().skipBytes(8, .{});
                            _ = try self.br.readInt(u7);
                            break :blk .string;
                        },
                        .array => .{ .array = .{
                            .length = try self.br.readInt(u10),
                        } },
                        .data_table => .{ .data_table = .{
                            .name = try self.readString(),
                        } },
                    };
                }
            }

            return DataTables.SendTable{
                .needs_decoder = needs_decoder,
                .name = name,
                .props = props,
            };
        }

        pub fn parseServerClass(self: *Self) !DataTables.ServerClass {
            const data_table_id = try self.br.readInt(u16);
            const class_name = try self.readString();
            const table_name = try self.readString();

            return DataTables.ServerClass{
                .data_table_id = data_table_id,
                .class_name = class_name,
                .table_name = table_name,
            };
        }

        inline fn readString(self: *Self) ![]u8 {
            return self.br.readMoveString(self.raw_allocator, self.arena);
        }
    };
}
