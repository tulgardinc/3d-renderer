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
    \\    (param_list) 
    \\    (template_elaborated_ident) @ret))
;

const cp_entry_query =
    \\(function_decl 
    \\  (attribute (compute_attr)) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)
    \\    (param_list) @params))
;

const struct_decl_query =
    \\(struct_decl) @decl
;

const binding_decl_query =
    \\(global_variable_decl
    \\  (attribute (group_attr))
    \\  (attribute (binding_attr))) @decl
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
    texture: TextureType,
    sampler: SamplerType,
    struct_ref: []const u8,
};

const ParamOrField = struct {
    name: []const u8,
    type: WGSLTypes,
    location: ?u32,
};

const ShaderEntry = union(EntryTypes) {
    vertex: struct {
        name: []const u8,
        parameters: []const ParamOrField,
    },
    fragment: struct {
        name: []const u8,
        ret: WGSLTypes,
    },
    compute: struct {
        name: []const u8,
    },
};

const ViewDimension = enum {
    @"1d",
    @"2d",
    @"2d_array",
    @"3d",
    cube,
    cube_array,
};

const SampleType = enum {
    float,
    unfilterable_float,
    sint,
    uint,
    depth,
};

const SamplerType = enum { sampler, sampler_comparison };

const TextureType = union(enum) {
    sampled_texture: struct { dim: SampledTextures, scalar: WGSLTextureScalar },
    depth_texture: DepthTextures,
    storage_texture: struct { dim: StorageTextures, format: TextureFormat, access: enum { write, read, read_write } },
    external_texture,
};

const BindingResource = union(enum) {
    uniform_buffer: struct { type: WGSLTypes },
    storage_buffer: struct { type: WGSLTypes, access: enum { read, read_write } },
    texture: TextureType,
    sampler: SamplerType,
};

const Binding = struct {
    group: u32,
    binding: u32,
    name: []const u8,
    resource: BindingResource,
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

fn getLocation(src: []const u8, param: c.TSNode) !?u32 {
    const count = c.ts_node_named_child_count(param);
    for (0..count) |i| {
        const child = c.ts_node_named_child(param, @intCast(i));
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), "attribute")) continue;

        const loc_attr = findChild(child, "location_attr") orelse continue;
        const lit = findDescendant(loc_attr, "int_literal") orelse return null;
        return parseWGSLUint(nodeText(src, lit));
    }

    return null;
}

fn getBinding(src: []const u8, param: c.TSNode) !?u32 {
    const count = c.ts_node_named_child_count(param);
    for (0..count) |i| {
        const child = c.ts_node_named_child(param, @intCast(i));
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), "attribute")) continue;

        const loc_attr = findChild(child, "binding_attr") orelse continue;
        const lit = findDescendant(loc_attr, "int_literal") orelse return null;
        return parseWGSLUint(nodeText(src, lit));
    }

    return null;
}

fn getGroup(src: []const u8, param: c.TSNode) !?u32 {
    const count = c.ts_node_named_child_count(param);
    for (0..count) |i| {
        const child = c.ts_node_named_child(param, @intCast(i));
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(child)), "attribute")) continue;

        const loc_attr = findChild(child, "group_attr") orelse continue;
        const lit = findDescendant(loc_attr, "int_literal") orelse return null;
        return parseWGSLUint(nodeText(src, lit));
    }

    return null;
}

fn parseWGSLUint(text: []const u8) !?u32 {
    var s = text;
    if (s.len > 0 and (s[s.len - 1] == 'u' or s[s.len - 1] == 'i')) s = s[0 .. s.len - 1];
    return try std.fmt.parseInt(u32, s, 0);
}

