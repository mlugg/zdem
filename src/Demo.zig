const std = @import("std");

const Parser = @import("parser.zig").Parser;
const Demo = @This();

pub usingnamespace @import("data_table.zig");
pub usingnamespace @import("packet.zig");
pub const StringTable = @import("StringTable.zig");
pub const EntProp = @import("EntProp.zig");
pub const EntityFrame = @import("EntityFrame.zig");
pub const DemoState = @import("DemoState.zig");

arena: std.heap.ArenaAllocator,

dem_protocol: u32,
net_protocol: u32,
server_name: []u8,
client_name: []u8,
map_name: []u8,
game_directory: []u8,
playback_time: f32,
playback_ticks: i32,
playback_frames: i32,
signon_length: u32,
messages: []Message,

pub const Message = struct {
    tick: i32,
    slot: u8,
    data: Data,

    pub const Data = union(enum) {
        signon: Packet,
        packet: Packet,
        sync_tick: void,
        console_cmd: []u8,
        user_cmd: UserCmd,
        data_tables: Demo.DataTables,
        stop: void,
        custom_data: CustomData,
        string_tables: []Demo.StringTable,
    };

    pub const Packet = struct {
        packet_info: [2]PacketInfo,
        in_seq: u32,
        out_seq: u32,
        net_messages: []Demo.NetSvcMessage,

        pub const PacketInfo = struct {
            flags: u32,
            view_origin: [3]f32,
            view_angles: [3]f32,
            local_view_angles: [3]f32,
            view_origin_2: [3]f32,
            view_angles_2: [3]f32,
            local_view_angles_2: [3]f32,
        };
    };

    pub const UserCmd = struct {
        cmd: u32,
        info: struct {
            cmd_num: ?u32,
            tick_count: ?i32,
            view_angles: [3]?f32,
            forward_move: ?f32,
            side_move: ?f32,
            up_move: ?f32,
            buttons: ?u32,
            impulse: ?u8,
            weapon_select: ?struct {
                select: u11,
                subtype: ?u6,
            },
            mouse_dx: ?i16,
            mouse_dy: ?i16,
        },
    };

    pub const CustomData = union(enum) {
        callbacks: [][]u8,
        data: struct {
            callback: ?[]const u8,
            buf: []u8,
        },
    };
};

pub fn parse(allocator: std.mem.Allocator, r: anytype) !Demo {
    std.log.info("parse", .{});
    var p = Parser(@TypeOf(r)){
        .raw_allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .r = r,
        .parse_state = undefined,
    };
    std.log.info("inited parser", .{});

    errdefer p.arena.deinit();
    std.log.info("did defer", .{});

    return p.run();
}

pub fn deinit(dem: Demo) void {
    dem.arena.deinit();
}

pub fn format(dem: Demo, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;

    try writer.print("HL2DEMO (demo protocol {}, network protocol {})\n", .{ dem.dem_protocol, dem.net_protocol });
    try writer.print("    server name: {s}\n", .{dem.server_name});
    try writer.print("    client name: {s}\n", .{dem.client_name});
    try writer.print("    map name: {s}\n", .{dem.map_name});
    try writer.print("    game directory: {s}\n", .{dem.game_directory});
    try writer.print("    playback time: {d}\n", .{dem.playback_time});
    try writer.print("    playback ticks: {}\n", .{dem.playback_ticks});
    try writer.print("    playback frames: {}\n", .{dem.playback_frames});
    try writer.print("    signon length: {}\n", .{dem.signon_length});
    try writer.print("    {} messages:\n", .{dem.messages.len});

    for (dem.messages) |message| {
        try writer.print("        [{};{}] ", .{ message.slot, message.tick });
        switch (message.data) {
            .signon => |pkt| {
                try writer.print("signon:\n", .{});
                try fmtPacket(pkt, writer);
            },
            .packet => |pkt| {
                try writer.print("packet:\n", .{});
                try fmtPacket(pkt, writer);
            },
            .sync_tick => try writer.print("sync tick\n", .{}),
            .console_cmd => |cmd| try writer.print("console cmd: {s}\n", .{cmd}),
            .user_cmd => |cmd| {
                try writer.print("user cmd:\n", .{});
                try fmtUserCmd(cmd, writer);
            },
            .data_tables => |tables| {
                try writer.print("data tables:\n", .{});
                try fmtDataTables(tables, writer);
            },
            .stop => try writer.print("stop\n", .{}),
            .custom_data => |data| {
                try writer.print("custom data:\n", .{});
                try fmtCustomData(data, writer);
            },
            .string_tables => |tables| {
                try writer.print("{} string tables:\n", .{tables.len});
                try fmtStringTables(tables, writer);
            },
        }
    }
}

