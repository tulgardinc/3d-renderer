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
    \\    (ident (ident_pattern_token) @fn_name)))
;

const cp_entry_query =
    \\(function_decl 
    \\  (attribute (compute_attr)) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)))
;

const struct_decl_query =
    \\(struct_decl) @decl
;

const global_var_decl_query =
    \\(global_variable_decl) @decl
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

    pub fn getSampleString(t: WGSLTextureScalar) []const u8 {
        return switch (t) {
            .f32 => ".float",
            .i32 => ".sint",
            .u32 => ".uint",
        };
    }
};

const SampledTextures = enum {
    texture_1d,
    texture_2d,
    texture_2d_array,
    texture_3d,
    texture_cube,
    texture_cube_array,
    texture_multisampled_2d,

    pub fn getString(t: SampledTextures) []const u8 {
        return switch (t) {
            .texture_1d => ".@\"1d\"",
            .texture_2d => ".@\"2d\"",
            .texture_2d_array => ".@\"2d_array\"",
            .texture_3d => ".@\"3d\"",
            .texture_cube => ".cube",
            .texture_cube_array => ".cube_array",
            .texture_multisampled_2d => ".@\"2d\"",
        };
    }
};

const DepthTextures = enum {
    texture_depth_2d,
    texture_depth_2d_array,
    texture_depth_cube,
    texture_depth_cube_array,
    texture_depth_multisampled_2d,

    pub fn getString(t: DepthTextures) []const u8 {
        return switch (t) {
            .texture_depth_2d => ".@\"2d\"",
            .texture_depth_2d_array => ".@\"2d_array\"",
            .texture_depth_cube => ".cube",
            .texture_depth_cube_array => ".cube_array",
            .texture_depth_multisampled_2d => ".@\"2d\"",
        };
    }
};

const StorageTextures = enum {
    texture_storage_1d,
    texture_storage_2d,
    texture_storage_2d_array,
    texture_storage_3d,

    pub fn getString(t: StorageTextures) []const u8 {
        return switch (t) {
            .texture_storage_1d => ".@\"1d\"",
            .texture_storage_2d => ".@\"2d\"",
            .texture_storage_2d_array => ".@\"2d_array\"",
            .texture_storage_3d => ".@\"3d\"",
        };
    }
};

const DataType = union(enum) {
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
        type: *const DataType,
    },
    struct_ref: []const u8,

    pub fn getString(d: DataType, arena: std.mem.Allocator) ![]const u8 {
        return switch (d) {
            .scalar => |s| std.enums.tagName(WGSLScalar, s).?,
            .vec => |v| try std.fmt.allocPrint(arena, "[{any}]{s}", .{ v.size, std.enums.tagName(WGSLScalar, v.scalar).? }),
            .mat => |m| try std.fmt.allocPrint(arena, "[{any}][{any}]{s}", .{ m.cols, m.rows, std.enums.tagName(WGSLScalar, m.scalar).? }),
            .array => |a| if (a.max_size) |ms|
                try std.fmt.allocPrint(arena, "[{any}]{s}", .{ ms, try getString(a.type.*, arena) })
            else
                return error.NoString,
            .struct_ref => |s| s,
        };
    }
};

const HandleType = union(enum) {
    texture: TextureType,
    sampler: SamplerType,
};

const AddressSpace = enum { uniform, storage, handle };

// invariant for alignof and sizeof: the layout of the struct must have been previously calcualted
fn alignOf(data_type: DataType, space: AddressSpace, struct_layout_map: StructLayoutMap) ?u32 {
    return switch (data_type) {
        .scalar => 4,
        .vec => |v| if (v.size == 2) 8 else 16,
        .mat => |m| if (m.rows == 2) 8 else 16,
        .array => |arr| switch (space) {
            .uniform => 16,
            .storage => alignOf(arr.type.*, space, struct_layout_map).?,
            .handle => null,
        },
        .struct_ref => |s| switch (space) {
            .uniform => 16,
            .storage => struct_layout_map.get(s).?.alignment,
            .handle => null,
        },
    };
}