fn parseWGSLType(src: []const u8, type_node: c.TSNode) ?WGSLTypes {
    const ident_node = findChild(type_node, "ident") orelse return null;
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
        if (findChild(type_node, "template_list")) |tmpl| {
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

        if (findChild((type_node), "template_list")) |tmpl| {
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

    // texture
    if (std.mem.startsWith(u8, base_name, "texture_")) {
        if (std.meta.stringToEnum(SampledTextures, base_name)) |tex_dim| {
            if (findChild((type_node), "template_list")) |tmpl| {
                const inner = findDescendant(tmpl, "ident_pattern_token") orelse return null;
                const scalar = std.meta.stringToEnum(WGSLTextureScalar, nodeText(src, inner)) orelse return null;
                return .{ .texture = .{
                    .sampled_texture = .{
                        .dim = tex_dim,
                        .scalar = scalar,
                    },
                } };
            }
        } else if (std.meta.stringToEnum(DepthTextures, base_name)) |depth_tex| {
            return .{ .texture = .{ .depth_texture = depth_tex } };
        }

        return null;

        // TODO storage textures
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

pub fn getStructDeclerations(
    arena: std.mem.Allocator,
    src: []const u8,
    root: c.TSNode,
    cursor: ?*c.TSQueryCursor,
) !std.StringHashMapUnmanaged(std.ArrayList(ParamOrField)) {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var struct_declerations: std.StringHashMapUnmanaged(std.ArrayList(ParamOrField)) = .empty;

    const query = c.ts_query_new(
        tree_sitter_wgsl(),
        struct_decl_query,
        struct_decl_query.len,
        &error_offset,
        @ptrCast(&error_type),
    );
    defer c.ts_query_delete(query);

    if (query == null) {
        std.debug.print("error at: {s}\n", .{struct_decl_query[error_offset..]});
        return error.BadQuery;
    }

    c.ts_query_cursor_exec(cursor, query, root);
    var match: c.TSQueryMatch = undefined;

    while (c.ts_query_cursor_next_match(cursor, &match)) {
        for (match.captures[0..match.capture_count]) |cap| {
            const name_node = findChild(cap.node, "ident") orelse continue;
            const name = nodeText(src, name_node);
            var fields: std.ArrayList(ParamOrField) = .empty;
            const body_node = findChild(cap.node, "struct_body_decl") orelse continue;
            const field_count = c.ts_node_named_child_count(body_node);
            for (0..field_count) |i| {
                const field_token = c.ts_node_named_child(body_node, @intCast(i));
                const field_location = try getLocation(src, field_token);
                const ident_token = findChild(field_token, "member_ident") orelse continue;
                const field_name = nodeText(src, ident_token);
                const elab_token = findDescendant(field_token, "template_elaborated_ident") orelse continue;
                const field_type = parseWGSLType(src, elab_token) orelse continue;
                try fields.append(arena, .{
                    .name = field_name,
                    .location = field_location,
                    .type = field_type,
                });
            }

            try struct_declerations.put(arena, name, fields);
        }
    }

    return struct_declerations;
}

pub fn getBindingResource(src: []const u8, var_decl: c.TSNode) ?BindingResource {
    const var_type_token = findDescendant(var_decl, "type_specifier") orelse return null;
    const elab = findChild(var_type_token, "template_elaborated_ident") orelse return null;
    const var_type = parseWGSLType(src, elab) orelse return null;
    if (findChild(var_decl, "template_list")) |addr_space| {
        const args = findChild(addr_space, "template_arg_comma_list") orelse return null;
        const buffer_type_token = c.ts_node_named_child(args, 0);
        const buffer_type = nodeText(src, buffer_type_token);
        if (std.mem.eql(u8, buffer_type, "uniform")) {
            return BindingResource{ .uniform_buffer = .{ .type = var_type } };
        } else {
            const access_token = c.ts_node_named_child(args, 1);
            const access_text = nodeText(src, access_token);
            return BindingResource{
                .storage_buffer = .{
                    .type = var_type,
                    .access = if (std.mem.eql(u8, access_text, "read")) .read else .read_write,
                },
            };
        }
    } else {
        switch (var_type) {
            .sampler => |smp| {
                return BindingResource{ .sampler = smp };
            },
            .texture => |tex| {
                return BindingResource{ .texture = tex };
            },
            else => return null,
        }
    }
}

pub fn getBindingDeclerations(arena: std.mem.Allocator, src: []const u8, root: c.TSNode, cursor: ?*c.TSQueryCursor) !std.ArrayList(Binding) {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var binding_declerations: std.ArrayList(Binding) = .empty;

    const query = c.ts_query_new(
        tree_sitter_wgsl(),
        binding_decl_query,
        binding_decl_query.len,
        &error_offset,
        @ptrCast(&error_type),
    );
    defer c.ts_query_delete(query);

    if (query == null) {
        std.debug.print("error at: {s}\n", .{binding_decl_query[error_offset..]});
        return error.BadQuery;
    }

    c.ts_query_cursor_exec(cursor, query, root);
    var match: c.TSQueryMatch = undefined;

    while (c.ts_query_cursor_next_match(cursor, &match)) {
        for (match.captures[0..match.capture_count]) |cap| {
            const group = try getGroup(src, cap.node) orelse continue;
            const binding = try getBinding(src, cap.node) orelse continue;
            const opt_token = findDescendant(cap.node, "optionally_typed_ident") orelse continue;
            const name_token = findDescendant(opt_token, "ident_pattern_token") orelse continue;
            const name = nodeText(src, name_token);
            const var_decl = findChild(cap.node, "variable_decl") orelse continue;
            const resource = getBindingResource(src, var_decl) orelse continue;
            try binding_declerations.append(arena, .{
                .group = group,
                .binding = binding,
                .name = name,
                .resource = resource,
            });
        }
    }

    return binding_declerations;
}

// (translation_unit (global_variable_decl
// (attribute (group_attr (expression (relational_expression (shift_expr
// ession (additive_expression (multiplicative_expression (unary_expression (singular_expression (primary_expres
// sion (literal (int_literal (decimal_int_literal)))))))))))))
// (attribute (binding_attr (expression (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_exp
// ression (primary_expression (literal (int_literal (decimal_int_literal)))))))))))))
// (variable_decl (optionally_typed_ident (ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern_
// token)) (template_list (template_arg_comma_list (template_arg_expression (expression (relational_expression (
// shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_expression (prim
// ary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))))))))

// (translation_unit (global_variable_decl
// (attribute (group_attr (expression (relational_expression (shift_expr
// ession (additive_expression (multiplicative_expression (unary_expression (singular_expression (primary_expres
// sion (literal (int_literal (decimal_int_literal)))))))))))))
// (attribute (binding_attr (expression (relational
// _expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_exp
// ression (primary_expression (literal (int_literal (decimal_int_literal)))))))))))))
// (variable_decl (template_list (template_arg_comma_list
// (template_arg_expression (expression (relational_expression (shift_expression (
// additive_expression (multiplicative_expression (unary_expression (singular_expression (primary_expression (te
// mplate_elaborated_ident (ident (ident_pattern_token))))))))))))
// (template_arg_expression (expression (relatio
// nal_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_
// expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))
// (optionally_typed_ident (ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern
// _token)) (template_list (template_arg_comma_list (template_arg_expression (expression (relational_expression
// (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_expression (pri
// mary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))))))))

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

        switch (entry_type) {
            .vertex => {
                while (c.ts_query_cursor_next_match(cursor, &match)) {
                    var name: ?[]const u8 = null;
                    var params: std.ArrayList(ParamOrField) = .empty;

                    for (match.captures[0..match.capture_count]) |cap| {
                        const cap_name = captureNameFromId(query, cap.index);
                        if (std.mem.eql(u8, cap_name, "fn_name")) {
                            name = nodeText(src, cap.node);
                        } else if (std.mem.eql(u8, cap_name, "params")) {
                            const count = c.ts_node_named_child_count(cap.node);
                            for (0..count) |i| {
                                const param = c.ts_node_named_child(cap.node, @intCast(i));
                                const location = try getLocation(src, param);
                                const ident = findChild(param, "ident") orelse continue;
                                const token = findChild(ident, "ident_pattern_token") orelse continue;
                                const type_sp = findChild(param, "type_specifier") orelse continue;
                                const type_tok = findChild(type_sp, "template_elaborated_ident") orelse continue;
                                const ty = parseWGSLType(src, type_tok) orelse continue;
                                try params.append(arena, .{
                                    .name = nodeText(src, token),
                                    .type = ty,
                                    .location = location,
                                });
                            }
                        }
                    }

                    if (name) |n| {
                        try entry_functions.append(arena, .{
                            .vertex = .{
                                .name = n,
                                .parameters = params.items,
                            },
                        });
                    }
                }
            },
            .fragment => {
                while (c.ts_query_cursor_next_match(cursor, &match)) {
                    var name: ?[]const u8 = null;
                    var ret_type: WGSLTypes = undefined;

                    for (match.captures[0..match.capture_count]) |cap| {
                        const cap_name = captureNameFromId(query, cap.index);
                        if (std.mem.eql(u8, cap_name, "fn_name")) {
                            name = nodeText(src, cap.node);
                        } else if (std.mem.eql(u8, cap_name, "ret")) {
                            ret_type = parseWGSLType(src, cap.node) orelse return error.FailedToParseReturn;
                        }
                    }

                    if (name) |n| {
                        try entry_functions.append(arena, .{
                            .fragment = .{
                                .name = n,
                                .ret = ret_type,
                            },
                        });
                    }
                }
            },
            .compute => {
                while (c.ts_query_cursor_next_match(cursor, &match)) {
                    var name: ?[]const u8 = null;

                    for (match.captures[0..match.capture_count]) |cap| {
                        const cap_name = captureNameFromId(query, cap.index);
                        if (std.mem.eql(u8, cap_name, "fn_name")) {
                            name = nodeText(src, cap.node);
                        }
                    }

                    if (name) |n| {
                        try entry_functions.append(arena, .{
                            .compute = .{
                                .name = n,
                            },
                        });
                    }
                }
            },
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
    const src = @embedFile("./shaders/2DVertexColors.wgsl");
    // const src =
    //     \\@vertex
    //     \\fn vs(in: VertexInput) -> VertexOutput {}
    // ;
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

    const bindings = try getBindingDeclerations(allocator, src, root, cursor);
    for (bindings.items) |e| {
        std.debug.print("{f}\n", .{std.json.fmt(e, .{})});
    }

    const struct_decls = try getStructDeclerations(allocator, src, root, cursor);
    var iter = struct_decls.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{s}\n", .{entry.key_ptr.*});
        for (entry.value_ptr.items) |field| {
            std.debug.print("{f}\n", .{std.json.fmt(field, .{})});
        }
    }
}

pub const TextureFormat = enum {
    undefined,
    r8_unorm,
    r8_snorm,
    r8_uint,
    r8_sint,
    r16_unorm,
    r16_snorm,
    r16_uint,
    r16_sint,
    r16_float,
    rg8_unorm,
    rg8_snorm,
    rg8_uint,
    rg8_sint,
    r32_float,
    r32_uint,
    r32_sint,
    rg16_unorm,
    rg16_snorm,
    rg16_uint,
    rg16_sint,
    rg16_float,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba8_snorm,
    rgba8_uint,
    rgba8_sint,
    bgra8_unorm,
    bgra8_unorm_srgb,
    rgb10a2_uint,
    rgb10a2_unorm,
    rg11b10_ufloat,
    rgb9e5_ufloat,
    rg32_float,
    rg32_uint,
    rg32_sint,
    rgba16_unorm,
    rgba16_snorm,
    rgba16_uint,
    rgba16_sint,
    rgba16_float,
    rgba32_float,
    rgba32_uint,
    rgba32_sint,
    stencil8,
    depth16_unorm,
    depth24_plus,
    depth24_plus_stencil8,
    depth32_float,
    depth32_float_stencil8,
    bc1_rgba_unorm,
    bc1_rgba_unorm_srgb,
    bc2_rgba_unorm,
    bc2_rgba_unorm_srgb,
    bc3_rgba_unorm,
    bc3_rgba_unorm_srgb,
    bc4_r_unorm,
    bc4_r_snorm,
    bc5_rg_unorm,
    bc5_rg_snorm,
    bc6h_rgb_ufloat,
    bc6h_rgb_float,
    bc7_rgba_unorm,
    bc7_rgba_unorm_srgb,
    etc2_rgb8_unorm,
    etc2_rgb8_unorm_srgb,
    etc2_rgb8a1_unorm,
    etc2_rgb8a1_unorm_srgb,
    etc2_rgba8_unorm,
    etc2_rgba8_unorm_srgb,
    eac_r11_unorm,
    eac_r11_snorm,
    eac_rg11_unorm,
    eac_rg11_snorm,
    astc4x4_unorm,
    astc4x4_unorm_srgb,
    astc5x4_unorm,
    astc5x4_unorm_srgb,
    astc5x5_unorm,
    astc5x5_unorm_srgb,
    astc6x5_unorm,
    astc6x5_unorm_srgb,
    astc6x6_unorm,
    astc6x6_unorm_srgb,
    astc8x5_unorm,
    astc8x5_unorm_srgb,
    astc8x6_unorm,
    astc8x6_unorm_srgb,
    astc8x8_unorm,
    astc8x8_unorm_srgb,
    astc10x5_unorm,
    astc10x5_unorm_srgb,
    astc10x6_unorm,
    astc10x6_unorm_srgb,
    astc10x8_unorm,
    astc10x8_unorm_srgb,
    astc10x10_unorm,
    astc10x10_unorm_srgb,
    astc12x10_unorm,
    astc12x10_unorm_srgb,
    astc12x12_unorm,
    astc12x12_unorm_srgb,
    r8bg8_biplanar420_unorm,
    r10x6bg10x6_biplanar420_unorm,
    r8bg8a8_triplanar420_unorm,
    r8bg8_biplanar422_unorm,
    r8bg8_biplanar444_unorm,
    r10x6bg10x6_biplanar422_unorm,
    r10x6bg10x6_biplanar444_unorm,
    external,

    pub fn wgpuName(self: TextureFormat) []const u8 {
        return switch (self) {
            .undefined => "c.WGPUTextureFormat_Undefined",
            .r8_unorm => "c.WGPUTextureFormat_R8Unorm",
            .r8_snorm => "c.WGPUTextureFormat_R8Snorm",
            .r8_uint => "c.WGPUTextureFormat_R8Uint",
            .r8_sint => "c.WGPUTextureFormat_R8Sint",
            .r16_unorm => "c.WGPUTextureFormat_R16Unorm",
            .r16_snorm => "c.WGPUTextureFormat_R16Snorm",
            .r16_uint => "c.WGPUTextureFormat_R16Uint",
            .r16_sint => "c.WGPUTextureFormat_R16Sint",
            .r16_float => "c.WGPUTextureFormat_R16Float",
            .rg8_unorm => "c.WGPUTextureFormat_RG8Unorm",
            .rg8_snorm => "c.WGPUTextureFormat_RG8Snorm",
            .rg8_uint => "c.WGPUTextureFormat_RG8Uint",
            .rg8_sint => "c.WGPUTextureFormat_RG8Sint",
            .r32_float => "c.WGPUTextureFormat_R32Float",
            .r32_uint => "c.WGPUTextureFormat_R32Uint",
            .r32_sint => "c.WGPUTextureFormat_R32Sint",
            .rg16_unorm => "c.WGPUTextureFormat_RG16Unorm",
            .rg16_snorm => "c.WGPUTextureFormat_RG16Snorm",
            .rg16_uint => "c.WGPUTextureFormat_RG16Uint",
            .rg16_sint => "c.WGPUTextureFormat_RG16Sint",
            .rg16_float => "c.WGPUTextureFormat_RG16Float",
            .rgba8_unorm => "c.WGPUTextureFormat_RGBA8Unorm",
            .rgba8_unorm_srgb => "c.WGPUTextureFormat_RGBA8UnormSrgb",
            .rgba8_snorm => "c.WGPUTextureFormat_RGBA8Snorm",
            .rgba8_uint => "c.WGPUTextureFormat_RGBA8Uint",
            .rgba8_sint => "c.WGPUTextureFormat_RGBA8Sint",
            .bgra8_unorm => "c.WGPUTextureFormat_BGRA8Unorm",
            .bgra8_unorm_srgb => "c.WGPUTextureFormat_BGRA8UnormSrgb",
            .rgb10a2_uint => "c.WGPUTextureFormat_RGB10A2Uint",
            .rgb10a2_unorm => "c.WGPUTextureFormat_RGB10A2Unorm",
            .rg11b10_ufloat => "c.WGPUTextureFormat_RG11B10Ufloat",
            .rgb9e5_ufloat => "c.WGPUTextureFormat_RGB9E5Ufloat",
            .rg32_float => "c.WGPUTextureFormat_RG32Float",
            .rg32_uint => "c.WGPUTextureFormat_RG32Uint",
            .rg32_sint => "c.WGPUTextureFormat_RG32Sint",
            .rgba16_unorm => "c.WGPUTextureFormat_RGBA16Unorm",
            .rgba16_snorm => "c.WGPUTextureFormat_RGBA16Snorm",
            .rgba16_uint => "c.WGPUTextureFormat_RGBA16Uint",
            .rgba16_sint => "c.WGPUTextureFormat_RGBA16Sint",
            .rgba16_float => "c.WGPUTextureFormat_RGBA16Float",
            .rgba32_float => "c.WGPUTextureFormat_RGBA32Float",
            .rgba32_uint => "c.WGPUTextureFormat_RGBA32Uint",
            .rgba32_sint => "c.WGPUTextureFormat_RGBA32Sint",
            .stencil8 => "c.WGPUTextureFormat_Stencil8",
            .depth16_unorm => "c.WGPUTextureFormat_Depth16Unorm",
            .depth24_plus => "c.WGPUTextureFormat_Depth24Plus",
            .depth24_plus_stencil8 => "c.WGPUTextureFormat_Depth24PlusStencil8",
            .depth32_float => "c.WGPUTextureFormat_Depth32Float",
            .depth32_float_stencil8 => "c.WGPUTextureFormat_Depth32FloatStencil8",
            .bc1_rgba_unorm => "c.WGPUTextureFormat_BC1RGBAUnorm",
            .bc1_rgba_unorm_srgb => "c.WGPUTextureFormat_BC1RGBAUnormSrgb",
            .bc2_rgba_unorm => "c.WGPUTextureFormat_BC2RGBAUnorm",
            .bc2_rgba_unorm_srgb => "c.WGPUTextureFormat_BC2RGBAUnormSrgb",
            .bc3_rgba_unorm => "c.WGPUTextureFormat_BC3RGBAUnorm",
            .bc3_rgba_unorm_srgb => "c.WGPUTextureFormat_BC3RGBAUnormSrgb",
            .bc4_r_unorm => "c.WGPUTextureFormat_BC4RUnorm",
            .bc4_r_snorm => "c.WGPUTextureFormat_BC4RSnorm",
            .bc5_rg_unorm => "c.WGPUTextureFormat_BC5RGUnorm",
            .bc5_rg_snorm => "c.WGPUTextureFormat_BC5RGSnorm",
            .bc6h_rgb_ufloat => "c.WGPUTextureFormat_BC6HRGBUfloat",
            .bc6h_rgb_float => "c.WGPUTextureFormat_BC6HRGBFloat",
            .bc7_rgba_unorm => "c.WGPUTextureFormat_BC7RGBAUnorm",
            .bc7_rgba_unorm_srgb => "c.WGPUTextureFormat_BC7RGBAUnormSrgb",
            .etc2_rgb8_unorm => "c.WGPUTextureFormat_ETC2RGB8Unorm",
            .etc2_rgb8_unorm_srgb => "c.WGPUTextureFormat_ETC2RGB8UnormSrgb",
            .etc2_rgb8a1_unorm => "c.WGPUTextureFormat_ETC2RGB8A1Unorm",
            .etc2_rgb8a1_unorm_srgb => "c.WGPUTextureFormat_ETC2RGB8A1UnormSrgb",
            .etc2_rgba8_unorm => "c.WGPUTextureFormat_ETC2RGBA8Unorm",
            .etc2_rgba8_unorm_srgb => "c.WGPUTextureFormat_ETC2RGBA8UnormSrgb",
            .eac_r11_unorm => "c.WGPUTextureFormat_EACR11Unorm",
            .eac_r11_snorm => "c.WGPUTextureFormat_EACR11Snorm",
            .eac_rg11_unorm => "c.WGPUTextureFormat_EACRG11Unorm",
            .eac_rg11_snorm => "c.WGPUTextureFormat_EACRG11Snorm",
            .astc4x4_unorm => "c.WGPUTextureFormat_ASTC4x4Unorm",
            .astc4x4_unorm_srgb => "c.WGPUTextureFormat_ASTC4x4UnormSrgb",
            .astc5x4_unorm => "c.WGPUTextureFormat_ASTC5x4Unorm",
            .astc5x4_unorm_srgb => "c.WGPUTextureFormat_ASTC5x4UnormSrgb",
            .astc5x5_unorm => "c.WGPUTextureFormat_ASTC5x5Unorm",
            .astc5x5_unorm_srgb => "c.WGPUTextureFormat_ASTC5x5UnormSrgb",
            .astc6x5_unorm => "c.WGPUTextureFormat_ASTC6x5Unorm",
            .astc6x5_unorm_srgb => "c.WGPUTextureFormat_ASTC6x5UnormSrgb",
            .astc6x6_unorm => "c.WGPUTextureFormat_ASTC6x6Unorm",
            .astc6x6_unorm_srgb => "c.WGPUTextureFormat_ASTC6x6UnormSrgb",
            .astc8x5_unorm => "c.WGPUTextureFormat_ASTC8x5Unorm",
            .astc8x5_unorm_srgb => "c.WGPUTextureFormat_ASTC8x5UnormSrgb",
            .astc8x6_unorm => "c.WGPUTextureFormat_ASTC8x6Unorm",
            .astc8x6_unorm_srgb => "c.WGPUTextureFormat_ASTC8x6UnormSrgb",
            .astc8x8_unorm => "c.WGPUTextureFormat_ASTC8x8Unorm",
            .astc8x8_unorm_srgb => "c.WGPUTextureFormat_ASTC8x8UnormSrgb",
            .astc10x5_unorm => "c.WGPUTextureFormat_ASTC10x5Unorm",
            .astc10x5_unorm_srgb => "c.WGPUTextureFormat_ASTC10x5UnormSrgb",
            .astc10x6_unorm => "c.WGPUTextureFormat_ASTC10x6Unorm",
            .astc10x6_unorm_srgb => "c.WGPUTextureFormat_ASTC10x6UnormSrgb",
            .astc10x8_unorm => "c.WGPUTextureFormat_ASTC10x8Unorm",
            .astc10x8_unorm_srgb => "c.WGPUTextureFormat_ASTC10x8UnormSrgb",
            .astc10x10_unorm => "c.WGPUTextureFormat_ASTC10x10Unorm",
            .astc10x10_unorm_srgb => "c.WGPUTextureFormat_ASTC10x10UnormSrgb",
            .astc12x10_unorm => "c.WGPUTextureFormat_ASTC12x10Unorm",
            .astc12x10_unorm_srgb => "c.WGPUTextureFormat_ASTC12x10UnormSrgb",
            .astc12x12_unorm => "c.WGPUTextureFormat_ASTC12x12Unorm",
            .astc12x12_unorm_srgb => "c.WGPUTextureFormat_ASTC12x12UnormSrgb",
            .r8bg8_biplanar420_unorm => "c.WGPUTextureFormat_R8BG8Biplanar420Unorm",
            .r10x6bg10x6_biplanar420_unorm => "c.WGPUTextureFormat_R10X6BG10X6Biplanar420Unorm",
            .r8bg8a8_triplanar420_unorm => "c.WGPUTextureFormat_R8BG8A8Triplanar420Unorm",
            .r8bg8_biplanar422_unorm => "c.WGPUTextureFormat_R8BG8Biplanar422Unorm",
            .r8bg8_biplanar444_unorm => "c.WGPUTextureFormat_R8BG8Biplanar444Unorm",
            .r10x6bg10x6_biplanar422_unorm => "c.WGPUTextureFormat_R10X6BG10X6Biplanar422Unorm",
            .r10x6bg10x6_biplanar444_unorm => "c.WGPUTextureFormat_R10X6BG10X6Biplanar444Unorm",
            .external => "c.WGPUTextureFormat_External",
        };
    }
};

// // ── sampled textures: dimension (→ ViewDimension), all sample as float ──
// @group(0) @binding(0)  var t_1d:        texture_1d<f32>;              // sampled_texture{ dim=1d,        sample=float, ms=false }
// @group(0) @binding(1)  var t_2d:        texture_2d<f32>;              // sampled_texture{ dim=2d,        sample=float, ms=false }
// @group(0) @binding(2)  var t_2d_arr:    texture_2d_array<f32>;       // sampled_texture{ dim=2d_array,  sample=float, ms=false }
// @group(0) @binding(3)  var t_3d:        texture_3d<f32>;             // sampled_texture{ dim=3d,         sample=float, ms=false }
// @group(0) @binding(4)  var t_cube:      texture_cube<f32>;           // sampled_texture{ dim=cube,       sample=float, ms=false }
// @group(0) @binding(5)  var t_cube_arr:  texture_cube_array<f32>;     // sampled_texture{ dim=cube_array, sample=float, ms=false }
// @group(0) @binding(6)  var t_ms:        texture_multisampled_2d<f32>;// sampled_texture{ dim=2d,         sample=float, ms=TRUE  }
//
// // ── sampled textures: component type (→ SampleType) ──
// @group(0) @binding(7)  var t_float:     texture_2d<f32>;             // sample=float   (also: unfilterable_float, but not reflectable)
// @group(0) @binding(8)  var t_sint:      texture_2d<i32>;             // sample=sint
// @group(0) @binding(9)  var t_uint:      texture_2d<u32>;             // sample=uint
//
// // ── depth textures (no <…>; sample is always depth) ──
// @group(0) @binding(10) var d_2d:        texture_depth_2d;            // sampled_texture{ dim=2d,        sample=depth, ms=false }
// @group(0) @binding(11) var d_2d_arr:    texture_depth_2d_array;      // sampled_texture{ dim=2d_array,  sample=depth, ms=false }
// @group(0) @binding(12) var d_cube:      texture_depth_cube;          // sampled_texture{ dim=cube,      sample=depth, ms=false }
// @group(0) @binding(13) var d_cube_arr:  texture_depth_cube_array;    // sampled_texture{ dim=cube_array,sample=depth, ms=false }
// @group(0) @binding(14) var d_ms:        texture_depth_multisampled_2d;// sampled_texture{ dim=2d,       sample=depth, ms=TRUE  }
//
// // ── storage textures: <format, access> — the part your parser currently drops ──
// @group(0) @binding(15) var s_1d:        texture_storage_1d<rgba8unorm, write>;        // storage_texture{ dim=1d,       format=rgba8_unorm, access=write }
// @group(0) @binding(16) var s_2d:        texture_storage_2d<rgba8unorm, write>;        // storage_texture{ dim=2d,       format=rgba8_unorm, access=write }
// @group(0) @binding(17) var s_2d_arr:    texture_storage_2d_array<r32float, read>;     // storage_texture{ dim=2d_array, format=r32_float,  access=read }
// @group(0) @binding(18) var s_3d:        texture_storage_3d<rgba16float, read_write>;  // storage_texture{ dim=3d,       format=rgba16_float,access=read_write }
//
// // ── external texture (no <…>, no sub-info) ──
// @group(0) @binding(19) var ext:         texture_external;            // external_texture
//
// // ── samplers (the type name carries filtering vs comparison) ──
// @group(0) @binding(20) var samp:        sampler;                     // sampler{ filtering }   (non-filtering not reflectable)
// @group(0) @binding(21) var samp_cmp:    sampler_comparison;          // sampler{ comparison }
