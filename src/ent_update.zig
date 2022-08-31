const std = @import("std");

const Demo = @import("Demo.zig");
const parseEntProps = @import("ent_prop_parser.zig").parseEntProps;

pub fn parseEntityUpdate(comptime T: type, pp: anytype) !T {
    const max_entries = try pp.br.readInt(u11);
    const delta_from = if (try pp.br.readBool()) try pp.br.readInt(u32) else null;
    const baseline = try pp.br.readBool();
    const updated_entries = try pp.br.readInt(u11);
    const data_len = try pp.br.readInt(u20);
    const update_baseline = try pp.br.readBool();

    var snapshot = Demo.EntityFrame{
        .server_tick = pp.demo_state.cur_server_tick,
    };

    if (delta_from != null) {
        const frames = pp.demo_state.entityFrames();
        snapshot.entities = for (frames) |frame| {
            if (frame.server_tick == delta_from) {
                var entities: [2048]?Demo.EntityFrame.Entity = undefined;
                for (entities) |*ent_out, i| {
                    if (frame.entities[i]) |ent| {
                        // TODO: jesus the memory leaks here
                        const props = try pp.arena.dupe(Demo.EntProp.Value, ent.props);
                        ent_out.* = .{
                            .class_idx = ent.class_idx,
                            .serial = ent.serial,
                            .in_pvs = ent.in_pvs,
                            .props = props,
                        };
                    } else {
                        ent_out.* = null;
                    }
                }
                break entities;
            }
        } else {
            return error.EntityDeltaFromBadTick;
        };
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

                    for (props) |prop| {
                        ent.props[prop.idx] = prop.value;
                    }

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
                    // TODO: this... doesn't *leak* memory as such, as it's an arena, but we probably don't
                    // want to keep the old snapshot prop arrays around when we delete/replace entities. how
                    // can we deal with this nicely? maybe we could use a fixed prop array per slot to avoid
                    // constant allocations of new arrays when new entities enter the pvs?
                    snapshot.entities[idx] = .{
                        .class_idx = class_idx,
                        .serial = serial,
                        .in_pvs = true,
                        .props = try pp.arena.alloc(Demo.EntProp.Value, class.props.count()),
                    };

                    // fill in from baseline
                    std.mem.copy(Demo.EntProp.Value, snapshot.entities[idx].?.props, try pp.demo_state.getBaseline(class_idx));
                }

                const props = try parseEntProps(pp.raw_allocator, pp.arena, pp.br, class);
                defer pp.raw_allocator.free(props);

                for (props) |prop| {
                    snapshot.entities[idx].?.props[prop.idx] = prop.value;
                }

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
