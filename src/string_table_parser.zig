const std = @import("std");

const Demo = @import("Demo.zig");
const parseEntProps = @import("ent_prop_parser.zig").parseEntProps;
const demoBitReader = @import("bit_reader.zig").demoBitReader;

pub fn StringTableParser(comptime BitReader: type) type {
    return struct {
        raw_allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        br: BitReader,
        demo_state: *Demo.DemoState,

        const Self = @This();

        pub fn parseStringTable(self: *Self) !Demo.StringTable {
            const name = try self.br.readMoveString(self.raw_allocator, self.arena);

            const server_entries = try self.parseEntries();
            const client_entries = if (try self.br.readBool())
                try self.parseEntries()
            else
                null;

            var table = Demo.StringTable{
                .name = name,
                .server_entries = server_entries,
                .client_entries = client_entries,
                .parsed = .none,
            };

            if (std.mem.eql(u8, name, "instancebaseline")) {
                if (self.demo_state.processed_classes.count() > 0) {
                    const classes = try self.arena.alloc(Demo.StringTable.Baseline, self.demo_state.processed_classes.count());

                    for (self.demo_state.processed_classes.values()) |class, i| {
                        const values = try self.arena.alloc(Demo.EntProp.Value, class.props.count());
                        for (values) |*val, j| {
                            val.* = Demo.EntProp.Value.zero(class.props.values()[j].info);
                        }
                        classes[i] = .{ .props = values };
                    }

                    for (server_entries) |ent| {
                        const class_id = try std.fmt.parseInt(u32, ent.name, 10);
                        if (class_id >= self.demo_state.processed_classes.count()) {
                            return error.BadBaselineClassId;
                        }
                        const class = self.demo_state.processed_classes.values()[class_id];

                        var fbr = std.io.fixedBufferStream(ent.data.?);
                        var br = demoBitReader(fbr.reader());

                        const props = try parseEntProps(self.raw_allocator, self.arena, &br, class);
                        defer self.raw_allocator.free(props);

                        for (props) |prop| {
                            classes[class_id].props[prop.idx] = prop.value;
                        }
                    }

                    table.parsed = .{ .instance_baseline = .{
                        .classes = classes,
                    } };
                }
            }

            return table;
        }

        fn parseEntries(self: *Self) ![]Demo.StringTable.Entry {
            const count = try self.br.readInt(u16);
            const entries = try self.arena.alloc(Demo.StringTable.Entry, count);

            for (entries) |*entry| {
                entry.name = try self.br.readMoveString(self.raw_allocator, self.arena);

                if (try self.br.readBool()) {
                    const size = try self.br.readInt(u16);
                    const buf = try self.arena.alloc(u8, size);
                    try self.br.reader().readNoEof(buf);
                    entry.data = buf;
                } else {
                    entry.data = null;
                }
            }

            return entries;
        }
    };
}
