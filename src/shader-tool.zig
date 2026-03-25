const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_wgsl() *const c.TSLanguage;

const entry_query =
    \\(function_decl 
    \\  (attribute [(vertex_attr)(fragment_attr)]) 
    \\  (function_header 
    \\    (ident (ident_pattern_token) @fn_name)
    \\    (param_list (param (ident (ident_pattern_token) @par_name) (type_specifier) @type_name))))
;

// \\    (param_list (param (ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern_token))))))
// \\    (template_elaborated_ident (ident (ident_pattern_token))))

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

pub fn main() !void {
    const parser = c.ts_parser_new();
    _ = c.ts_parser_set_language(parser, tree_sitter_wgsl());
    // const src = @embedFile("./shaders/2DVertexColors.wgsl");
    const src = "@vertex fn vs(test1: u32, test2: f32) -> VertexOutput {}\n@fragment fn fs(test3: vec2<u32>, test4: vec4<f32>) -> FragmentOutput {}";
    const tree = c.ts_parser_parse_string(parser, null, src, src.len);

    const root = c.ts_tree_root_node(tree);

    // const str = c.ts_node_string(root);
    // std.debug.print("{s}\n", .{str});

    var error_offset: u32 = 0;
    var error_type = c.TSQueryErrorNone;

    const query = c.ts_query_new(
        tree_sitter_wgsl(),
        entry_query,
        entry_query.len,
        &error_offset,
        @ptrCast(&error_type),
    );

    if (query == null) {
        std.debug.print("error at: {s}\n", .{entry_query[error_offset..]});
        return error.Error;
    }

    const cursor = c.ts_query_cursor_new();

    c.ts_query_cursor_exec(cursor, query, root);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        const captures = match.captures[0..match.capture_count];
        for (captures) |cap| {
            const start = c.ts_node_start_byte(cap.node);
            const end = c.ts_node_end_byte(cap.node);
            std.debug.print("{}: {s}\n", .{ match.id, src[start..end] });
        }
    }
}

