const std = @import("std");

const Demo = @import("Demo.zig");
const parseEntProps = @import("ent_prop_parser.zig").parseEntProps;

pub fn parseEntityUpdate(comptime T: type, pp: anytype) !T {
    const max_entries = try pp.br.readInt(u11);
    const delta_from_tick = if (try pp.br.readBool()) try pp.br.readInt(u32) else null;
    const baseline = try pp.br.readBool();
    const updated_entries = try pp.br.readInt(u11);
    const data_len = try pp.br.readInt(u20);
    const update_baseline = try pp.br.readBool();

    var snapshot = Demo.EntityFrame{
        .server_tick = pp.demo_state.cur_server_tick,
        .update = undefined, // TODO: we need to fill this with a pointer to the packet
    };

    var delta_from: ?*Demo.NetSvcMessage = null;

    if (delta_from_tick != null) {
        for (pp.demo_state.entityFrames()) |frame| {
            if (frame.server_tick == delta_from_tick) {
                snapshot.entities = frame.entities;
                delta_from = frame.update;
                break;
            }
        } else {
            return error.EntityDeltaFromBadTick;
        }
    }

    var updates = std.ArrayList(T.EntityUpdate).init(pp.raw_allocator);
    defer updates.deinit();

    try updates.ensureTotalCapacity(updated_entries);

    // oh my GOD valve's code for this is horrendous... i'm glad i spent some
    // time figuring out what it actually fucking does so i could simplify it

    var idx: u11 = 0;
    var i: u32 = 0;
    while (i < updated_entries) : (i += 1) {
        idx += @intCast(u11, try readVarInt(pp.br)); // TODO handle

        const update_type = try pp.br.readInt(u2);

        if (delta_from == null and update_type != 2) {
            return error.NonNewEntityInFullUpdate;
        }

        switch (update_type) {
            0 => { // delta
                if (snapshot.entities[idx]) |*ent| {
                    const class = pp.demo_state.processed_classes.values()[ent.class_idx];
                    const props = try parseEntProps(pp.raw_allocator, pp.arena, pp.br, class);
                    defer pp.raw_allocator.free(props);

                    const props_copy = try pp.arena.dupe(Demo.EntProp, props);

                    updates.append(.{
                        .idx = idx,
                        .update = .{ .delta = .{
                            .props = props_copy,
                        } },
                    }) catch unreachable;
                } else {
                    return error.DeltaUnknownEntity;
                }
            },
            1 => { // leave pvs
                if (snapshot.entities[idx]) |*ent| {
                    ent.in_pvs = false;
                    updates.append(.{ .idx = idx, .update = .leave_pvs }) catch unreachable;
                } else {
                    return error.LeavePvsUnknownEntity;
                }
            },
            2 => { // enter pvs
                const class_bits = std.math.log2(pp.demo_state.processed_classes.count()) + 1;

                const class_idx = try pp.br.readUnsigned(u32, class_bits);
                const serial = try pp.br.readInt(u10);
                const new = if (snapshot.entities[idx]) |ent| ent.serial != serial else true;

                if (!new and snapshot.entities[idx].?.class_idx != class_idx) {
                    return error.ReEnteredPvsWithDifferentClass;
                }

                if (class_idx > pp.demo_state.processed_classes.count()) {
                    return error.ServerClassOutOfRange;
                }

                const class = pp.demo_state.processed_classes.values()[class_idx];

                if (new) {
                    snapshot.entities[idx] = .{
                        .class_idx = class_idx,
                        .serial = serial,
                        .in_pvs = true,
                    };

                    // TODO: assert baseline exists
                }

                const props = try parseEntProps(pp.raw_allocator, pp.arena, pp.br, class);
                defer pp.raw_allocator.free(props);

                const props_copy = try pp.arena.dupe(Demo.EntProp, props);

                if (new) {
                    updates.append(.{
                        .idx = idx,
                        .update = .{ .new = .{
                            .class_idx = class_idx,
                            .serial = serial,
                            .props = props_copy,
                        } },
                    }) catch unreachable;
                } else {
                    updates.append(.{
                        .idx = idx,
                        .update = .{ .re_enter_pvs = .{
                            .props = props_copy,
                        } },
                    }) catch unreachable;
                }
            },
            3 => { // delete
                if (snapshot.entities[idx] == null) {
                    return error.DeleteUnknownEntity;
                }
                snapshot.entities[idx] = null;
                updates.append(.{ .idx = idx, .update = .delete }) catch unreachable;
            },
        }

        idx += 1;
    }

    if (delta_from != null) {
        while (try pp.br.readBool()) {
            idx = try pp.br.readInt(u11);
            snapshot.entities[idx] = null;
            try updates.append(.{ .idx = idx, .update = .delete });
        }
    }

    // TODO: ensure we've read data_len bits
    _ = data_len;

    // TODO: handle baseline / update_baseline
    if (baseline or update_baseline) {
        std.log.info("NOTE parsing with baseline={} update_baseline={}", .{ baseline, update_baseline });
    }

    pp.demo_state.addEntityFrame(snapshot);

    const updates_copy = try pp.arena.dupe(T.EntityUpdate, updates.items);
    return T{
        .max_entries = max_entries,
        .delta_from = delta_from,
        .baseline = baseline,
        .update_baseline = update_baseline,
        .updates = updates_copy,
    };
}

pub fn postParseEntityUpdate(pp: anytype, ptr: anytype) void {
    // TODO FIXME: this breaks horribly if we have multiple SVC_PacketEntities messages in one packet!
    pp.demo_state.lastEntityFrame().?.update = ptr;
}

fn readVarInt(br: anytype) !u32 {
    const x = try br.readInt(u4);
    const bits: usize = switch (try br.readInt(u2)) {
        0 => 0,
        1 => 4,
        2 => 8,
        3 => 28,
    };
    return x | (try br.readUnsigned(u32, bits)) << 4;
}
