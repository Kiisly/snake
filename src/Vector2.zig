comptime {
    @setFloatMode(.optimized);
}

const assert = @import("std").debug.assert;

x: f32 = 0.0,
y: f32 = 0.0,

const Vector2 = @This();

// zig fmt: off
pub const up:    Vector2 = .{ .x =  0.0,  .y =  1.0 };
pub const down:  Vector2 = .{ .x =  0.0,  .y = -1.0 };
pub const left:  Vector2 = .{ .x = -1.0,  .y =  0.0 };
pub const right: Vector2 = .{ .x =  1.0,  .y =  0.0 };
// zig fmt: on

pub fn dot(a: Vector2, b: Vector2) f32 {
    const result = a.x * b.x + a.y * b.y;
    return result;
}

pub fn scale(a: Vector2, scalar: f32) Vector2 {
    const result = Vector2{
        .x = a.x * scalar,
        .y = a.y * scalar,
    };
    return result;
}

pub fn sub(a: Vector2, b: Vector2) Vector2 {
    const result = Vector2{
        .x = a.x - b.x,
        .y = a.y - b.y,
    };
    return result;
}

pub fn add(a: Vector2, b: Vector2) Vector2 {
    const result = Vector2{
        .x = a.x + b.x,
        .y = a.y + b.y,
    };
    return result;
}

pub fn div(a: Vector2, scalar: f32) Vector2 {
    assert(scalar != 0);
    const result = Vector2{
        .x = a.x / scalar,
        .y = a.y / scalar,
    };
    return result;
}

pub fn divChecked(a: Vector2, scalar: f32) !Vector2 {
    if (scalar == 0) return error.DivisionByZero;
    return a.div(scalar);
}

pub fn lengthSquared(a: Vector2) f32 {
    const result = a.dot(a);
    return result;
}

pub fn length(a: Vector2) f32 {
    const result = @sqrt(a.lengthSquared());
    return result;
}

pub fn normalized(a: Vector2) Vector2 {
    const len = a.length();
    const result = a.scale(1.0 / len);
    return result;
}

pub fn normalize(self: *Vector2) void {
    self.* = self.scale(1.0 / self.length());
}
