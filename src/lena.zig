pub fn checkNumeric(T: type) void {
    switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("Not a numeric"),
    }
}

pub fn Vec2(T: type) type {
    checkNumeric(T);
    return extern struct {
        x: T,
        y: T,

        const Self = @This();
        const V = @Vector(2, T);

        fn toSimd(self: Self) V {
            return .{ self.x, self.y };
        }

        fn fromSimd(v: V) Self {
            return .{ .x = v[0], .y = v[1] };
        }

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        pub fn splat(s: T) Self {
            return fromSimd(@splat(s));
        }

        pub fn add(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() + b.toSimd());
        }

        pub fn sub(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() - b.toSimd());
        }

        pub fn mul(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() * b.toSimd());
        }

        pub fn div(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() / b.toSimd());
        }

        pub fn scale(a: Self, s: T) Self {
            return fromSimd(a.toSimd() * @as(V, @splat(s)));
        }

        pub fn dot(a: Self, b: Self) T {
            return @reduce(.Add, a.toSimd() * b.toSimd());
        }

        pub fn length(a: Self) T {
            return @sqrt(a.dot(a));
        }

        pub fn normalize(a: Self) Self {
            return a.scale(1.0 / a.length());
        }

        pub fn toArray(self: Self) [2]T {
            return @bitCast(self);
        }

        pub fn asArray(self: *Self) *[2]T {
            return @ptrCast(self);
        }
    };
}

pub fn Vec3(T: type) type {
    checkNumeric(T);
    return extern struct {
        x: T,
        y: T,
        z: T,

        const Self = @This();
        const V = @Vector(3, T);

        fn toSimd(self: Self) V {
            return .{ self.x, self.y, self.z };
        }

        fn fromSimd(v: V) Self {
            return .{ .x = v[0], .y = v[1], .z = v[2] };
        }

        pub fn init(x: T, y: T, z: T) Self {
            return .{ .x = x, .y = y, .z = z };
        }

        pub fn splat(s: T) Self {
            return fromSimd(@splat(s));
        }

        pub fn add(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() + b.toSimd());
        }

        pub fn sub(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() - b.toSimd());
        }

        pub fn mul(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() * b.toSimd());
        }

        pub fn div(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() / b.toSimd());
        }

        pub fn scale(a: Self, s: T) Self {
            return fromSimd(a.toSimd() * @as(V, @splat(s)));
        }

        pub fn dot(a: Self, b: Self) T {
            return @reduce(.Add, a.toSimd() * b.toSimd());
        }

        pub fn cross(a: Self, b: Self) Self {
            const va = a.toSimd();
            const vb = b.toSimd();
            const left = @shuffle(T, va, undefined, @Vector(3, i32){ 1, 2, 0 }) *
                @shuffle(T, vb, undefined, @Vector(3, i32){ 2, 0, 1 });
            const right = @shuffle(T, va, undefined, @Vector(3, i32){ 2, 0, 1 }) *
                @shuffle(T, vb, undefined, @Vector(3, i32){ 1, 2, 0 });
            return fromSimd(left - right);
        }

        pub fn length(a: Self) T {
            return @sqrt(a.dot(a));
        }

        pub fn normalize(a: Self) Self {
            return a.scale(1.0 / a.length());
        }

        pub fn toArray(self: Self) [3]T {
            return @bitCast(self);
        }

        pub fn asArray(self: *Self) *[3]T {
            return @ptrCast(self);
        }
    };
}

pub fn Vec4(T: type) type {
    checkNumeric(T);
    return extern struct {
        x: T,
        y: T,
        z: T,
        w: T,

        const Self = @This();
        const V = @Vector(4, T);

        fn toSimd(self: Self) V {
            return .{ self.x, self.y, self.z, self.w };
        }

        fn fromSimd(v: V) Self {
            return .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
        }

        pub fn init(x: T, y: T, z: T, w: T) Self {
            return .{ .x = x, .y = y, .z = z, .w = w };
        }

        pub fn splat(s: T) Self {
            return fromSimd(@splat(s));
        }

        pub fn add(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() + b.toSimd());
        }

        pub fn sub(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() - b.toSimd());
        }

        pub fn mul(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() * b.toSimd());
        }

        pub fn div(a: Self, b: Self) Self {
            return fromSimd(a.toSimd() / b.toSimd());
        }

        pub fn scale(a: Self, s: T) Self {
            return fromSimd(a.toSimd() * @as(V, @splat(s)));
        }

        pub fn dot(a: Self, b: Self) T {
            return @reduce(.Add, a.toSimd() * b.toSimd());
        }

        pub fn length(a: Self) T {
            return @sqrt(a.dot(a));
        }

        pub fn normalize(a: Self) Self {
            return a.scale(1.0 / a.length());
        }

        pub fn toArray(self: Self) [4]T {
            return @bitCast(self);
        }

        pub fn asArray(self: *Self) *[4]T {
            return @ptrCast(self);
        }
    };
}

