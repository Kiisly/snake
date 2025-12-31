const std = @import("std");
const assert = std.debug.assert;

pub const UpdateAndRender = ?*const fn (memory: *Memory, input: *Input, buffer: *OffscreenBuffer) callconv(.c) void;

pub const Memory = struct {
    permanent_storage: []u8,
    transient_storage: []u8,
    cache_transient_storage: []u8,
    is_initialized: bool,

    // Interface for generating pseudo random numbers.
    // It is not in the game code because
    // it doesn't survive hot code reloading
    // TODO: Where does this belong?
    rand: std.Random,
};

pub const Input = struct {
    controllers: [5]Controller,
    delta_time: f32,
};

pub const OffscreenBuffer = struct {
    memory: [*]u8,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

pub const Controller = struct {
    buttons: [buttons_count]ButtonState,
    is_conected: bool,
    is_analog: bool,

    const buttons_count = @intFromEnum(ButtonName.count);

    pub fn init() Controller {
        var result: Controller = .{
            .is_conected = true,
            .is_analog = false,
            .buttons = undefined,
        };

        for (0..result.buttons.len) |i| {
            result.buttons[i].name = @enumFromInt(i);
            result.buttons[i].ended_down = false;
        }
        return result;
    }
};

pub const ButtonState = struct {
    //half_transition_count: i32,
    name: ButtonName,
    ended_down: bool,
};

const ButtonName = enum {
    up,
    down,
    left,
    right,
    pause,
    count,
};

pub fn getController(input: *Input, index: usize) *Controller {
    assert(index < input.controllers.len);
    return &input.controllers[index];
}

pub fn getButton(buttons: []ButtonState, name: ButtonName) *ButtonState {
    const index: usize = @intFromEnum(name);
    return &buttons[index];
}
