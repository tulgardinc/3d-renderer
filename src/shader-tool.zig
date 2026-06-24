const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_wgsl() *const c.TSLanguage;

const vs_query_string =
    \\(function_decl 
    \\  (attribute (vertex_attr)) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)
    \\    (param_list) @params))
;

const fs_entry_query =
    \\(function_decl 
    \\  (attribute (fragment_attr)) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)
    \\    (param_list) @params))
;

const cp_entry_query =
    \\(function_decl 
    \\  (attribute (compute_attr)) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)
    \\    (param_list) @params))
;

const EntryTypes = enum {
    vertex,
    fragment,
    compute,
};

const WGSLScalar = enum {
    bool,
    f16,
    f32,
    i32,
    u32,
};

const WGSLTextureScalar = enum {
    f32,
    i32,
    u32,
};

const SampledTextures = enum {
    texture_1d,
    texture_2d,
    texture_2d_array,
    texture_3d,
    texture_cube,
    texture_cube_array,
    texture_multisampled_2d,
};

const DepthTextures = enum {
    texture_depth_2d,
    texture_depth_2d_array,
    texture_depth_cube,
    texture_depth_cube_array,
    texture_depth_multisampled_2d,
};

const StorageTextures = enum {
    texture_storage_1d,
    texture_storage_2d,
    texture_storage_2d_array,
    texture_storage_3d,
};

const WGSLTypes = union(enum) {
    scalar: WGSLScalar,
    vec: struct {
        size: u32,
        scalar: WGSLScalar,
    },
    mat: struct {
        cols: u32,
        rows: u32,
        scalar: WGSLScalar,
    },
    array: struct {
        max_size: ?u32,
        type: *const WGSLTypes,
    },
    texture: union(enum) {
        sampled_texture: struct {
            type: SampledTextures,
            scalar: WGSLTextureScalar,
        },
        depth_texture: DepthTextures,
        storage_texture: StorageTextures,
        external_texture: void,
    },
    sampler: enum { sampler, sampler_comparison },
    struct_ref: []const u8,
};

const EntryParameter = struct {
    name: []const u8,
    type: WGSLTypes,
};

const ShaderEntry = struct {
    name: []const u8,
    type: EntryTypes,
    parameters: []const EntryParameter,
};

fn nodeText(src: []const u8, node: c.TSNode) []const u8 {
    const start = c.ts_node_start_byte(node);
    const end = c.ts_node_end_byte(node);
    return src[start..end];
}

fn findChild(node: c.TSNode, node_type: []const u8) ?c.TSNode {
    const count = c.ts_node_child_count(node);
    for (0..count) |i| {
        const child = c.ts_node_child(node, @intCast(i));
        if (std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), node_type))
            return child;
    }
    return null;
}

fn parseWGSLType(src: []const u8, type_node: c.TSNode) ?WGSLTypes {
    const elab = findChild(type_node, "template_elaborated_ident") orelse return null;
    const ident_node = findChild(elab, "ident") orelse return null;
    const token = findChild(ident_node, "ident_pattern_token") orelse return null;
    const base_name = nodeText(src, token);

    // Try scalar
    if (std.meta.stringToEnum(WGSLScalar, base_name)) |scalar| {
        return .{ .scalar = scalar };
    }

    // vec
    if (base_name.len >= 4 and std.mem.startsWith(u8, base_name, "vec") and
        base_name[3] >= '2' and base_name[3] <= '4')
    {
        const size: u32 = base_name[3] - '0';

        // generic
        if (findChild(elab, "template_list")) |tmpl| {
            const inner = findDescendant(tmpl, "ident_pattern_token") orelse return null;
            const scalar = std.meta.stringToEnum(WGSLScalar, nodeText(src, inner)) orelse return null;
            return .{ .vec = .{ .size = size, .scalar = scalar } };
        }

        // alias
        if (base_name.len == 5) {
            const scalar: WGSLScalar = switch (base_name[4]) {
                'f' => .f32,
                'h' => .f16,
                'i' => .i32,
                'u' => .u32,
                else => return null,
            };
            return .{ .vec = .{ .size = size, .scalar = scalar } };
        }

        return null;
    }

    // mat
    if (base_name.len >= 4 and std.mem.startsWith(u8, base_name, "mat") and
        base_name[3] >= '2' and
        base_name[3] <= '4' and
        base_name[4] == 'x' and
        base_name[5] >= '2' and
        base_name[5] <= '4')
    {
        // generic
        const rows = base_name[3] - '0';
        const cols = base_name[5] - '0';

        if (findChild((elab), "template_list")) |tmpl| {
            const inner = findDescendant(tmpl, "ident_pattern_token") orelse return null;
            const scalar = std.meta.stringToEnum(WGSLScalar, nodeText(src, inner)) orelse return null;
            return .{ .mat = .{ .rows = rows, .cols = cols, .scalar = scalar } };
        }

        // alias
        if (base_name.len == 7) {
            const scalar: WGSLScalar = switch (base_name[6]) {
                'f' => .f32,
                'h' => .f16,
                'i' => .i32,
                'u' => .u32,
                else => return null,
            };
            return .{ .mat = .{ .rows = rows, .cols = cols, .scalar = scalar } };
        }

        return null;
    }

    // Unknown type — treat as struct ref
    return .{ .struct_ref = base_name };
}