/// Conventions: column-major storage (flat order matches
/// WGSL mat4x4), column vectors (transform = M * v, compose right-to-left),
/// right-handed view space with -z forward and +y up, clip depth [0, 1] (WebGPU).
pub fn Mat4x4(T: type) type {
    checkNumeric(T);
    return extern struct {
        cols: [4]Vec4(T),

        const Self = @This();

        pub fn ident() Self {
            return .{
                .cols = .{
                    .init(1, 0, 0, 0),
                    .init(0, 1, 0, 0),
                    .init(0, 0, 1, 0),
                    .init(0, 0, 0, 1),
                },
            };
        }

        pub fn mulVec(m: Self, v: Vec4(T)) Vec4(T) {
            return m.cols[0].scale(v.x)
                .add(m.cols[1].scale(v.y))
                .add(m.cols[2].scale(v.z))
                .add(m.cols[3].scale(v.w));
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{
                .cols = .{
                    a.mulVec(b.cols[0]),
                    a.mulVec(b.cols[1]),
                    a.mulVec(b.cols[2]),
                    a.mulVec(b.cols[3]),
                },
            };
        }

        pub fn translation(v: Vec3(T)) Self {
            return .{
                .cols = .{
                    .init(1, 0, 0, 0),
                    .init(0, 1, 0, 0),
                    .init(0, 0, 1, 0),
                    .init(v.x, v.y, v.z, 1),
                },
            };
        }

        pub fn scale(v: Vec3(T)) Self {
            return .{
                .cols = .{
                    .init(v.x, 0, 0, 0),
                    .init(0, v.y, 0, 0),
                    .init(0, 0, v.z, 0),
                    .init(0, 0, 0, 1),
                },
            };
        }

        pub fn rotation(axis: Vec3(T), angle: T) Self {
            const u = axis.normalize();
            const c = @cos(angle);
            const s = @sin(angle);
            const t = 1 - c;
            return .{
                .cols = .{
                    Vec4(T).init(c + t * u.x * u.x, t * u.x * u.y + s * u.z, t * u.x * u.z - s * u.y, 0),
                    Vec4(T).init(t * u.x * u.y - s * u.z, c + t * u.y * u.y, t * u.y * u.z + s * u.x, 0),
                    Vec4(T).init(t * u.x * u.z + s * u.y, t * u.y * u.z - s * u.x, c + t * u.z * u.z, 0),
                    Vec4(T).init(0, 0, 0, 1),
                },
            };
        }

        pub fn perspective(fov_y: T, aspect: T, near: T, far: T) Self {
            comptime if (@typeInfo(T) == .int) @compileError("Projection requires a float matrix");
            const f = 1 / @tan(fov_y / 2);
            return .{
                .cols = .{
                    Vec4(T).init(f / aspect, 0, 0, 0),
                    Vec4(T).init(0, f, 0, 0),
                    Vec4(T).init(0, 0, far / (near - far), -1),
                    Vec4(T).init(0, 0, near * far / (near - far), 0),
                },
            };
        }

        pub fn orthographic(left: T, right: T, top: T, bottom: T, near: T, far: T) Self {
            comptime if (@typeInfo(T) == .int) @compileError("Projection requires a float matrix");
            const v_diff = top - bottom;
            const h_diff = right - left;
            const d_diff = near - far;
            return .{
                .cols = .{
                    Vec4(T).init(2 / h_diff, 0, 0, 0),
                    Vec4(T).init(0, 2 / v_diff, 0, 0),
                    Vec4(T).init(0, 0, 1 / d_diff, 0),
                    Vec4(T).init(-(right + left) / h_diff, -(top + bottom) / v_diff, near / d_diff, 1),
                },
            };
        }

        pub fn lookAt(eye: Vec3(T), target: Vec3(T), up: Vec3(T)) Self {
            comptime if (@typeInfo(T) == .int) @compileError("lookAt requires a float matrix");
            const f = target.sub(eye).normalize();
            const r = f.cross(up).normalize();
            const u = r.cross(f);
            return .{
                .cols = .{
                    .init(r.x, u.x, -f.x, 0),
                    .init(r.y, u.y, -f.y, 0),
                    .init(r.z, u.z, -f.z, 0),
                    .init(-r.dot(eye), -u.dot(eye), f.dot(eye), 1),
                },
            };
        }

        pub fn toArray(self: Self) [4]Vec4(T) {
            return @bitCast(self);
        }

        pub fn asArray(self: *Self) *[4]Vec4(T) {
            return @ptrCast(self);
        }
    };
}
