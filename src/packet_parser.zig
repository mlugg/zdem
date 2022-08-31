const std = @import("std");
const Demo = @import("Demo.zig");
const packet = @import("packet.zig");

pub fn PanicOnParse(comptime message: []const u8) type {
    return struct {
        const Self = @This();
        pub fn parse(comptime T: type, pp: anytype) !Self {
            _ = T;
            _ = pp;
            @panic(message);
        }
    };
}

pub fn parseNetTick(comptime T: type, pp: anytype) !T {
    const tick = try pp.br.readInt(u32);
    const frametime = try pp.br.readInt(u16);
    const stddev = try pp.br.readInt(u16);

    pp.demo_state.cur_server_tick = tick;

    return T{
        .tick = tick,
        .host_frametime = @intToFloat(f32, frametime) / 1e5,
        .host_frametime_stddev = @intToFloat(f32, stddev) / 1e5,
    };
}

pub fn parseOs(comptime T: type, pp: anytype) !T {
    return switch (try pp.br.readInt(u8)) {
        'W', 'w' => .windows,
        'L', 'l' => .linux,
        else => error.BadOsChar,
    };
}

pub fn parseSvcClassInfo(comptime T: type, pp: anytype) !T {
    const class_count = try pp.br.readInt(u16);
    if (!try pp.br.readBool()) {
        @panic("Unexpected SVC_ClassInfo with CreateOnClient=false");
    }

    return T{
        .class_count = class_count,
    };
}

pub fn stubSvcCreateStringTable(comptime T: type, pp: anytype) !T {
    const name = try pp.br.readMoveString(pp.raw_allocator, pp.arena);
    const max_entries = try pp.br.readInt(u16);
    const entry_bits = std.math.log2(max_entries) + 1;
    const num_entries = try pp.br.readUnsigned(u16, entry_bits);
    const data_len = try pp.br.readInt(u20);
    const user_data_fixed_size = try pp.br.readBool();
    const user_data_size = if (user_data_fixed_size) try pp.br.readInt(u12) else 0;
    const user_data_size_bits = if (user_data_fixed_size) try pp.br.readInt(u4) else 0;
    const flags = try pp.br.readInt(u2);
    std.log.info("ignoring parsing for stringtable {s}", .{name});
    _ = num_entries;
    _ = user_data_fixed_size;
    _ = user_data_size;
    _ = user_data_size_bits;
    _ = flags;
    try pp.br.skipBits(data_len);
    return T{};
}

pub fn stubSvcUpdateStringTable(comptime T: type, pp: anytype) !T {
    const table_id = try pp.br.readInt(u5);
    const num_changed = if (try pp.br.readBool()) try pp.br.readInt(u16) else 1;
    const data_len = try pp.br.readInt(u20);
    std.log.info("ignoring update parsing for stringtable {} with {} changes", .{ table_id, num_changed });
    try pp.br.skipBits(data_len);
    return T{};
}

pub fn parseSvcSounds(comptime T: type, pp: anytype) !T {
    const reliable = try pp.br.readBool();
    const num_sounds: u8 = if (reliable) 1 else try pp.br.readInt(u8);
    const length: u16 = if (reliable) try pp.br.readInt(u8) else try pp.br.readInt(u16);
    try pp.br.skipBits(length);
    _ = num_sounds;
    return T{ .reliable = reliable };
}

pub fn parseSvcFixAngle(comptime T: type, pp: anytype) !T {
    return T{
        .relative = try pp.br.readBool(),
        .angle = .{
            try readBitAngle(pp.br, 16),
            try readBitAngle(pp.br, 16),
            try readBitAngle(pp.br, 16),
        },
    };
}

pub fn parseSvcCrosshairAngle(comptime T: type, pp: anytype) !T {
    return T{
        .angle = .{
            try readBitAngle(pp.br, 16),
            try readBitAngle(pp.br, 16),
            try readBitAngle(pp.br, 16),
        },
    };
}

pub fn parseSvcBspDecal(comptime T: type, pp: anytype) !T {
    return T{
        .pos = .{
            try readVecCoord(pp.br),
            try readVecCoord(pp.br),
            try readVecCoord(pp.br),
        },
        .decal_texture_index = try pp.br.readInt(u9),
        .indices = if (try pp.br.readBool()) .{
            .entity = try pp.br.readInt(u11),
            .model = try pp.br.readInt(u11),
        } else null,
        .low_priority = try pp.br.readBool(),
    };
}

pub fn stubSvcUserMessage(comptime T: type, pp: anytype) !T {
    const msg_type = try pp.br.readInt(u8);
    const data_len = try pp.br.readInt(u12);
    std.log.info("ignoring user message parsing with type {}", .{msg_type});
    try pp.br.skipBits(data_len);
    return T{};
}

pub fn parseSvcPacketEntities(comptime T: type, pp: anytype) !T {
    return @import("ent_update.zig").parseEntityUpdate(T, pp);
}

pub fn postParseSvcPacketEntities(pp: anytype, ptr: anytype) void {
    return @import("ent_update.zig").postParseEntityUpdate(pp, ptr);
}

pub fn readBitAngle(br: anytype, bits: u5) !f32 {
    const shift = @intToFloat(f32, @as(u32, 1) << bits);
    const i = try br.readUnsigned(u32, bits);
    return @intToFloat(f32, i) * 360.0 / shift;
}

