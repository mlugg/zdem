const Demo = @import("Demo.zig");
const packet_parser = @import("packet_parser.zig");
const PanicOnParse = packet_parser.PanicOnParse;
const ParseArrayLength = packet_parser.ParseArrayLength;

pub const PacketType = enum(u6) {
    net_nop,
    net_disconnect,
    net_file,
    net_splitscreen_user,
    net_tick,
    net_string_cmd,
    net_set_convar,
    net_signon_state,
    svc_server_info,
    svc_send_table,
    svc_class_info,
    svc_set_pause,
    svc_create_string_table,
    svc_update_string_table,
    svc_voice_init,
    svc_voice_data,
    svc_print,
    svc_sounds,
    svc_set_view,
    svc_fix_angle,
    svc_crosshair_angle,
    svc_bsp_decal,
    svc_splitscreen,
    svc_user_message,
    svc_entity_message,
    svc_game_event,
    svc_packet_entities,
    svc_temp_entities,
    svc_prefetch,
    svc_menu,
    svc_game_event_list,
    svc_get_cvar_value,
    svc_cmd_keyvalues,
    svc_paintmap_data,
};

pub const NetSvcMessage = union(PacketType) {
    net_nop: struct {},
    net_disconnect: struct { str: []u8 },
    net_file: struct {
        transfer_id: i32,
        file_name: []u8,
        file_requested: bool,
    },
    net_splitscreen_user: struct { slot: u1 },
    net_tick: struct {
        tick: u32,
        host_frametime: f32,
        host_frametime_stddev: f32,
        pub const parse = packet_parser.parseNetTick;
    },
    net_string_cmd: struct { cmd: []u8 },
    net_set_convar: struct {
        _vars_len: ParseArrayLength("vars", u8),
        vars: []Var,
        const Var = struct {
            name: []u8,
            val: []u8,
        };
    },
    net_signon_state: struct {
        state: u8,
        spawn_count: u32,
        num_players: u32,
        _ids_len: ParseArrayLength("player_net_ids", u32),
        player_net_ids: []u8,
        _map_name_len: ParseArrayLength("map_name", u32),
        map_name: []u8,
    },
    svc_server_info: struct {
        protocol: u16,
        server_count: u32,
        is_hltv: bool,
        is_dedicated: bool,
        client_crc: u32,
        string_table_crc: u32,
        max_classes: u16,
        map_crc: u32,
        player_slot: u8,
        max_clients: u8,
        tick_interval: f32,
        os: enum {
            windows,
            linux,
            pub const parse = packet_parser.parseOs;
        },
        game_dir: []u8,
        map_name: []u8,
        sky_name: []u8,
        host_name: []u8,
    },
    svc_send_table: PanicOnParse("Parser for SVC_SendTable not implemented"),
    svc_class_info: struct {
        class_count: u16,
        pub const parse = packet_parser.parseSvcClassInfo;
    },
    svc_set_pause: struct { paused: bool },
    svc_create_string_table: struct { //PanicOnParse("Parser for SVC_CreateStringTable not implemented"), TODO
        pub const parse = packet_parser.stubSvcCreateStringTable;
    },
    svc_update_string_table: struct { //PanicOnParse("Parser for SVC_UpdateStringTable not implemented"), TODO
        pub const parse = packet_parser.stubSvcUpdateStringTable;
    },
    svc_voice_init: struct {
        codec: []u8,
        quality: u8,
    },
    svc_voice_data: struct {
        from_client: u8,
        proximity: u8,
        _data_len: ParseArrayLength("data", u16),
        audible: [2]bool,
        data: []u1,
    },
    svc_print: struct { text: []u8 },
    svc_sounds: struct {
        reliable: bool,
        // WIP
        pub const parse = packet_parser.parseSvcSounds;
    },
    svc_set_view: struct { ent_idx: u11 },
    svc_fix_angle: struct {
        relative: bool,
        angle: [3]f32,
        pub const parse = packet_parser.parseSvcFixAngle;
    },
    svc_crosshair_angle: struct {
        angle: [3]f32,
        pub const parse = packet_parser.parseSvcCrosshairAngle;
    },
    svc_bsp_decal: struct {
        pos: [3]?f32,
        decal_texture_index: u9,
        indices: ?struct {
            entity: u11,
            model: u11,
        },
        low_priority: bool,
        pub const parse = packet_parser.parseSvcBspDecal;
    },
    svc_splitscreen: struct {
        remove: bool,
        slot: u11,
    },
    svc_user_message: struct { //PanicOnParse("Parser for SVC_UserMessage not implemented"), TODO
        pub const parse = packet_parser.stubSvcUserMessage;
    },
    svc_entity_message: struct {
        entity_index: u11,
        class_id: u9,
        _data_len: ParseArrayLength("data", u11),
        data: []u1, // WIP
    },
    svc_game_event: struct {
        _data_len: ParseArrayLength("data", u11),
        data: []u1, // WIP
    },
    svc_packet_entities: struct {
        max_entries: u11,
        delta_from: ?*Demo.NetSvcMessage,
        baseline: bool,
        update_baseline: bool,
        updates: []EntityUpdate,
        pub const EntityUpdate = struct {
            idx: u11,
            update: union(enum) {
                new: struct {
                    class_idx: u32,
                    serial: u10,
                    props: []Demo.EntProp,
                },
                delete,
                re_enter_pvs: struct { props: []Demo.EntProp },
                leave_pvs,
                delta: struct { props: []Demo.EntProp },
            },
        };
        pub const parse = packet_parser.parseSvcPacketEntities;
        pub const postParse = packet_parser.postParseSvcPacketEntities;
    },
    svc_temp_entities: struct {
        entry_count: u8,
        _data_len: ParseArrayLength("data", u17),
        data: []u1, // WIP
    },
    svc_prefetch: struct {
        sound_index: u13,
    },
    svc_menu: struct {
        menu_type: u16,
        _data_len: ParseArrayLength("data", u32),
        data: []u8, // WIP
    },
    svc_game_event_list: struct {
        num_events: u9,
        _data_len: ParseArrayLength("data", u20),
        data: []u1, // WIP
    },
    svc_get_cvar_value: struct {
        cookie: i32,
        name: []u8,
    },
    svc_cmd_keyvalues: struct {
        _data_len: ParseArrayLength("data", u32),
        data: []u8, // WIP
    },
    svc_paintmap_data: struct {
        _data_len: ParseArrayLength("data", u32),
        data: []u1, // WIP
    },
};