fn sizeOf(data_type: DataType, space: AddressSpace, struct_layout_map: StructLayoutMap) ?u32 {
    return switch (data_type) {
        .scalar => 4,
        .vec => |v| v.size * 4,
        .mat => |m| m.rows * m.cols * 4,
        .array => |arr| if (arr.max_size) |max_size| @max(
            alignOf(arr.type.*, space, struct_layout_map).?,
            sizeOf(arr.type.*, space, struct_layout_map).?,
        ) * max_size else null,
        .struct_ref => |s| switch (struct_layout_map.get(s).?.size) {
            .fixed => |f| f,
            .runtime => null,
        },
    };
}

const StructLayoutEntries = std.ArrayList(
    struct {
        name: []const u8,
        padding_before: u32,
        offset: u32,
    },
);

const StructLayout = struct {
    size: union(enum) {
        fixed: u32,
        runtime: struct { base: u32, array_stride: u32 },
    },
    alignment: u32,
    fields: StructLayoutEntries,
    padding_after: ?u32 = null,
};

const VarWithAttributes = struct {
    name: []const u8,
    type: DataType,
    location: ?u32,
};

const VertexInput = struct {
    name: []const u8,
    type: DataType,
    location: u32,
};

const ShaderEntry = union(EntryTypes) {
    vertex: struct {
        name: []const u8,
        parameters: []const VertexInput,
    },
    fragment: struct {
        name: []const u8,
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
const StorageAccess = enum {
    write,
    read,
    read_write,

    pub fn getString(t: StorageAccess) []const u8 {
        return switch (t) {
            .write => ".write_only",
            .read => ".read_only",
            .read_write => ".read_write",
        };
    }
};

const TextureType = union(enum) {
    sampled_texture: struct { dim: SampledTextures, scalar: WGSLTextureScalar },
    depth_texture: DepthTextures,
    storage_texture: struct { dim: StorageTextures, format: TextureFormat, access: StorageAccess },
    external_texture,
};

const BindingResource = union(enum) {
    uniform_buffer: struct { type: DataType },
    storage_buffer: struct { type: DataType, access: enum { read, read_write } },
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
    const count = c.ts_node_named_child_count(node);
    for (0..count) |i| {
        const child = c.ts_node_named_child(node, @intCast(i));
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

pub fn getBindingResource(arena: std.mem.Allocator, src: []const u8, var_decl: c.TSNode) !?BindingResource {
    const var_type_token = findDescendant(var_decl, "type_specifier").?;
    const elab = findChild(var_type_token, "template_elaborated_ident").?;
    if (findChild(var_decl, "template_list")) |addr_space| {
        const var_type = (try parseWGSLDataType(arena, src, elab)).?;
        const args = findChild(addr_space, "template_arg_comma_list").?;
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
        const ident_node = findChild(elab, "ident").?;
        const token = findChild(ident_node, "ident_pattern_token").?;
        const base_name = nodeText(src, token);
        if (std.mem.startsWith(u8, base_name, "texture_")) {
            if (std.meta.stringToEnum(SampledTextures, base_name)) |tex_dim| {
                if (findChild((elab), "template_list")) |tmpl| {
                    const inner = findDescendant(tmpl, "ident_pattern_token").?;
                    const scalar = std.meta.stringToEnum(WGSLTextureScalar, nodeText(src, inner)).?;
                    return .{
                        .texture = .{
                            .sampled_texture = .{
                                .dim = tex_dim,
                                .scalar = scalar,
                            },
                        },
                    };
                }
            } else if (std.meta.stringToEnum(DepthTextures, base_name)) |depth_tex| {
                return .{ .texture = .{ .depth_texture = depth_tex } };
            }

            return error.Todo;

            // TODO storage textures
        }

        if (std.mem.startsWith(u8, base_name, "sampler")) {
            const sampler_type = std.meta.stringToEnum(SamplerType, base_name).?;
            return .{ .sampler = sampler_type };
        }

        return error.SomethingIsNotRight;
    }
}

pub fn getBindingDeclerations(arena: std.mem.Allocator, src: []const u8, root: c.TSNode, cursor: ?*c.TSQueryCursor) !std.ArrayList(Binding) {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var binding_declerations: std.ArrayList(Binding) = .empty;

    const query = c.ts_query_new(
        tree_sitter_wgsl(),
        global_var_decl_query,
        global_var_decl_query.len,
        &error_offset,
        @ptrCast(&error_type),
    );
    defer c.ts_query_delete(query);

    if (query == null) {
        std.debug.print("error at: {s}\n", .{global_var_decl_query[error_offset..]});
        return error.BadQuery;
    }

    c.ts_query_cursor_exec(cursor, query, root);
    var match: c.TSQueryMatch = undefined;

    while (c.ts_query_cursor_next_match(cursor, &match)) {
        for (match.captures[0..match.capture_count]) |cap| {
            const group = try getGroup(src, cap.node) orelse continue;
            const binding = try getBinding(src, cap.node) orelse continue;
            const opt_token = findDescendant(cap.node, "optionally_typed_ident").?;
            const name_token = findDescendant(opt_token, "ident_pattern_token").?;
            const name = nodeText(src, name_token);
            const var_decl = findChild(cap.node, "variable_decl").?;
            const resource = (try getBindingResource(arena, src, var_decl)).?;
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

fn parseWGSLDataType(arena: std.mem.Allocator, src: []const u8, type_node: c.TSNode) !?DataType {
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

        if (findChild(type_node, "template_list")) |tmpl| {
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

    // array
    if (std.mem.startsWith(u8, base_name, "array")) {
        const template_list = findDescendant(type_node, "template_arg_comma_list") orelse return null;
        const par_count = c.ts_node_named_child_count(template_list);
        const elem_type_node = c.ts_node_named_child(template_list, 0);
        const type_inner = findDescendant(elem_type_node, "template_elaborated_ident") orelse return null;
        const child_type: *DataType = try arena.create(DataType);
        child_type.* = (try parseWGSLDataType(arena, src, type_inner)).?;

        var max_size: ?u32 = null;

        if (par_count == 2) {
            const elem_count_node = c.ts_node_named_child(template_list, 1);
            const count_inner = findDescendant(elem_count_node, "decimal_int_literal") orelse return null;
            max_size = try std.fmt.parseInt(u32, nodeText(src, count_inner), 0);
        }

        return .{
            .array = .{
                .type = child_type,
                .max_size = max_size,
            },
        };
    }

    // unknown type
    return .{ .struct_ref = base_name };
}

pub fn captureNameFromId(query: ?*c.TSQuery, index: u32) []const u8 {
    var length: u32 = 0;
    const name_ptr = c.ts_query_capture_name_for_id(query, index, &length);
    return name_ptr[0..length];
}

pub fn capture(match: c.TSQueryMatch, query: ?*c.TSQuery, name: []const u8) ?c.TSNode {
    for (match.captures[0..match.capture_count]) |cap| {
        if (std.mem.eql(u8, captureNameFromId(query, cap.index), name)) {
            return cap.node;
        }
    }
    return null;
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

const StructMap = std.StringHashMapUnmanaged(std.ArrayList(VarWithAttributes));
const StructLayoutMap = std.StringHashMapUnmanaged(StructLayout);

pub fn getStructDeclerations(
    arena: std.mem.Allocator,
    src: []const u8,
    root: c.TSNode,
    cursor: ?*c.TSQueryCursor,
) !StructMap {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var struct_declerations: StructMap = .empty;

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
            var fields: std.ArrayList(VarWithAttributes) = .empty;
            const body_node = findChild(cap.node, "struct_body_decl") orelse continue;
            const field_count = c.ts_node_named_child_count(body_node);
            for (0..field_count) |i| {
                const field_token = c.ts_node_named_child(body_node, @intCast(i));
                const field_location = try getLocation(src, field_token);
                const ident_token = findChild(field_token, "member_ident") orelse continue;
                const field_name = nodeText(src, ident_token);
                const elab_token = findDescendant(field_token, "template_elaborated_ident") orelse continue;
                const field_type = try parseWGSLDataType(arena, src, elab_token) orelse continue;
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

pub fn getVertexInputFromStruct(
    arena: std.mem.Allocator,
    struct_map: StructMap,
    struct_name: []const u8,
    params: *std.ArrayList(VertexInput),
) !void {
    const struct_fields = struct_map.get(struct_name).?;
    for (struct_fields.items) |field| {
        if (field.location) |loc| {
            try params.append(arena, .{
                .name = field.name,
                .type = field.type,
                .location = loc,
            });
        } else if (field.type == .struct_ref) {
            try getVertexInputFromStruct(
                arena,
                struct_map,
                field.type.struct_ref,
                params,
            );
        }
    }
}

pub fn getEntryFunctions(
    arena: std.mem.Allocator,
    src: []const u8,
    root: c.TSNode,
    cursor: ?*c.TSQueryCursor,
    struct_map: StructMap,
) !std.ArrayList(ShaderEntry) {
    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    var entry_functions: std.ArrayList(ShaderEntry) = .empty;

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
                    var params: std.ArrayList(VertexInput) = .empty;

                    const name_capture = capture(match, query, "fn_name").?;
                    name = nodeText(src, name_capture);
                    const params_capture = capture(match, query, "params").?;
                    const param_count = c.ts_node_named_child_count(params_capture);
                    for (0..param_count) |i| {
                        const param = c.ts_node_named_child(params_capture, @intCast(i));
                        const ident = findChild(param, "ident").?;
                        const token = findChild(ident, "ident_pattern_token").?;
                        const type_sp = findChild(param, "type_specifier").?;
                        const type_tok = findChild(type_sp, "template_elaborated_ident").?;
                        const ty = (try parseWGSLDataType(arena, src, type_tok)).?;

                        const location = try getLocation(src, param);

                        if (location) |loc| {
                            try params.append(arena, .{
                                .name = nodeText(src, token),
                                .type = ty,
                                .location = loc,
                            });
                        } else if (ty == .struct_ref) {
                            try getVertexInputFromStruct(arena, struct_map, ty.struct_ref, &params);
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
                    const name_node = capture(match, query, "fn_name").?;
                    const name = nodeText(src, name_node);

                    try entry_functions.append(arena, .{
                        .fragment = .{ .name = name },
                    });
                }
            },
            .compute => {
                while (c.ts_query_cursor_next_match(cursor, &match)) {
                    const name_node = capture(match, query, "fn_name").?;
                    const name = nodeText(src, name_node);

                    try entry_functions.append(arena, .{
                        .compute = .{ .name = name },
                    });
                }
            },
        }
    }

    return entry_functions;
}

pub fn getStructProperties(
    arena: std.mem.Allocator,
    struct_ref: []const u8,
    space: AddressSpace,
    struct_map: StructMap,
    struct_layout_map: *StructLayoutMap,
) error{OutOfMemory}!StructLayout {
    if (struct_layout_map.get(struct_ref)) |layout| return layout;

    const struct_fields = struct_map.get(struct_ref).?;
    var struct_layout_entries: StructLayoutEntries = .empty;
    var offset: u32 = 0;
    var max_alignment: u32 = 0;
    for (struct_fields.items) |field| {
        switch (field.type) {
            .struct_ref => |ref| {
                const l = try getStructProperties(arena, ref, space, struct_map, struct_layout_map);
                try struct_layout_map.put(arena, ref, l);
            },
            .array => |arr| {
                var inner_type: DataType = arr.type.*;
                while (inner_type == .array) {
                    inner_type = inner_type.array.type.*;
                }
                if (inner_type == .struct_ref) {
                    const l = try getStructProperties(arena, arr.type.struct_ref, space, struct_map, struct_layout_map);
                    try struct_layout_map.put(arena, arr.type.struct_ref, l);
                }
            },
            else => {},
        }
        const alignment = alignOf(field.type, space, struct_layout_map.*).?;
        max_alignment = @max(max_alignment, alignment);
        const address: u32 = @intCast(std.mem.alignForward(usize, offset, alignment));
        const padding = address - offset;
        if (field.type == .array and field.type.array.max_size == null) {
            const base = address;
            const array_stride = @max(
                sizeOf(field.type.array.type.*, space, struct_layout_map.*).?,
                alignment,
            );
            try struct_layout_entries.append(arena, .{
                .offset = address,
                .padding_before = padding,
                .name = field.name,
            });
            return .{
                .alignment = max_alignment,
                .size = .{
                    .runtime = .{ .base = base, .array_stride = array_stride },
                },
                .fields = struct_layout_entries,
            };
        }
        try struct_layout_entries.append(arena, .{
            .offset = address,
            .padding_before = padding,
            .name = field.name,
        });
        offset = address + sizeOf(field.type, space, struct_layout_map.*).?;
    }
    const size: u32 = @intCast(std.mem.alignForward(usize, offset, max_alignment));
    const last_field_layout = struct_layout_entries.items[struct_layout_entries.items.len - 1];
    const last_field_decl = struct_fields.items[struct_fields.items.len - 1];
    const padding_after = size - (last_field_layout.offset + sizeOf(last_field_decl.type, space, struct_layout_map.*).?);
    return .{
        .alignment = max_alignment,
        .size = .{ .fixed = size },
        .fields = struct_layout_entries,
        .padding_after = padding_after,
    };
}

pub fn sortByGroup(_: void, a: Binding, b: Binding) bool {
    return a.group < b.group;
}

pub fn printStructCode(
    allocator: std.mem.Allocator,
    ref: []const u8,
    struct_map: StructMap,
    struct_layout_map: StructLayoutMap,
    w: *std.Io.Writer,
) !void {
    const struct_definition = struct_map.get(ref).?;
    const struct_layout = struct_layout_map.get(ref).?;
    for (struct_definition.items) |field| {
        switch (field.type) {
            .struct_ref => |in_ref| try printStructCode(allocator, in_ref, struct_map, struct_layout_map, w),
            .array => |arr| {
                var inner_type: DataType = arr.type.*;
                while (inner_type == .array) {
                    inner_type = inner_type.array.type.*;
                }
                if (inner_type == .struct_ref) {
                    try printStructCode(allocator, inner_type.struct_ref, struct_map, struct_layout_map, w);
                }
            },
            else => {},
        }
    }
    try w.print(
        "pub const {s} = extern struct {{\n",
        .{ref},
    );
    var padding_count: usize = 0;
    var runtime_sized_array: ?[]const u8 = null;
    for (struct_layout.fields.items, 0..) |field, i| {
        const field_def = struct_definition.items[i];
        if (field.padding_before > 0) {
            try w.print("pad_{}: [{any}]u8 = @splat(0),\n", .{ padding_count, field.padding_before });
            padding_count += 1;
        }
        if (field_def.type == .array and field_def.type.array.max_size == null) {
            runtime_sized_array = field.name;
            continue;
        }
        try w.print(
            "{s}: {s},\n",
            .{ field.name, try field_def.type.getString(allocator) },
        );
    }
    if (struct_layout.padding_after) |p| {
        if (p > 0) {
            try w.print("pad_{}: [{any}]u8 = @splat(0),\n", .{ padding_count, p });
        }
    }
    if (runtime_sized_array) |name| {
        const upper_name =
            try std.ascii.allocUpperString(allocator, name);
        try w.print(
            "\npub const {s}_STRIDE: u32 = {any};\npub const {s}_OFFSET: u32 = {any};\n",
            .{
                upper_name,
                struct_layout.size.runtime.array_stride,
                upper_name,
                struct_layout.size.runtime.base,
            },
        );
    }
    try w.print("}};\n\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    // TODO: command line parameter inputs
    // TODO: try with real shaders

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(allocator);
    if (args.len != 2) return error.WrongArgumentCount;
    const path = args[1];
    const file_name = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, file_name, ".wgsl")) {
        return error.WrongFileType;
    }
    const file_no_ext = file_name[0 .. file_name.len - 5];

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "src/shaders/compiled");

    const parser = c.ts_parser_new();
    defer c.ts_parser_delete(parser);

    _ = c.ts_parser_set_language(parser, tree_sitter_wgsl());
    const src = try cwd.readFileAlloc(
        io,
        path,
        allocator,
        .unlimited,
    );
    const tree = c.ts_parser_parse_string(parser, null, @ptrCast(src), @intCast(src.len));

    const root = c.ts_tree_root_node(tree);

    const cursor = c.ts_query_cursor_new();
    defer c.ts_query_cursor_delete(cursor);

    std.debug.print("=== STRUCT DECLERATIONS ===\n", .{});
    const struct_map = try getStructDeclerations(allocator, src, root, cursor);
    var iter = struct_map.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{s}\n", .{entry.key_ptr.*});
        for (entry.value_ptr.items) |field| {
            std.debug.print("{f}\n", .{std.json.fmt(field, .{})});
        }
    }

    std.debug.print("=== ENTRY FUNCTIONS ===\n", .{});
    const entries = try getEntryFunctions(allocator, src, root, cursor, struct_map);
    for (entries.items) |e| {
        std.debug.print("{f}\n", .{std.json.fmt(e, .{})});
    }

    std.debug.print("=== BINDINGS ===\n", .{});
    const bindings = try getBindingDeclerations(allocator, src, root, cursor);
    for (bindings.items) |e| {
        std.debug.print("{f}\n", .{std.json.fmt(e, .{})});
    }

    var struct_layout_map: StructLayoutMap = .empty;
    std.debug.print("=== STRUCT LAYOUTS ===\n", .{});
    for (bindings.items) |b| {
        const buf_type = switch (b.resource) {
            .uniform_buffer => |ub| ub.type,
            .storage_buffer => |ub| ub.type,
            else => continue,
        };
        if (buf_type != .struct_ref) continue;
        const space: AddressSpace = switch (b.resource) {
            .uniform_buffer => .uniform,
            .storage_buffer => .storage,
            else => continue,
        };
        const ref = buf_type.struct_ref;
        const layout = try getStructProperties(
            allocator,
            ref,
            space,
            struct_map,
            &struct_layout_map,
        );
        try struct_layout_map.put(allocator, ref, layout);
    }

    std.mem.sort(Binding, bindings.items, {}, sortByGroup);

    const visibility: []const u8 = blk: {
        for (entries.items) |i| {
            if (i == .compute) break :blk "gpu.ShaderStage.compute";
        }
        break :blk "gpu.ShaderStage.vertex | gpu.ShaderStage.fragment";
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    const w = &aw.writer;
    try w.print("const gpu = @import(\"../../gpu.zig\");\n\n", .{});

    for (entries.items) |item| {
        const name = switch (item) {
            inline else => |x| x.name,
        };
        const upper_name = try std.ascii.allocUpperString(allocator, name);
        try w.print("pub const {s}: []const u8 = \"{s}\";\n", .{ upper_name, name });
    }
    try w.print("\n", .{});

    for (bindings.items) |binding| {
        const resource = binding.resource;
        if (resource == .uniform_buffer or resource == .storage_buffer) {
            const bind_type = if (resource == .uniform_buffer) resource.uniform_buffer.type else resource.storage_buffer.type;
            switch (bind_type) {
                .struct_ref => |ref| {
                    try printStructCode(allocator, ref, struct_map, struct_layout_map, w);
                },
                .array => |arr| {
                    if (arr.max_size == null) {
                        const array_stride = @max(
                            alignOf(arr.type.*, .storage, struct_layout_map).?,
                            sizeOf(arr.type.*, .storage, struct_layout_map).?,
                        );
                        try w.print(
                            "pub const {s}_STRIDE: u32 = {any};\n\n",
                            .{
                                try std.ascii.allocUpperString(allocator, binding.name),
                                array_stride,
                            },
                        );
                    }
                },
                else => {},
            }
        }
    }

    if (bindings.items.len > 0) {
        try w.print(
            \\ pub const layouts: ?[]const []const gpu.BindGroupLayoutEntry = &.{{
            \\ &.{{
        , .{});

        var group: usize = 0;
        for (bindings.items) |binding| {
            if (binding.group != group) {
                try w.print("}},\n", .{});
                try w.print("&.{{", .{});
                group = binding.group;
            }
            try w.print(
                ".{{ .binding = {any}, .visibility = {s}, .type = ",
                .{ binding.binding, visibility },
            );
            switch (binding.resource) {
                .uniform_buffer => |ub| switch (ub.type) {
                    .struct_ref => |ref| try w.print(
                        ".{{ .buffer = .{{.type = .uniform, .has_dynamic_offset = false, .min_binding_size = {any} }} }} }},",
                        .{
                            struct_layout_map.get(ref).?.size.fixed,
                        },
                    ),
                    else => try w.print(".{{ .buffer = .{{.type = .uniform, .has_dynamic_offset = false, .min_binding_size = 0 }} }} }},", .{}),
                },
                .storage_buffer => |sb| switch (sb.type) {
                    .struct_ref => |ref| switch (struct_layout_map.get(ref).?.size) {
                        .fixed => |f| try w.print(
                            ".{{ .buffer = .{{ .type = {s}, .has_dynamic_offset = false, .min_binding_size = {any} }} }} }},",
                            .{ if (sb.access == .read_write) ".storage" else ".read_only_storage", f },
                        ),
                        .runtime => try w.print(
                            ".{{ .buffer = .{{ .type = {s}, .has_dynamic_offset = false, .min_binding_size = 0 }} }} }},",
                            .{if (sb.access == .read_write) ".storage" else ".read_only_storage"},
                        ),
                    },
                    else => try w.print(".{{ .buffer = .{{ .type = {s}, .has_dynamic_offset = false, .min_binding_size = {any} }} }} }},", .{
                        if (sb.access == .read) ".read_only_storage" else ".storage",
                        if (sizeOf(sb.type, .storage, struct_layout_map)) |size| size else 0,
                    }),
                },
                .sampler => |smp| {
                    const smp_type = if (smp == .sampler) ".filtering" else ".sampler_comparison";
                    try w.print(".{{ .sampler = {s} }} }},", .{smp_type});
                },
                .texture => |tex| switch (tex) {
                    .sampled_texture => |smp| {
                        try w.print(
                            ".{{ .texture = .{{ .sample_type = {s}, .view_dimension = {s}, .multi_sampled = {any}  }} }} }},",
                            .{ smp.scalar.getSampleString(), smp.dim.getString(), smp.dim == .texture_multisampled_2d },
                        );
                    },
                    .depth_texture => |depth| {
                        try w.print(
                            ".{{ .texture = .{{ .sample_type = {s}, .view_dimension = .depth, .multi_sampled = {any}  }} }} }},",
                            .{ depth.getString(), depth == .texture_depth_multisampled_2d },
                        );
                    },
                    .storage_texture => |strg| {
                        try w.print(
                            ".{{ .storage_texture = .{{ .view_dimension = {s}, .access = {s}, .format = .{s}  }} }} }},",
                            .{
                                strg.dim.getString(),
                                strg.access.getString(),
                                std.enums.tagName(TextureFormat, strg.format).?,
                            },
                        );
                    },
                    .external_texture => {},
                },
            }
        }
        try w.print("}}, }};\n\n", .{});
    } else {
        try w.print("pub const layouts: ?[]const []const gpu.BindGroupLayoutEntry = null;\n\n", .{});
    }

    if (bindings.items.len > 0) {
        try w.print("pub const Uniforms: ?[]const type = &.{{\n", .{});
        var group: usize = 0;
        var found_uniform = false;
        for (bindings.items) |binding| {
            if (binding.group != group) {
                if (found_uniform) {
                    try w.print("}},\n", .{});
                } else {
                    try w.print("void,\n", .{});
                }
                found_uniform = false;
                group = binding.group;
            }
            if (binding.resource != .uniform_buffer) continue;
            if (!found_uniform) {
                try w.print("struct {{\n", .{});
                found_uniform = true;
            }
            const type_string = try binding.resource.uniform_buffer.type.getString(allocator);
            try w.print("{s}: {s},\n", .{ binding.name, type_string });
        }
        if (!found_uniform) {
            try w.print("void,\n", .{});
        }

        try w.print("}};\n\n", .{});
    } else {
        try w.print("pub const Uniforms: ?[]const type = null;\n\n", .{});
    }

    const write_path = try std.fmt.allocPrint(allocator, "src/shaders/compiled/{s}.zig", .{file_no_ext});

    try cwd.writeFile(io, .{
        .sub_path = write_path,
        .data = aw.written(),
    });
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
};
