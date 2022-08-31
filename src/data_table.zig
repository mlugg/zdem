const std = @import("std");

pub const DataTables = struct {
    send_tables: []SendTable,
    server_classes: []ServerClass,

    pub const SendTable = struct {
        needs_decoder: bool,
        name: []u8,
        props: []Prop,

        pub const Prop = struct {
            name: []u8,
            priority: u8,

            flags: packed struct {
                inside_array: bool,
                proxy_always_yes: bool,
                collapsible: bool,
                changes_often: bool,
            },

            info: Info,

            pub const Info = union(enum) {
                int: struct { bits: u7, signed: bool },
                float: FloatSendInfo,
                vec3: FloatSendInfo,
                vec2: FloatSendInfo,
                string,
                array: struct { length: u10 },
                data_table: struct { name: []u8 },
                exclude: struct { table: []u8 },
            };
        };
    };

    pub const ServerClass = struct {
        data_table_id: u16,
        class_name: []u8,
        table_name: []u8,
    };
};

pub const FloatSendInfo = union(enum) {
    ranged: struct {
        low: f32,
        high: f32,
        bits: u7,
        round_up: bool,
        round_down: bool,
    },
    coord,
    no_scale,
    normal,
    coord_mp,
    coord_mp_low_precision,
    coord_mp_integral,
    cell_coord: struct { bits: u7 },
    cell_coord_low_precision: struct { bits: u7 },
    cell_coord_integral: struct { bits: u7 },
};

pub const ProcessedClass = struct {
    name: []u8,
    props: std.StringArrayHashMap(Prop),

    pub const Prop = struct {
        name: []u8,
        priority: u8,
        info: SendInfo,
        flags: packed struct {
            proxy_always_yes: bool,
        },

        pub const SendInfo = union(enum) {
            int: struct { bits: u7, signed: bool },
            float: FloatSendInfo,
            vec3: FloatSendInfo,
            vec2: FloatSendInfo,
            string,
            array: struct { length: u10, elem: *SendInfo },
        };
    };
};
