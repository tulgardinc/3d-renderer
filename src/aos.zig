const std = @import("std");

pub fn Init(ShapeStruct: type) type {
    const type_info = @typeInfo(ShapeStruct);
    if (type_info != .@"struct") @compileError("Must be struct");
    const struct_info = type_info.@"struct";

    const field_names, const e_vals, const s_types, const r_types = comptime blk: {
        var field_names: [struct_info.fields.len][]const u8 = undefined;
        var e_vals: [struct_info.fields.len]usize = undefined;
        var s_types: [struct_info.fields.len]type = undefined;
        var r_types: [struct_info.fields.len]type = undefined;
        for (struct_info.fields, 0..) |field, i| {
            field_names[i] = field.name;
            s_types[i] = std.ArrayList(field.type);
            e_vals[i] = i;
            r_types[i] = *field.type;
        }
        break :blk .{ field_names, e_vals, s_types, r_types };
    };

    const Attributes = std.builtin.Type.StructField.Attributes;

    const SoAStruct = @Struct(
        .auto,
        null,
        &field_names,
        &s_types,
        &([_]Attributes{.{}} ** field_names.len),
    );

    const FieldsEnum = @Enum(
        usize,
        .exhaustive,
        &field_names,
        &e_vals,
    );

    const RowStruct = @Struct(
        .auto,
        null,
        &field_names,
        &r_types,
        &([_]Attributes{.{}} ** field_names.len),
    );

    return struct {
        data: SoAStruct,

        pub fn init() @This() {
            var data: SoAStruct = undefined;
            inline for (field_names) |name| {
                @field(&data, name) = .empty;
            }
            return .{
                .data = data,
            };
        }

        pub fn append(self: *@This(), allocator: std.mem.Allocator, item: ShapeStruct) !void {
            inline for (field_names) |name| {
                try @field(&self.data, name).append(allocator, @field(item, name));
            }
        }

        pub fn row(self: *@This(), id: usize) RowStruct {
            var s_row: RowStruct = undefined;
            inline for (field_names) |name| {
                @field(s_row, name) = &(@field(self.data, name).items[id]);
            }
            return s_row;
        }

        pub fn col(self: @This(), comptime field: FieldsEnum) []struct_info.fields[@intFromEnum(field)].type {
            return @field(&self.data, field_names[@intFromEnum(field)]).items;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (field_names) |name| {
                @field(&self.data, name).deinit(allocator);
            }
        }
    };
}

test "row" {
    const allocator = std.testing.allocator;

    const SOA = Init(struct { value: u32, string: []const u8 });

    var soa = SOA.init();
    defer soa.deinit(allocator);

    try soa.append(allocator, .{ .value = 10, .string = "test" });
    try soa.append(allocator, .{ .value = 20, .string = "test2" });
    try soa.append(allocator, .{ .value = 30, .string = "test3" });
    const row0 = soa.row(0);
    const row1 = soa.row(1);
    const row2 = soa.row(2);
    try std.testing.expect(row0.value.* == 10);
    try std.testing.expect(row1.value.* == 20);
    try std.testing.expect(row2.value.* == 30);
    try std.testing.expect(std.mem.eql(u8, row0.string.*, "test"));
    try std.testing.expect(std.mem.eql(u8, row1.string.*, "test2"));
    try std.testing.expect(std.mem.eql(u8, row2.string.*, "test3"));
}

test "column" {
    const allocator = std.testing.allocator;

    const SOA = Init(struct { value: u32, string: []const u8 });

    var soa = SOA.init();
    defer soa.deinit(allocator);

    try soa.append(allocator, .{ .value = 10, .string = "test" });
    try soa.append(allocator, .{ .value = 20, .string = "test2" });
    try soa.append(allocator, .{ .value = 30, .string = "test3" });
    const vals = soa.col(.value);
    const strings = soa.col(.string);
    try std.testing.expect(vals[0] == 10);
    try std.testing.expect(vals[1] == 20);
    try std.testing.expect(vals[2] == 30);
    try std.testing.expect(std.mem.eql(u8, strings[0], "test"));
    try std.testing.expect(std.mem.eql(u8, strings[1], "test2"));
    try std.testing.expect(std.mem.eql(u8, strings[2], "test3"));
}
