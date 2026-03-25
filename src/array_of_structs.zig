const std = @import("std");

pub fn Init(ShapeStruct: type) type {
    const type_info = @typeInfo(ShapeStruct);
    if (type_info != .@"struct") @compileError("Must be struct");
    const struct_info = type_info.@"struct";
    if (struct_info.fields.len == 0) @compileError("Empty struct");

    comptime var enum_fields: [struct_info.fields.len]std.builtin.Type.EnumField = undefined;
    comptime var fields: [struct_info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (struct_info.fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };
        fields[i] = .{
            .name = field.name,
            .type = std.ArrayList(field.type),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(std.ArrayList(field.type)),
        };
    }

    const new_struct: std.builtin.Type.Struct = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    };
    const NewStruct = @Type(.{ .@"struct" = new_struct });

    const fields_enum: std.builtin.Type.Enum = .{
        .fields = &enum_fields,
        .decls = &.{},
        .is_exhaustive = false,
        .tag_type = usize,
    };
    const FieldsEnum = @Type(.{ .@"enum" = fields_enum });

    return struct {
        data: NewStruct,

        pub fn init() @This() {
            var data: NewStruct = undefined;
            inline for (fields) |field| {
                @field(&data, field.name) = .empty;
            }
            return .{
                .data = data,
            };
        }

        pub fn append(self: *@This(), allocator: std.mem.Allocator, item: ShapeStruct) !void {
            inline for (fields) |field| {
                try @field(&self.data, field.name).append(allocator, @field(item, field.name));
            }
        }

        pub fn get(self: @This(), id: usize, comptime field: FieldsEnum) struct_info.fields[@intFromEnum(field)].type {
            return @field(&self.data, fields[@intFromEnum(field)].name).items[id];
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (fields) |field| {
                @field(&self.data, field.name).deinit(allocator);
            }
        }
    };
}

test "bruh" {
    const allocator = std.testing.allocator;

    const SOA = Init(struct { value: u32 });

    var soa = SOA.init();
    defer soa.deinit(allocator);

    try soa.append(allocator, .{ .value = 10 });
    try std.testing.expect(soa.get(0, .value) == 10);
}
