const std = @import("std");
const build_options = @import("build_options");

pub const ShaderReflectionJSON = struct {
    entry_points: []const EntryPointEntry,

    pub const EntryPointEntry = struct {
        name: []const u8,
        stage: []const u8,
        input_variables: []const InputVariableEntry,
        bindings: []const BindingEntry,
    };

    pub const InputVariableEntry = struct {
        name: []const u8,
        location: usize,
        component_type: []const u8,
        composition_type: []const u8,
    };

    pub const BindingEntry = struct {
        binding: usize,
        group: usize,
        size: usize,
        resource_type: []const u8,

        // Todo support smapler and Texture

    };
};

pub fn parseShader(allocator: std.mem.Allocator, source_path: []const u8) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var child = std.process.Child.init(&.{ build_options.tint_path, source_path, "--json" }, allocator);
    child.stdout_behavior = .Pipe;
    _ = try child.spawn();

    var stream: [512]u8 = undefined;
    var json_buffer: [4096]u8 = undefined;

    var reader = child.stdout.?.readerStreaming(&stream);
    const read_bytes = try reader.interface.readSliceShort(&json_buffer);

    _ = try child.wait();

    const reflection_json: std.json.Parsed(ShaderReflectionJSON) = try std.json.parseFromSlice(
        ShaderReflectionJSON,
        allocator,
        json_buffer[0..read_bytes],
        .{ .ignore_unknown_fields = true },
    );
    defer reflection_json.deinit();

    var metadata: Metadata = .{ .arena_allocator = arena_allocator };

    var bind_groups: [MAX_BIND_GROUP_COUNT]?std.ArrayListUnmanaged(gpu.BindGroupLayoutEntry) = .{null} ** MAX_BIND_GROUP_COUNT;
    var max_bind_group_index: ?usize = null;

    for (reflection_json.value.entry_points) |ep| {
        if (ep.bindings.len > 0) {
            for (ep.bindings) |be| {
                max_bind_group_index = @max(be.group, max_bind_group_index orelse 0);
                var list_p = blk: {
                    if (bind_groups[be.group]) |*ls| {
                        break :blk ls;
                    } else {
                        bind_groups[be.group] = try .initCapacity(arena, 4);
                        break :blk &bind_groups[be.group].?;
                    }
                };
                for (bind_groups[be.group].?.items) |tbe| {
                    if (tbe.binding == be.binding) continue;
                }
                try list_p.append(
                    arena,
                    .{
                        .binding = @intCast(be.binding),
                        .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment,
                        .type = try getBindingType(be.resource_type),
                    },
                );
            }
        }

        if (std.mem.eql(u8, ep.stage, "vertex")) {
            const name = try arena.alloc(u8, ep.name.len);
            @memcpy(name, ep.name);
            metadata.vertex_entry = name;

            if (ep.input_variables.len > 0) {
                var vertex_inputs = try arena.alloc(gpu.VertexInput, ep.input_variables.len);
                for (ep.input_variables, 0..) |iv, i| {
                    vertex_inputs[i] = .{
                        .location = @intCast(iv.location),
                        .format = gpu.VertexFormat.getFormComponents(
                            iv.component_type,
                            iv.composition_type,
                        ),
                    };
                }
                metadata.vertex_inputs = vertex_inputs;
            }
        } else if (std.mem.eql(u8, ep.stage, "fragment")) {
            const name = try arena.alloc(u8, ep.name.len);
            @memcpy(name, ep.name);
            metadata.fragment_entry = name;
        } else {
            return error.FragmentAndVertexOnly;
        }
    }

    if (max_bind_group_index) |mbi| {
        const bind_group_count = mbi + 1;
        var bgs = try arena.alloc([]const gpu.BindGroupLayoutEntry, bind_group_count);
        for (0..bind_group_count) |i| {
            bgs[i] = try bind_groups[i].?.toOwnedSlice(arena);
        }

        metadata.bind_group_layouts = bgs;
    }

    return metadata;
}

pub fn compileShader() !void {}
