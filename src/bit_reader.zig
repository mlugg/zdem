// std.io.BitReader is missing a lot of stuff - let's make our own!
const std = @import("std");

pub fn DemoBitReader(comptime Reader: type) type {
    return struct {
        base: std.io.BitReader(.Little, Reader),

        const Self = @This();
        pub const Error = Reader.Error;

        pub fn init(r: Reader) Self {
            return Self{ .base = std.io.bitReader(.Little, r) };
        }

        pub fn readUnsigned(self: *Self, comptime I: type, bits: usize) !I {
            comptime std.debug.assert(std.meta.trait.isUnsignedInt(I));
            return self.base.readBitsNoEof(I, bits);
        }

        pub fn readSigned(self: *Self, comptime I: type, bits: usize) !I {
            comptime std.debug.assert(std.meta.trait.isSignedInt(I));
            const ShiftType = std.math.Log2Int(I);
            const sign_val = -(@as(I, 1) << @intCast(ShiftType, bits - 1));
            const sign: I = if (try self.readBool()) sign_val else 0;
            const main: I = try self.readUnsigned(std.meta.Int(.unsigned, @bitSizeOf(I) - 1), bits - 1);
            return sign + main;
        }

        pub fn readInt(self: *Self, comptime I: type) !I {
            if (comptime std.meta.trait.isSignedInt(I)) {
                const u = try self.readInt(std.meta.Int(.unsigned, @bitSizeOf(I)));
                return @bitCast(I, u);
            } else if (comptime std.meta.trait.isUnsignedInt(I)) {
                return self.readUnsigned(I, @bitSizeOf(I));
            } else {
                @compileError("Expected int type for DemoBitReader.readInt");
            }
        }

        pub fn readFloat(self: *Self, comptime F: type) !F {
            return switch (F) {
                f16 => @bitCast(f16, try self.readInt(u16)),
                f32 => @bitCast(f32, try self.readInt(u32)),
                f64 => @bitCast(f64, try self.readInt(u64)),
                else => @compileError("Expected f16, f32 or f64 for DemoBitReader.readFloat"),
            };
        }

        pub fn readBool(self: *Self) !bool {
            return 1 == try self.readInt(u1);
        }

        pub fn skipBits(self: *Self, bits: usize) !void {
            const bytes = @divFloor(bits, 8);
            const rem = bits % 8;
            try self.base.reader().skipBytes(bytes, .{});
            _ = try self.readUnsigned(u8, rem);
        }

        pub fn readString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            return self.base.reader().readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(usize));
        }

        pub fn readMoveString(self: *Self, staging_allocator: std.mem.Allocator, final_allocator: std.mem.Allocator) ![]u8 {
            const str = try self.readString(staging_allocator);
            defer staging_allocator.free(str);
            return final_allocator.dupe(u8, str);
        }

        pub fn reader(self: *Self) std.io.BitReader(.Little, Reader).Reader {
            return self.base.reader();
        }
    };
}

pub fn demoBitReader(r: anytype) DemoBitReader(@TypeOf(r)) {
    return DemoBitReader(@TypeOf(r)).init(r);
}