// (translation_unit (struct_decl (ident (ident_pattern_token)) (struct_body_decl (struct_member (attribute (loc
// ation_attr (expression (relational_expression (shift_expression (additive_expression (multiplicative_expressi
// on (unary_expression (singular_expression (primary_expression (literal (int_literal (decimal_int_literal)))))
// )))))))) (member_ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_patter
// n_token)) (template_list (template_arg_comma_list (template_arg_expression (expression (relational_expression
//  (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_expression (pr
// imary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))))) (struct_member (attr
// ibute (location_attr (expression (relational_expression (shift_expression (additive_expression (multiplicativ
// e_expression (unary_expression (singular_expression (primary_expression (literal (int_literal (decimal_int_li
// teral))))))))))))) (member_ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (id
// ent_pattern_token)) (template_list (template_arg_comma_list (template_arg_expression (expression (relational_
// expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_expr
// ession (primary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))))))) (struct_
// decl (ident (ident_pattern_token)) (struct_body_decl (struct_member (attribute (builtin_attr (builtin_value_n
// ame (ident_pattern_token)))) (member_ident (ident_pattern_token)) (type_specifier (template_elaborated_ident
// (ident (ident_pattern_token)) (template_list (template_arg_comma_list (template_arg_expression (expression (r
// elational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (sin
// gular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token)))))))))))))))))
// (struct_member (attribute (location_attr (expression (relational_expression (shift_expression (additive_expre
// ssion (multiplicative_expression (unary_expression (singular_expression (primary_expression (literal (int_lit
// eral (decimal_int_literal))))))))))))) (member_ident (ident_pattern_token)) (type_specifier (template_elabora
// ted_ident (ident (ident_pattern_token)) (template_list (template_arg_comma_list (template_arg_expression (exp
// ression (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expre
// ssion (singular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))
// ))))))))))) (struct_decl (ident (ident_pattern_token)) (struct_body_decl (struct_member (member_ident (ident_
// pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern_token)))))))
// (global_variabl
// e_decl (attribute (group_attr (expression (relational_expression (shift_expression (additive_expression (mult
// iplicative_expression (unary_expression (singular_expression (primary_expression (literal (int_literal (decim
// al_int_literal))))))))))))) (attribute (binding_attr (expression (relational_expression (shift_expression (ad
// ditive_expression (multiplicative_expression (unary_expression (singular_expression (primary_expression (lite
// ral (int_literal (decimal_int_literal))))))))))))) (variable_decl (template_list (template_arg_comma_list (te
// mplate_arg_expression (expression (relational_expression (shift_expression (additive_expression (multiplicati
// ve_expression (unary_expression (singular_expression (primary_expression (template_elaborated_ident (ident (i
// dent_pattern_token)))))))))))))) (optionally_typed_ident (ident (ident_pattern_token)) (type_specifier (templ
// ate_elaborated_ident (ident (ident_pattern_token)))))))
// (function_decl (attribute (vertex_attr)) (function_header (ident (ident_pattern_token)) (param_list (param (ident (ident_pattern_token)) (type_specifier (template
// _elaborated_ident (ident (ident_pattern_token)))))) (template_elaborated_ident (ident (ident_pattern_token)))
// )
// (compound_statement (statement (variable_or_value_statement (variable_decl (optionally_typed_ident (ident (
// ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern_token)))))))) (stateme
// nt (variable_updating_statement (assignment_statement (lhs_expression (core_lhs_expression (ident (ident_patt
// ern_token))) (component_or_swizzle_specifier (member_ident (ident_pattern_token)))) (expression (relational_e
// xpression (shift_expression (additive_expression (multiplicative_expression (unary_expression (singular_expre
// ssion (primary_expression (call_expression (call_phrase (template_elaborated_ident (ident (ident_pattern_toke
// n)) (template_list (template_arg_comma_list (template_arg_expression (expression (relational_expression (shif
// t_expression (additive_expression (multiplicative_expression (unary_expression (singular_expression (primary_
// expression (template_elaborated_ident (ident (ident_pattern_token))))))))))))))) (argument_expression_list (e
// xpression_comma_list (expression (relational_expression (shift_expression (additive_expression (multiplicativ
// e_expression (unary_expression (singular_expression (primary_expression (template_elaborated_ident (ident (id
// ent_pattern_token)))) (component_or_swizzle_specifier (member_ident (ident_pattern_token)))))))))) (expressio
// n (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression
// (singular_expression (primary_expression (literal (float_literal (decimal_float_literal))))))))))) (expressio
// n (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression
// (singular_expression (primary_expression (literal (float_literal (decimal_float_literal))))))))))))))))))))))
// )))) (statement (variable_updating_statement (assignment_statement (lhs_expression (core_lhs_expression (iden
// t (ident_pattern_token))) (component_or_swizzle_specifier (member_ident (ident_pattern_token)))) (expression
// (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (s
// ingular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token)))) (component_
// or_swizzle_specifier (member_ident (ident_pattern_token))))))))))))) (statement (return_statement (expression
//  (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_expression (
// singular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token)))))))))))))))
//  (function_decl (attribute (fragment_attr)) (function_header (ident (ident_pattern_token)) (param_list (param
//  (ident (ident_pattern_token)) (type_specifier (template_elaborated_ident (ident (ident_pattern_token)))))) (
// attribute (location_attr (expression (relational_expression (shift_expression (additive_expression (multiplic
// ative_expression (unary_expression (singular_expression (primary_expression (literal (int_literal (decimal_in
// t_literal))))))))))))) (template_elaborated_ident (ident (ident_pattern_token)) (template_list (template_arg_
// comma_list (template_arg_expression (expression (relational_expression (shift_expression (additive_expression
//  (multiplicative_expression (unary_expression (singular_expression (primary_expression (template_elaborated_i
// dent (ident (ident_pattern_token)))))))))))))))) (compound_statement (statement (variable_or_value_statement
// (optionally_typed_ident (ident (ident_pattern_token))) (expression (relational_expression (shift_expression (
// additive_expression (multiplicative_expression (multiplicative_expression (unary_expression (singular_express
// ion (primary_expression (paren_expression (expression (relational_expression (shift_expression (additive_expr
// ession (additive_expression (multiplicative_expression (unary_expression (singular_expression (primary_expres
// sion (call_expression (call_phrase (template_elaborated_ident (ident (ident_pattern_token))) (argument_expres
// sion_list (expression_comma_list (expression (relational_expression (shift_expression (additive_expression (m
// ultiplicative_expression (unary_expression (singular_expression (primary_expression (template_elaborated_iden
// t (ident (ident_pattern_token)))) (component_or_swizzle_specifier (member_ident (ident_pattern_token)))))))))
// )))))))))) (additive_operator) (multiplicative_expression (unary_expression (singular_expression (primary_exp
// ression (literal (float_literal (decimal_float_literal)))))))))))))))) (multiplicative_operator) (unary_expre
// ssion (singular_expression (primary_expression (literal (float_literal (decimal_float_literal))))))))))))) (s
// tatement (return_statement (expression (relational_expression (shift_expression (additive_expression (multipl
// icative_expression (unary_expression (singular_expression (primary_expression (call_expression (call_phrase (
// template_elaborated_ident (ident (ident_pattern_token)) (template_list (template_arg_comma_list (template_arg
// _expression (expression (relational_expression (shift_expression (additive_expression (multiplicative_express
// ion (unary_expression (singular_expression (primary_expression (template_elaborated_ident (ident (ident_patte
// rn_token))))))))))))))) (argument_expression_list (expression_comma_list (expression (relational_expression (
// shift_expression (additive_expression (multiplicative_expression (multiplicative_expression (unary_expression
//  (singular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token)))) (compone
// nt_or_swizzle_specifier (member_ident (ident_pattern_token)))))) (multiplicative_operator) (unary_expression
// (singular_expression (primary_expression (template_elaborated_ident (ident (ident_pattern_token))))))))))) (e
// xpression (relational_expression (shift_expression (additive_expression (multiplicative_expression (unary_exp
// ression (singular_expression (primary_expression (literal (float_literal (decimal_float_literal))))))))))))))
// ))))))))))))))