pub fn readVecCoord(br: anytype) !?f32 {
    if (!try br.readBool()) return null;

    const has_int = try br.readBool();
    const has_frac = try br.readBool();
    if (has_int or has_frac) {
        const sign: f32 = if (try br.readBool()) -1 else 1;
        var val: f32 = 0;
        if (has_int) {
            val += @intToFloat(f32, try br.readInt(u14));
        }
        if (has_frac) {
            const raw = try br.readInt(u5);
            val += @intToFloat(f32, raw) / ((1 << 5) - 1);
        }
        return sign * val;
    } else {
        return 0;
    }
}

//////////////////////////////

pub fn ParseArrayLength(comptime field: []const u8, comptime T: type) type {
    return struct {
        const parse_array_length_dummy_decl = {};
        const field_name = field;
        const LengthType = T;
    };
}

pub fn PacketParser(comptime BitReader: type) type {
    return struct {
        br: BitReader,
        raw_allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        demo_state: *Demo.DemoState,

        const Self = @This();

        fn parseGeneric(self: *Self, comptime T: type) anyerror!T { // XXX TODO FIXME ERROR SET
            if (comptime std.meta.trait.isContainer(T) and @hasDecl(T, "parse")) {
                return T.parse(T, self);
            } else if (comptime std.meta.trait.is(.Struct)(T)) {
                return self.parseStruct(T);
            } else if (comptime std.meta.trait.is(.Array)(T)) {
                // parse child n times
                var val: T = undefined;
                inline for (val[0..]) |*x| {
                    x.* = try self.parseGeneric(@TypeOf(x.*));
                }
                return val;
            } else if (comptime T == []u8) {
                // stringity string mc string face
                return try self.br.readMoveString(self.raw_allocator, self.arena);
            } else if (comptime std.meta.trait.isFloat(T)) {
                return try self.br.readFloat(T);
            } else if (comptime std.meta.trait.isIntegral(T)) {
                return try self.br.readInt(T);
            } else if (comptime T == bool) {
                return 1 == try self.parseGeneric(u1);
            } else {
                @compileError("Cannot create parser for type " ++ @typeName(T));
            }
        }

        fn parseStruct(self: *Self, comptime T: type) !T {
            comptime var allocated_arrays: []const []const u8 = &.{};

            var result: T = undefined;

            inline for (comptime std.meta.fieldNames(T)) |field| {
                const FieldType = @TypeOf(@field(result, field));

                if (comptime std.meta.trait.isContainer(FieldType) and @hasDecl(FieldType, "parse_array_length_dummy_decl")) {
                    allocated_arrays = allocated_arrays ++ &[1][]const u8{FieldType.field_name};

                    const length = try self.parseGeneric(FieldType.LengthType);
                    const ElemType = std.meta.Child(@TypeOf(@field(result, FieldType.field_name)));

                    @field(result, FieldType.field_name) = try self.arena.alloc(ElemType, length);
                    @field(result, field) = .{};

                    continue;
                }

                if (comptime std.meta.trait.isSlice(FieldType)) {
                    const should_handle = inline for (allocated_arrays) |entry| {
                        if (comptime std.mem.eql(u8, entry, field)) {
                            break true;
                        }
                    } else false;

                    if (should_handle) {
                        for (@field(result, field)) |*elem| {
                            elem.* = try self.parseGeneric(std.meta.Child(FieldType));
                        }
                        continue;
                    }
                }

                @field(result, field) = try self.parseGeneric(FieldType);
            }

            return result;
        }

        fn parsePacket(self: *Self) !?packet.NetSvcMessage {
            const raw_type = self.br.readInt(u6) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => |e| return e,
            };

            const pkt_type = std.meta.intToEnum(packet.PacketType, raw_type) catch {
                std.log.info("BAD PACKET TYPE: {}", .{raw_type});
                return error.BadPacketType;
            };

            std.log.info("Parsing packet type {s}", .{@tagName(pkt_type)});

            inline for (std.meta.fields(packet.NetSvcMessage)) |field_info| {
                if (std.mem.eql(u8, @tagName(pkt_type), field_info.name)) {
                    const val = try self.parseGeneric(field_info.field_type);
                    return @unionInit(packet.NetSvcMessage, field_info.name, val);
                }
            }

            unreachable;
        }

        pub fn parsePackets(self: *Self) ![]packet.NetSvcMessage {
            var packets = std.ArrayList(packet.NetSvcMessage).init(self.raw_allocator);
            defer packets.deinit();

            while (try self.parsePacket()) |pkt| {
                try packets.append(pkt);
            }

            const packets_copy = try self.arena.dupe(packet.NetSvcMessage, packets.items);

            // run post-parse hooks
            for (packets_copy) |*pkt| {
                inline for (std.meta.fields(packet.PacketType)) |field_info| {
                    if (@intToEnum(packet.PacketType, field_info.value) == std.meta.activeTag(pkt.*)) {
                        if (@hasDecl(@TypeOf(@field(pkt, field_info.name)), "postParse")) {
                            const f = @field(@TypeOf(@field(pkt, field_info.name)), "postParse");
                            f(self, pkt);
                        }
                        break;
                    }
                } else unreachable;
            }

            return packets_copy;
        }
    };
}
