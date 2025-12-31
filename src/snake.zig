comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const lerp = std.math.lerp;

const Vector2 = @import("Vector2.zig");
const game_API = @import("game_API.zig");
const GameMemory = game_API.Memory;
const GameInput = game_API.Input;
const GameOffscreenBuffer = game_API.OffscreenBuffer;
const Arena = @import("Arena.zig");
const Queue = @import("queue.zig").Queue;

const Snake = struct {
    body: Queue(Vector2), // Tiles occupied by the snake
    direction: Vector2,
    turn_queue: Queue(Vector2),
    eaten_egg: bool,

    pub const initial_length = 3;
};

const GameState = struct {
    permanent_arena: Arena,
    snake: Snake,
    step_cooldown: f32,

    egg: Vector2,

    x_offset: u8 = 0,
    y_offset: u8 = 0,

    mode: Mode,

    const Mode = enum {
        gameplay,
        game_over,
        pause,
    };

    const window_width = 960;
    pub const window_height = 540;
    pub const step_interval = 0.160;
    pub const tile_side_pixels = 60.0;
    pub const tiles_per_height: u32 = window_height / tile_side_pixels;
    pub const tiles_per_width: u32 = window_width / tile_side_pixels;
    pub const tile_count = tiles_per_height * tiles_per_width;
};

pub export fn gameUpdateAndRender(
    memory: *GameMemory,
    input: *GameInput,
    buffer: *GameOffscreenBuffer,
) callconv(.c) void {
    assert(@sizeOf(GameState) <= memory.permanent_storage.len);
    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));

    if (!memory.is_initialized) {
        memory.is_initialized = true;
        restartGame(game_state, memory);
    }

    const snake = &game_state.snake;
    const controller = game_API.getController(input, 0);
    switch (game_state.mode) {
        .gameplay => {
            for (controller.buttons) |button| {
                if (button.ended_down) {
                    switch (button.name) {
                        .up => {
                            snake.turn_queue.enqueueDisplace(.up);
                        },

                        .down => {
                            snake.turn_queue.enqueueDisplace(.down);
                        },

                        .left => {
                            snake.turn_queue.enqueueDisplace(.left);
                        },

                        .right => {
                            snake.turn_queue.enqueueDisplace(.right);
                        },

                        .pause => {
                            game_state.mode = .pause;
                        },

                        else => unreachable,
                    }
                }
            }

            stepSnake(
                snake,
                game_state.egg,
                &game_state.mode,
                input.delta_time,
                &game_state.step_cooldown,
            );

            drawColour(buffer, 125.0 / 255.0, 242.0 / 255.0, 242.0 / 255.0);
            game_state.x_offset +%= 1;
            game_state.y_offset +%= 1;

            if (snake.eaten_egg) {
                game_state.egg = generateRandomEgg(memory.rand, &game_state.snake);
                snake.eaten_egg = false;
            }

            { // Draw egg
                const egg_upper_left: Vector2 = tilemapSpaceToScreenSpace(game_state.egg);
                const egg_lower_right: Vector2 = .addScalar(egg_upper_left, GameState.tile_side_pixels);
                const r = 208.0 / 255.0;
                const g = 232.0 / 255.0;
                const b = 116.0 / 255.0;
                drawRectangle(buffer, egg_upper_left, egg_lower_right, r, g, b);
            }

            drawSnake(buffer, snake, game_state.step_cooldown);
        },

        .game_over => {
            for (controller.buttons) |button| {
                if (button.ended_down) {
                    restartGame(game_state, memory);
                    break;
                }
            }
        },

        .pause => {
            if (game_API.getButton(&controller.buttons, .pause).ended_down) {
                game_state.mode = .gameplay;
            }
        },
    }
}

fn restartGame(game_state: *GameState, memory: *GameMemory) void {
    game_state.* = .{
        .mode = .gameplay,
        .permanent_arena = .init(memory.permanent_storage[@sizeOf(GameState)..]),
        .snake = .{
            .body = .init(&game_state.permanent_arena, GameState.tile_count),
            .direction = .{},
            .turn_queue = .init(&game_state.permanent_arena, 3),
            .eaten_egg = false,
        },
        .step_cooldown = 0.0,
        .egg = undefined,
    };

    const rand = memory.rand;
    switch (rand.uintLessThanBiased(u4, 4)) {
        0 => game_state.snake.direction = .{ .x = 1.0, .y = 0 },
        1 => game_state.snake.direction = .{ .x = 0.0, .y = 1.0 },
        2 => game_state.snake.direction = .{ .x = -1.0, .y = 0.0 },
        3 => game_state.snake.direction = .{ .x = 0.0, .y = -1.0 },
        else => unreachable,
    }

    var snake_tile: Vector2 = .{
        .x = @floatFromInt(rand.uintLessThanBiased(u8, GameState.tiles_per_width)),
        .y = @floatFromInt(rand.uintLessThanBiased(u4, GameState.tiles_per_height)),
    };
    for (0..Snake.initial_length) |_| {
        game_state.snake.body.enqueue(snake_tile);
        snake_tile = .add(snake_tile, game_state.snake.direction);
        snake_tile = .{
            .x = @mod(snake_tile.x, GameState.tiles_per_width),
            .y = @mod(snake_tile.y, GameState.tiles_per_height),
        };
    }

    game_state.egg = generateRandomEgg(rand, &game_state.snake);
}