fn fmtPacket(pkt: Message.Packet, writer: anytype) !void {
    for (pkt.packet_info) |info, slot| {
        try writer.print("            slot {} info:\n", .{slot});
        try writer.print("                flags: {x}\n", .{info.flags});
        try writer.print("                view origin: {d}\n", .{info.view_origin});
        try writer.print("                view angles: {d}\n", .{info.view_angles});
        try writer.print("                local view angles: {d}\n", .{info.local_view_angles});
        try writer.print("                view origin 2: {d}\n", .{info.view_origin_2});
        try writer.print("                view angles 2: {d}\n", .{info.view_angles_2});
        try writer.print("                local view angles 2: {d}\n", .{info.local_view_angles_2});
    }

    try writer.print("            in sequence: {}\n", .{pkt.in_seq});
    try writer.print("            out sequence: {}\n", .{pkt.out_seq});
}

fn fmtUserCmd(ucmd: Message.UserCmd, writer: anytype) !void {
    try writer.print("            command: {}\n", .{ucmd.cmd});
    try writer.print("            command number: {any}\n", .{ucmd.info.cmd_num});
    try writer.print("            tick count: {any}\n", .{ucmd.info.tick_count});
    try writer.print("            view angles: {any}\n", .{ucmd.info.view_angles});
    try writer.print("            forward move: {any}\n", .{ucmd.info.forward_move});
    try writer.print("            side move: {any}\n", .{ucmd.info.side_move});
    try writer.print("            up move: {any}\n", .{ucmd.info.up_move});
    try writer.print("            buttons: {any}\n", .{ucmd.info.buttons});
    try writer.print("            impulse: {any}\n", .{ucmd.info.impulse});

    if (ucmd.info.weapon_select) |weapon| {
        try writer.print("            weapon select: {} (subtype {any})\n", .{ weapon.select, weapon.subtype });
    } else {
        try writer.print("            weapon select: null\n", .{});
    }

    try writer.print("            mouse dx: {any}\n", .{ucmd.info.mouse_dx});
    try writer.print("            mouse dy: {any}\n", .{ucmd.info.mouse_dy});
}

fn fmtDataTables(tables: Demo.DataTables, writer: anytype) !void {
    try writer.print("            {} send tables:\n", .{tables.send_tables.len});
    for (tables.send_tables) |table| {
        try writer.print("                {s}:\n", .{table.name});
        try writer.print("                    needs decoder: {}\n", .{table.needs_decoder});
        try writer.print("                    {} props:\n", .{table.props.len});
        for (table.props) |prop| {
            try writer.print("                        {s}:\n", .{prop.name});
            try writer.print("                            priority: {}\n", .{prop.priority});
            try writer.print("                            type: {s}\n", .{@tagName(prop.info)});
        }
    }
    try writer.print("            {} server classes:\n", .{tables.server_classes.len});
    for (tables.server_classes) |class, i| {
        try writer.print("                {}:\n", .{i});
        try writer.print("                    data table id: {}\n", .{class.data_table_id});
        try writer.print("                    class name: {s}\n", .{class.class_name});
        try writer.print("                    table name: {s}\n", .{class.table_name});
    }
}

fn fmtCustomData(cd: Message.CustomData, writer: anytype) !void {
    switch (cd) {
        .callbacks => |callbacks| {
            try writer.print("            {} callbacks:\n", .{callbacks.len});
            for (callbacks) |cbk, i| {
                try writer.print("                {}: {s}\n", .{ i, cbk });
            }
        },
        .data => |data| {
            try writer.print("            callback {?s}, data {} bytes\n", .{ data.callback, data.buf.len });
        },
    }
}

fn fmtStringTables(tables: []Demo.StringTable, writer: anytype) !void {
    for (tables) |table| {
        try writer.print("            {s}\n", .{table.name});
        try writer.print("                {} server entries:\n", .{table.server_entries.len});
        try fmtStringTableEntries(table.server_entries, writer);
        if (table.client_entries) |client_entries| {
            try writer.print("                {} client entries:\n", .{client_entries.len});
            try fmtStringTableEntries(client_entries, writer);
        }
    }
}

fn fmtStringTableEntries(entries: []Demo.StringTable.Entry, writer: anytype) !void {
    for (entries) |entry| {
        if (entry.data) |data| {
            try writer.print("                    {s} ({} bytes)\n", .{ entry.name, data.len });
        } else {
            try writer.print("                    {s}\n", .{entry.name});
        }
    }
}