pub fn captureNameFromId(query: ?*c.TSQuery, index: u32) []const u8 {
    var length: u32 = 0;
    const name_ptr = c.ts_query_capture_name_for_id(query, index, &length);
    return name_ptr[0..length];
}

pub fn findDescendant(node: c.TSNode, node_type: []const u8) ?c.TSNode {
    const count = c.ts_node_child_count(node);
    for (0..count) |i| {
        const child = c.ts_node_child(node, @intCast(i));
        if (std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), node_type))
            return child;
        if (findDescendant(child, node_type)) |found| return found;
    }
    return null;
}

pub fn getEntryFunctions(arena: std.mem.Allocator, src: []const u8, root: c.TSNode, cursor: ?*c.TSQueryCursor) !std.ArrayList(ShaderEntry) {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var entry_functions: std.ArrayList(ShaderEntry) = .{};

    inline for (std.meta.fields(EntryTypes)) |enum_field| {
        const entry_type: EntryTypes = @enumFromInt(enum_field.value);
        const query_string = comptime switch (entry_type) {
            .vertex => vs_query_string,
            .fragment => fs_entry_query,
            .compute => cp_entry_query,
        };

        const query = c.ts_query_new(
            tree_sitter_wgsl(),
            query_string,
            query_string.len,
            &error_offset,
            @ptrCast(&error_type),
        );
        defer c.ts_query_delete(query);

        if (query == null) {
            std.debug.print("error at: {s}\n", .{query_string[error_offset..]});
            return error.BadQuery;
        }

        c.ts_query_cursor_exec(cursor, query, root);

        var match: c.TSQueryMatch = undefined;

        var shader_entry: ShaderEntry = undefined;
        shader_entry.type = entry_type;

        while (c.ts_query_cursor_next_match(cursor, &match)) {
            var name: ?[]const u8 = null;
            var params: std.ArrayList(EntryParameter) = .empty;

            for (match.captures[0..match.capture_count]) |cap| {
                const cap_name = captureNameFromId(query, cap.index);
                if (std.mem.eql(u8, cap_name, "fn_name")) {
                    name = nodeText(src, cap.node);
                } else if (std.mem.eql(u8, cap_name, "params")) {
                    const count = c.ts_node_named_child_count(cap.node);
                    for (0..count) |i| {
                        const param = c.ts_node_named_child(cap.node, @intCast(i));
                        const ident = findChild(param, "ident") orelse continue;
                        const token = findChild(ident, "ident_pattern_token") orelse continue;
                        const type_sp = findChild(param, "type_specifier") orelse continue;
                        const ty = parseWGSLType(src, type_sp) orelse continue;
                        try params.append(arena, .{ .name = nodeText(src, token), .type = ty });
                    }
                }
            }

            if (name) |n| {
                try entry_functions.append(arena, .{ .name = n, .parameters = params.items, .type = entry_type });
            }
        }
    }

    return entry_functions;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parser = c.ts_parser_new();
    _ = c.ts_parser_set_language(parser, tree_sitter_wgsl());
    // const src = @embedFile("./shaders/2DVertexColors.wgsl");
    const src = "@vertex fn vs(test1: u32, test2: f32) -> VertexOutput {}\n@fragment fn fs(test3: vec2<u32>, test4: vec4<f32>) -> FragmentOutput {}";
    const tree = c.ts_parser_parse_string(parser, null, src, src.len);

    const root = c.ts_tree_root_node(tree);

    // const str = c.ts_node_string(root);
    // std.debug.print("{s}\n", .{str});

    const cursor = c.ts_query_cursor_new();
    defer c.ts_query_cursor_delete(cursor);

    const entries = try getEntryFunctions(allocator, src, root, cursor);
    for (entries.items) |e| {
        std.debug.print("{f}\n", .{std.json.fmt(e, .{})});
    }
}