fn generateRandomEgg(rand: std.Random, snake: *Snake) Vector2 {
    var result: Vector2 = .{
        .x = @floatFromInt(rand.uintLessThanBiased(u8, GameState.tiles_per_width)),
        .y = @floatFromInt(rand.uintLessThanBiased(u4, GameState.tiles_per_height)),
    };
    while (isTileOccupiedBySnake(result, snake)) {
        result = .{
            .x = @floatFromInt(rand.uintLessThanBiased(u8, GameState.tiles_per_width)),
            .y = @floatFromInt(rand.uintLessThanBiased(u4, GameState.tiles_per_height)),
        };
    }
    return result;
}

fn isTileOccupiedBySnake(tile: Vector2, snake: *Snake) bool {
    var occupied = false;
    var it = snake.body.iterator();
    while (it.next()) |snake_tile| {
        if (isSameTile(tile, snake_tile)) {
            occupied = true;
            break;
        }
    }
    return occupied;
}

fn isSameTile(a: Vector2, b: Vector2) bool {
    return (a.x == b.x and a.y == b.y);
}

fn tilemapToWorldSpace(v: Vector2) Vector2 {
    return .{
        .x = v.x * GameState.tile_side_pixels,
        .y = (v.y + 1) * GameState.tile_side_pixels,
    };
}

fn worldSpaceToScreenSpace(v: Vector2) Vector2 {
    return .{
        .x = v.x,
        .y = @as(f32, @floatFromInt(GameState.window_height)) - v.y,
    };
}

fn tilemapSpaceToScreenSpace(v: Vector2) Vector2 {
    const window_height: f32 = @floatFromInt(GameState.window_height);
    const result: Vector2 = .{
        .x = v.x * GameState.tile_side_pixels,
        .y = window_height - (v.y + 1) * GameState.tile_side_pixels,
    };
    return result;
}

fn drawSnake(
    buffer: *const GameOffscreenBuffer,
    snake: *const Snake,
    step_cooldown: f32,
) void {
    const tile_side_pixels = GameState.tile_side_pixels;
    const t = step_cooldown / GameState.step_interval;
    const distance = lerp(0.0, tile_side_pixels, t);

    const head_tile = snake.body.get(snake.body.size - 1);
    var head_upper_left_world: Vector2 = tilemapToWorldSpace(head_tile);
    head_upper_left_world = .add(
        head_upper_left_world,
        .scale(snake.direction, -distance),
    );

    const head_upper_left = worldSpaceToScreenSpace(head_upper_left_world);
    const head_lower_right: Vector2 = .addScalar(
        head_upper_left,
        tile_side_pixels,
    );

    const r = 45.0 / 255.0;
    const g = 216.0 / 255.0;
    const b = 125.0 / 255.0;
    drawRectangle(buffer, head_upper_left, head_lower_right, r, g, b);

    const tail_tile = snake.body.get(0);
    const next_tail_tile = snake.body.get(1);
    var tail_direction: Vector2 = .sub(next_tail_tile, tail_tile);
    if (tail_direction.lengthSquared() > 1.0) {
        tail_direction = .scale(.normalized(tail_direction), -1);
    }

    var tail_upper_left_world: Vector2 = tilemapToWorldSpace(tail_tile);
    tail_upper_left_world = .add(
        tail_upper_left_world,
        .scale(tail_direction, tile_side_pixels - distance),
    );
    const tail_upper_left = worldSpaceToScreenSpace(tail_upper_left_world);

    const tail_lower_right: Vector2 = .addScalar(tail_upper_left, tile_side_pixels);

    drawRectangle(buffer, tail_upper_left, tail_lower_right, r, g, b);

    // Draw tiles occupied by the snake except head and tail
    for (1..snake.body.size - 1) |i| {
        const tile = snake.body.get(i);
        const tile_upper_left: Vector2 = tilemapSpaceToScreenSpace(tile);
        const tile_lower_right: Vector2 = .addScalar(tile_upper_left, tile_side_pixels);
        drawRectangle(buffer, tile_upper_left, tile_lower_right, r, g, b);
    }
}

