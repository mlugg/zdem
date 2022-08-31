const std = @import("std");

const Demo = @import("Demo.zig");
const EntProp = @import("EntProp.zig");

fn EntPropParser(comptime DemoBitReader: type) type {
    return struct {
        raw_allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        br: DemoBitReader,

        const Self = @This();

        fn parseEntProps(self: *Self, class: Demo.ProcessedClass) ![]EntProp {
            const new_encoding = try self.br.readBool();

            var props = std.ArrayList(EntProp).init(self.raw_allocator);
            defer props.deinit();

            var last_idx: ?u32 = null;
            while (try self.readFieldIndex(last_idx, new_encoding)) |i| {
                last_idx = i;
                if (i >= class.props.count()) return error.BadPropId;
                try props.append(.{
                    .idx = i,
                    .value = try self.readSendInfo(class.props.values()[i].info),
                });
            }

            return props.toOwnedSlice();
        }

        fn readFieldIndex(self: *Self, last_idx: ?u32, new_encoding: bool) !?u32 {
            if (new_encoding and try self.br.readBool()) {
                if (last_idx) |last|
                    return last + 1
                else
                    return 0;
            }

            const ret: u32 = if (new_encoding and try self.br.readBool())
                try self.br.readInt(u3)
            else blk: {
                const base = try self.br.readInt(u5);
                const end: u31 = switch (try self.br.readInt(u2)) {
                    0 => 0,
                    1 => try self.br.readInt(u2),
                    2 => try self.br.readInt(u4),
                    3 => try self.br.readInt(u7),
                };
                break :blk base | (end << 5);
            };

            return if (ret == 0xFFF)
                null
            else if (last_idx) |last|
                last + 1 + ret
            else
                ret;
        }

        const SpecialType = enum { none, low_precision, integral };

        inline fn readFloatCoordMp(self: *Self, comptime special: SpecialType) !f32 {
            const in_bounds = try self.br.readBool();
            const has_int = try self.br.readBool();
            if (special == .integral) {
                if (has_int) {
                    const sign: f32 = if (try self.br.readBool()) -1 else 1;
                    const raw = try self.br.readUnsigned(u14, if (in_bounds) @as(usize, 11) else @as(usize, 14));
                    return sign * (@intToFloat(f32, raw) + 1);
                } else {
                    return 0;
                }
            } else {
                const sign: f32 = if (try self.br.readBool()) -1 else 1;

                const int_part: f32 = if (has_int) blk: {
                    const raw = try self.br.readUnsigned(u14, if (in_bounds) @as(usize, 11) else @as(usize, 14));
                    break :blk @intToFloat(f32, raw) + 1;
                } else 0;

                const frac_part: f32 = blk: {
                    const bits: u3 = if (special == .low_precision) 3 else 5;
                    const raw = try self.br.readUnsigned(u5, bits);
                    break :blk @intToFloat(f32, raw) / @intToFloat(f32, (@as(u32, 1) << bits) - 1);
                };

                return sign * (int_part + frac_part);
            }
        }

        inline fn readFloatCellCoord(self: *Self, comptime special: SpecialType, bits: u7) !f32 {
            if (special == .integral) {
                return @intToFloat(f32, try self.br.readUnsigned(u128, bits));
            } else {
                const int_part = @intToFloat(f32, try self.br.readUnsigned(u128, bits));
                const frac_bits = if (special == .low_precision) 3 else 5;
                const frac_raw = try self.br.readUnsigned(u5, frac_bits);
                const frac_part = @intToFloat(f32, frac_raw) / @intToFloat(f32, (@as(u32, 1) << frac_bits) - 1);
                return int_part + frac_part;
            }
        }

        fn readFloatProp(self: *Self, send: Demo.FloatSendInfo) !f32 {
            switch (send) {
                .ranged => |ranged| {
                    const raw = try self.br.readUnsigned(u128, ranged.bits);
                    const frac = @intToFloat(f32, raw) / @intToFloat(f32, (@as(u128, 1) << ranged.bits) - 1);
                    return ranged.low + (ranged.high - ranged.low) * frac;
                },
                .coord => {
                    const has_int = try self.br.readBool();
                    const has_frac = try self.br.readBool();
                    if (has_int or has_frac) {
                        const sign: f32 = if (try self.br.readBool()) -1 else 1;
                        var val: f32 = 0;
                        if (has_int) {
                            val += @intToFloat(f32, try self.br.readInt(u14));
                        }
                        if (has_frac) {
                            const raw = try self.br.readInt(u5);
                            val += @intToFloat(f32, raw) / ((1 << 5) - 1);
                        }
                        return sign * val;
                    } else {
                        return 0;
                    }
                },
                .no_scale => {
                    return self.br.readFloat(f32);
                },
                .normal => {
                    const sign: f32 = if (try self.br.readBool()) -1 else 1;
                    const raw = try self.br.readInt(u11);
                    return sign * @intToFloat(f32, raw) / ((1 << 11) - 1);
                },
                .coord_mp => {
                    return self.readFloatCoordMp(.none);
                },
                .coord_mp_low_precision => {
                    return self.readFloatCoordMp(.low_precision);
                },
                .coord_mp_integral => {
                    return self.readFloatCoordMp(.integral);
                },
                .cell_coord => |cell_coord| {
                    return self.readFloatCellCoord(.none, cell_coord.bits);
                },
                .cell_coord_low_precision => |cell_coord| {
                    return self.readFloatCellCoord(.low_precision, cell_coord.bits);
                },
                .cell_coord_integral => |cell_coord| {
                    return self.readFloatCellCoord(.integral, cell_coord.bits);
                },
            }
        }

        const ThingError = std.meta.Child(DemoBitReader).Error || std.mem.Allocator.Error || error{EndOfStream};

        fn readSendInfo(self: *Self, info: Demo.ProcessedClass.Prop.SendInfo) ThingError!EntProp.Value {
            switch (info) {
                .int => |int| {
                    if (int.signed) {
                        return EntProp.Value{ .int = try self.br.readSigned(i128, int.bits) };
                    } else {
                        return EntProp.Value{ .int = try self.br.readUnsigned(u127, int.bits) };
                    }
                },
                .float => |float| return EntProp.Value{ .float = try self.readFloatProp(float) },
                .vec3 => |float| {
                    const x = try self.readFloatProp(float);
                    const y = try self.readFloatProp(float);
                    const z = if (float == .normal) blk: {
                        const sign: f32 = if (try self.br.readBool()) -1 else 1;
                        const cur = x * x + y * y;
                        break :blk if (cur < 1.0) sign * std.math.sqrt(1 - cur) else 0;
                    } else try self.readFloatProp(float);
                    return EntProp.Value{ .vec3 = .{ x, y, z } };
                },
                .vec2 => |float| {
                    const x = try self.readFloatProp(float);
                    const y = try self.readFloatProp(float);
                    return EntProp.Value{ .vec2 = .{ x, y } };
                },
                .string => {
                    const len = try self.br.readInt(u9);
                    const buf = try self.arena.alloc(u8, len);
                    try self.br.reader().readNoEof(buf);
                    return EntProp.Value{ .string = buf };
                },
                .array => |arr| {
                    const nelems_bits = std.math.log2(arr.length) + 1;
                    const nelems = try self.br.readUnsigned(u10, nelems_bits);
                    //if (nelems != arr.length) std.log.info("      vvv NOTE ARRAY CHANGED SIZE {} TO {}", .{ arr.length, nelems }); TODO ???
                    const buf = try self.arena.alloc(EntProp.Value, nelems);
                    for (buf) |*val| {
                        val.* = try self.readSendInfo(arr.elem.*);
                    }
                    return EntProp.Value{ .array = buf };
                },
            }
        }
    };
}

// note: returned slice is allocated on temp allocator, free or dupe manually
pub fn parseEntProps(
    raw_allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    br: anytype,
    class: Demo.ProcessedClass,
) ![]EntProp {
    var epp = EntPropParser(@TypeOf(br)){
        .raw_allocator = raw_allocator,
        .arena = arena,
        .br = br,
    };
    return epp.parseEntProps(class);
}
