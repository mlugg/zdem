const std = @import("std");
const Demo = @import("Demo.zig");
const DataTableParser = @import("data_table_parser.zig").DataTableParser;
const StringTableParser = @import("string_table_parser.zig").StringTableParser;
const demoBitReader = @import("bit_reader.zig").demoBitReader;

pub fn Parser(comptime Reader: type) type {
    return struct {
        raw_allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        r: Reader,
        parse_state: Demo.DemoState,

        const Self = @This();

        pub fn run(self: *Self) !Demo {
            self.parse_state = try Demo.DemoState.init(self.raw_allocator);

            defer self.parse_state.deinit();

            if (!try self.r.isBytes("HL2DEMO\x00")) return error.NotDemoFile;

            const dem_proto = try self.r.readIntLittle(u32);
            const net_proto = try self.r.readIntLittle(u32);

            const server_name_raw = try self.r.readBytesNoEof(260);
            const client_name_raw = try self.r.readBytesNoEof(260);
            const map_name_raw = try self.r.readBytesNoEof(260);
            const game_dir_raw = try self.r.readBytesNoEof(260);

            const server_name = try self.arena.allocator().dupe(u8, std.mem.sliceTo(&server_name_raw, 0));
            const client_name = try self.arena.allocator().dupe(u8, std.mem.sliceTo(&client_name_raw, 0));
            const map_name = try self.arena.allocator().dupe(u8, std.mem.sliceTo(&map_name_raw, 0));
            const game_dir = try self.arena.allocator().dupe(u8, std.mem.sliceTo(&game_dir_raw, 0));

            const playback_time = @bitCast(f32, try self.r.readIntLittle(u32));
            const playback_ticks = try self.r.readIntLittle(i32);
            const playback_frames = try self.r.readIntLittle(i32);
            const signon_length = try self.r.readIntLittle(u32);

            // don't use the arena for the message list yet since we'll be reallocing it
            var messages = std.ArrayList(Demo.Message).init(self.raw_allocator);
            defer messages.deinit();

            var had_stop = false;
            while (true) {
                const msg = self.parseMessage() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (had_stop) {
                            break;
                        } else {
                            return error.EndOfStream;
                        }
                    },
                    else => |e| return e,
                };

                if (msg.data == .stop) had_stop = true;

                try messages.append(msg);
            }

            const messages_copy = try self.arena.allocator().dupe(Demo.Message, messages.items);

            return Demo{
                .arena = self.arena,
                .dem_protocol = dem_proto,
                .net_protocol = net_proto,
                .server_name = server_name,
                .client_name = client_name,
                .map_name = map_name,
                .game_directory = game_dir,
                .playback_time = playback_time,
                .playback_ticks = playback_ticks,
                .playback_frames = playback_frames,
                .signon_length = signon_length,
                .messages = messages_copy,
            };
        }

        fn parseMessage(self: *Self) !Demo.Message {
            const msg_type = try self.r.readByte();
            const tick = try self.r.readIntLittle(i32);
            const slot = try self.r.readByte();

            const data: Demo.Message.Data = switch (msg_type) {
                1 => .{ .signon = try self.parsePacket() },
                2 => .{ .packet = try self.parsePacket() },
                3 => .sync_tick,
                4 => .{ .console_cmd = try self.parseConsoleCmd() },
                5 => .{ .user_cmd = try self.parseUserCmd() },
                6 => .{ .data_tables = try self.parseDataTables() },
                7 => .stop,
                8 => .{ .custom_data = try self.parseCustomData() },
                9 => .{ .string_tables = try self.parseStringTables() },
                else => return error.InvalidMessage,
            };

            return Demo.Message{
                .tick = tick,
                .slot = slot,
                .data = data,
            };
        }

        fn parsePacket(self: *Self) !Demo.Message.Packet {
            const infos = [2]Demo.Message.Packet.PacketInfo{
                try self.parsePacketInfo(),
                try self.parsePacketInfo(),
            };

            const in_seq = try self.r.readIntLittle(u32);
            const out_seq = try self.r.readIntLittle(u32);

            const size = try self.r.readIntLittle(u32);

            const buf = try self.raw_allocator.alloc(u8, size);
            defer self.raw_allocator.free(buf);
            try self.r.readNoEof(buf);

            var fbr = std.io.fixedBufferStream(buf);
            var br = demoBitReader(fbr.reader());

            var pp = @import("packet_parser.zig").PacketParser(@TypeOf(&br)){
                .br = &br,
                .demo_state = &self.parse_state,
                .raw_allocator = self.raw_allocator,
                .arena = self.arena.allocator(),
            };
            const messages = try pp.parsePackets();

            return Demo.Message.Packet{
                .packet_info = infos,
                .in_seq = in_seq,
                .out_seq = out_seq,
                .net_messages = messages,
            };
        }

        fn parsePacketInfo(self: *Self) !Demo.Message.Packet.PacketInfo {
            return Demo.Message.Packet.PacketInfo{
                .flags = try self.r.readIntLittle(u32),
                .view_origin = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
                .view_angles = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
                .local_view_angles = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
                .view_origin_2 = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
                .view_angles_2 = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
                .local_view_angles_2 = .{
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                    @bitCast(f32, try self.r.readIntLittle(u32)),
                },
            };
        }

        fn parseConsoleCmd(self: *Self) ![]u8 {
            const size = try self.r.readIntLittle(u32);
            const buf = try self.arena.allocator().alloc(u8, size);
            try self.r.readNoEof(buf);
            // This seems to contain a null terminator, but I'm not sure if
            // that's guaranteed
            if (buf[buf.len - 1] == 0) {
                return buf[0 .. buf.len - 1];
            } else {
                return buf;
            }
        }

        fn parseUserCmd(self: *Self) !Demo.Message.UserCmd {
            const cmd = try self.r.readIntLittle(u32);
            const size = try self.r.readIntLittle(u32);

            var cr = std.io.countingReader(self.r);
            var br = demoBitReader(cr.reader());

            const cmd_num = try optionalBitRead(u32, &br);
            const tick_count = try optionalBitRead(i32, &br);
            const view_angles = [3]?f32{
                try optionalBitRead(f32, &br),
                try optionalBitRead(f32, &br),
                try optionalBitRead(f32, &br),
            };
            const forward_move = try optionalBitRead(f32, &br);
            const side_move = try optionalBitRead(f32, &br);
            const up_move = try optionalBitRead(f32, &br);
            const buttons = try optionalBitRead(u32, &br);
            const impulse = try optionalBitRead(u8, &br);
            const weapon_select = try optionalBitRead(u11, &br);
            const weapon_subtype = if (weapon_select != null)
                try optionalBitRead(u6, &br)
            else
                null;
            const mouse_dx = try optionalBitRead(i16, &br);
            const mouse_dy = try optionalBitRead(i16, &br);

            if (cr.bytes_read > size) {
                return error.BadUserCmd;
            } else {
                try self.r.skipBytes(size - cr.bytes_read, .{});
            }

            return Demo.Message.UserCmd{
                .cmd = cmd,
                .info = .{
                    .cmd_num = cmd_num,
                    .tick_count = tick_count,
                    .view_angles = view_angles,
                    .forward_move = forward_move,
                    .side_move = side_move,
                    .up_move = up_move,
                    .buttons = buttons,
                    .impulse = impulse,
                    .weapon_select = if (weapon_select) |select| .{
                        .select = select,
                        .subtype = weapon_subtype,
                    } else null,
                    .mouse_dx = mouse_dx,
                    .mouse_dy = mouse_dy,
                },
            };
        }

        fn parseDataTables(self: *Self) !Demo.DataTables {
            std.log.info("Parsing data tables", .{});

            const size = try self.r.readIntLittle(u32);

            var cr = std.io.countingReader(self.r);
            var br = demoBitReader(cr.reader());

            var dtp = DataTableParser(@TypeOf(&br)){
                .raw_allocator = self.raw_allocator,
                .arena = self.arena.allocator(),
                .br = &br,
            };

            var send_tables = std.ArrayList(Demo.DataTables.SendTable).init(self.raw_allocator);
            defer send_tables.deinit();

            while (try br.readBool()) {
                try send_tables.append(try dtp.parseSendTable());
            }

            const num_classes = try br.readInt(u16);
            const server_classes = try self.arena.allocator().alloc(Demo.DataTables.ServerClass, num_classes);
            for (server_classes) |*class| {
                class.* = try dtp.parseServerClass();
            }

            if (cr.bytes_read > size) {
                return error.BadDataTables;
            } else {
                try self.r.skipBytes(size - cr.bytes_read, .{});
            }

            const dt = Demo.DataTables{
                .send_tables = try self.arena.allocator().dupe(Demo.DataTables.SendTable, send_tables.items),
                .server_classes = server_classes,
            };

            try self.parse_state.initDataTables(dt, self.raw_allocator, self.arena.allocator());
            return dt;
        }

        fn parseCustomData(self: *Self) !Demo.Message.CustomData {
            const kind = try self.r.readIntLittle(u32);
            const size = try self.r.readIntLittle(u32);

            if (kind == std.math.maxInt(u32)) {
                var cr = std.io.countingReader(self.r);

                const count = try cr.reader().readIntLittle(u32);
                const callbacks = try self.arena.allocator().alloc([]u8, count);
                for (callbacks) |*out| {
                    out.* = try self.readString(cr.reader());
                }
                self.parse_state.custom_data_callbacks = callbacks;

                if (cr.bytes_read != size) {
                    return error.BadCustomDataCallbacks;
                }

                return Demo.Message.CustomData{ .callbacks = callbacks };
            }

            const callback = if (self.parse_state.custom_data_callbacks) |callbacks|
                if (kind < callbacks.len) callbacks[kind] else null
            else
                null;

            const buf = try self.arena.allocator().alloc(u8, size);
            try self.r.readNoEof(buf);

            return Demo.Message.CustomData{ .data = .{
                .callback = callback,
                .buf = buf,
            } };
        }

        fn parseStringTables(self: *Self) ![]Demo.StringTable {
            std.log.info("Parsing string tables", .{});

            const size = try self.r.readIntLittle(u32);

            var cr = std.io.countingReader(self.r);
            var br = demoBitReader(cr.reader());

            const count = try br.readInt(u8);
            const tables = try self.arena.allocator().alloc(Demo.StringTable, count);

            var stp = StringTableParser(@TypeOf(&br)){
                .raw_allocator = self.raw_allocator,
                .arena = self.arena.allocator(),
                .br = &br,
                .demo_state = &self.parse_state,
            };

            for (tables) |*table| {
                table.* = try stp.parseStringTable();
                try self.parse_state.string_tables.put(table.name, table);
            }

            if (cr.bytes_read != size) {
                return error.BadStringTables;
            }

            return tables;
        }

        fn readString(self: *Self, r: anytype) ![]u8 {
            const str = try r.readUntilDelimiterAlloc(self.raw_allocator, 0, std.math.maxInt(usize));
            defer self.raw_allocator.free(str);
            return self.arena.allocator().dupe(u8, str);
        }
    };
}

//inline - TODO stage2 bug
fn optionalBitRead(comptime T: type, br: anytype) !?T {
    if (try br.readBool()) {
        if (comptime std.meta.trait.isFloat(T)) {
            return try br.readFloat(T);
        } else {
            return try br.readInt(T);
        }
    } else {
        return null;
    }
}