fn stepSnake(
    snake: *Snake,
    egg: Vector2,
    game_mode: *GameState.Mode,
    dt: f32,
    step_cooldown: *f32,
) void {
    step_cooldown.* -= dt;
    if (step_cooldown.* <= 0.0) {
        if (!snake.turn_queue.isEmpty()) {
            const new_direction = snake.turn_queue.dequeue();
            if (Vector2.dot(snake.direction, new_direction) == 0.0) {
                snake.direction = new_direction;
            }
        }

        const current_head: Vector2 = snake.body.get(snake.body.size - 1);
        var next_head: Vector2 = .add(current_head, snake.direction);
        next_head = .{
            .x = @mod(next_head.x, GameState.tiles_per_width),
            .y = @mod(next_head.y, GameState.tiles_per_height),
        };

        // Check if snake collided with itself ignoring tail
        for (1..snake.body.size - 1) |i| {
            const snake_tile = snake.body.get(i);
            if (isSameTile(snake_tile, current_head)) {
                game_mode.* = .game_over;
            }
        }

        if (isSameTile(current_head, egg)) {
            snake.eaten_egg = true;
        } else {
            _ = snake.body.dequeue();
        }

        snake.body.enqueue(next_head);
        step_cooldown.* = GameState.step_interval;
    }
}

fn drawRectangle(
    buffer: *const GameOffscreenBuffer,
    min: Vector2,
    max: Vector2,
    r: f32,
    g: f32,
    b: f32,
) void {
    var min_x: i32 = @intFromFloat(@round(min.x));
    var min_y: i32 = @intFromFloat(@round(min.y));
    var max_x: i32 = @intFromFloat(@round(max.x));
    var max_y: i32 = @intFromFloat(@round(max.y));

    if (min_x < 0) min_x = 0;
    if (min_y < 0) min_y = 0;
    if (max_x > buffer.width) max_x = buffer.width;
    if (max_y > buffer.height) max_y = buffer.height;

    // zig fmt: off
    const red   = @as(u32, @intFromFloat(@round(r * 255.0))) << 16;
    const green = @as(u16, @intFromFloat(@round(g * 255.0))) <<  8;
    const blue  = @as(u8,  @intFromFloat(@round(b * 255.0))) <<  0;
    const alpha = 255 << 24;
    const color: u32 = alpha | red | green | blue;
    // zig fmt: on

    const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    var row = min_y;
    var column = min_x;
    while (row < max_y) : (row += 1) {
        column = min_x;
        while (column < max_x) : (column += 1) {
            const pixel_index: usize = @intCast(row * buffer.width + column);
            pixels[pixel_index] = color;
        }
    }
}

fn drawChekeredPattern(buffer: *const GameOffscreenBuffer, dims: u32) void {
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    const height: usize = @intCast(buffer.height);
    const width: usize = @intCast(buffer.width);
    const white = 0xff_ff_ff_ff;
    const black = 0x00_00_00_00;
    var color: u32 = undefined;
    for (0..height) |row| {
        for (0..width) |column| {
            color = if (((column / dims) + (row / dims)) % 2 == 0) white else black;
            pixels[row * width + column] = color;
        }
    }
}

fn drawChekeredPattern2(buffer: *const GameOffscreenBuffer) void {
    var isBlue = true;
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    const tile_side_pixels = GameState.tile_side_pixels;
    var i: u32 = 0;
    var j: u32 = undefined;
    while (i < buffer.height) : (i += tile_side_pixels) {
        j = 0;
        while (j < buffer.width) : (j += tile_side_pixels) {
            if (isBlue) {
                r = 125.0 / 255.0;
                g = 242.0 / 255.0;
                b = g;
            } else {
                r = 140.0 / 255.0;
                g = 135.0 / 255.0;
                b = 186.0 / 255.0;
            }

            const tile_upper_left: Vector2 = .{
                .x = @floatFromInt(j),
                .y = @floatFromInt(i),
            };
            const tile_lower_right: Vector2 = .addScalar(tile_upper_left, tile_side_pixels);
            drawRectangle(buffer, tile_upper_left, tile_lower_right, r, g, b);
            isBlue = !isBlue;
        }
        isBlue = !isBlue;
    }
}

fn drawColour(buffer: *const GameOffscreenBuffer, r: f32, g: f32, b: f32) void {
    const red: u24 = @as(u24, @intFromFloat(@round(r * 255.0))) << 16;
    const green: u16 = @as(u16, @intFromFloat(@round(g * 255.0))) << 8;
    const blue: u8 = @intFromFloat(@round(b * 255.0));
    const alpha: u32 = 255 << 24;
    const colour: u32 = alpha | red | green | blue;

    var pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    const pixel_count: usize = @intCast(buffer.width * buffer.height);
    for (0..pixel_count) |i| {
        pixels[i] = colour;
    }
}

fn drawGradient(buffer: *const GameOffscreenBuffer, x_offset: u8, y_offset: u8) void {
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    const height: usize = @intCast(buffer.height);
    const width: usize = @intCast(buffer.width);
    for (0..height) |row| {
        for (0..width) |column| {
            const blue: u8 = @truncate((column +% x_offset) << 0);
            const green: u16 = @truncate((0) << 8);
            const red: u32 = @truncate((row +% y_offset) << 16);
            const alpha: u32 = 255 << 24;
            pixels[row * width + column] = alpha | red | green | blue;
        }
    }
}
