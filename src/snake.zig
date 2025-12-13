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
const queue = @import("queue.zig");

const Snake = struct {
    body: queue.Queue(Vector2), // Tiles occupied by the snake
    direction: Vector2,
    new_direction: Vector2,

    pub const initial_length = 3;
};

const GameState = struct {
    permanent_arena: Arena,
    snake: Snake,
    step_cooldown: f32 = 0,

    x_offset: u8 = 0,
    y_offset: u8 = 0,

    const window_height = 540;
    const window_width = 960;

    pub const step_interval = 0.125;
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

        game_state.* = .{
            .permanent_arena = .init(memory.permanent_storage[@sizeOf(GameState)..]),
            .snake = .{
                .body = .init(&game_state.permanent_arena, GameState.tile_count),
                .direction = .right,
                .new_direction = .right,
            },
        };

        for (0..Snake.initial_length) |i| {
            const snake_segment: Vector2 = .{ .x = @floatFromInt(i), .y = 3 };
            game_state.snake.body.enqueue(snake_segment);
        }
    }

    const snake = &game_state.snake;

    const controller = game_API.getController(input, 0);
    for (controller.buttons) |button| {
        if (button.ended_down) {
            switch (button.name) {
                .up => {
                    snake.new_direction = .up;
                },

                .down => {
                    snake.new_direction = .down;
                },

                .left => {
                    snake.new_direction = .left;
                },

                .right => {
                    snake.new_direction = .right;
                },
            }
        }
    }

    stepSnake(
        snake,
        input.delta_time,
        &game_state.step_cooldown,
        GameState.step_interval,
    );

    drawGradient(buffer, game_state.x_offset, game_state.y_offset);
    game_state.x_offset +%= 1;
    game_state.y_offset +%= 1;

    drawSnake(
        buffer,
        snake,
        game_state.step_cooldown,
    );
}

fn worldSpaceToScreenSpace(v: Vector2, window_height: f32) Vector2 {
    return .{ .x = v.x, .y = window_height - v.y };
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
    var head_upper_left_world: Vector2 = .{
        .x = head_tile.x * tile_side_pixels,
        .y = (head_tile.y + 1) * tile_side_pixels,
    };
    head_upper_left_world = .add(
        head_upper_left_world,
        .scale(snake.direction, -distance),
    );

    const window_height: f32 = @floatFromInt(buffer.height);
    const head_upper_left = worldSpaceToScreenSpace(
        head_upper_left_world,
        window_height,
    );
    const head_lower_right: Vector2 = .addScalar(
        head_upper_left,
        tile_side_pixels,
    );

    drawRectangle(buffer, head_upper_left, head_lower_right, 0.0, 0.7, 0.4);

    const tail_tile = snake.body.get(0);
    const next_tail_tile = snake.body.get(1);
    var tail_direction: Vector2 = .sub(next_tail_tile, tail_tile);
    if (tail_direction.lengthSquared() > 1.0) {
        tail_direction = .scale(.normalized(tail_direction), -1);
    }
    var tail_lower_right_world: Vector2 = .{
        .x = next_tail_tile.x * tile_side_pixels + tile_side_pixels,
        .y = next_tail_tile.y * tile_side_pixels,
    };
    var tail_upper_left_world: Vector2 = .{
        .x = tail_lower_right_world.x - tile_side_pixels,
        .y = tail_lower_right_world.y + tile_side_pixels,
    };
    tail_upper_left_world = .add(
        tail_upper_left_world,
        .scale(tail_direction, -distance),
    );
    tail_lower_right_world = .add(
        tail_lower_right_world,
        .scale(tail_direction, -distance),
    );

    const tail_upper_left = worldSpaceToScreenSpace(
        tail_upper_left_world,
        window_height,
    );
    const tail_lower_right = worldSpaceToScreenSpace(
        tail_lower_right_world,
        window_height,
    );

    drawRectangle(buffer, tail_upper_left, tail_lower_right, 0.0, 0.7, 0.4);

    // Draw tiles occupied by the snake except head and tail
    const max_coord_y = GameState.tiles_per_height - 1;
    for (1..snake.body.size - 1) |i| {
        const tile = snake.body.get(i);
        const tile_upper_left: Vector2 = .{
            .x = tile.x * tile_side_pixels,
            .y = (max_coord_y - tile.y) * tile_side_pixels,
        };

        const tile_lower_right: Vector2 = .addScalar(tile_upper_left, tile_side_pixels);
        drawRectangle(buffer, tile_upper_left, tile_lower_right, 0.0, 0.7, 0.4);
    }
}

fn stepSnake(
    snake: *Snake,
    dt: f32,
    step_cooldown: *f32,
    step_interval: f32,
) void {
    step_cooldown.* -= dt;
    if (step_cooldown.* <= 0.0) {
        if (Vector2.dot(snake.direction, snake.new_direction) == 0.0) {
            snake.direction = snake.new_direction;
        }

        const tiles_per_width = GameState.tiles_per_width;
        const tiles_per_height = GameState.tiles_per_height;
        var next_head: Vector2 = .add(
            snake.body.get(snake.body.size - 1),
            snake.direction,
        );
        next_head = .{
            .x = @mod(next_head.x, tiles_per_width),
            .y = @mod(next_head.y, tiles_per_height),
        };
        snake.body.enqueue(next_head);
        _ = snake.body.dequeue();
        step_cooldown.* = step_interval;
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
    const color: u32 = red | green | blue;
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

fn drawGradient(buffer: *const GameOffscreenBuffer, x_offset: u8, y_offset: u8) void {
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    const height: usize = @intCast(buffer.height);
    const width: usize = @intCast(buffer.width);
    for (0..height) |row| {
        for (0..width) |column| {
            const blue: u8 = @truncate((column +% x_offset) << 0);
            const green: u16 = @truncate((0) << 8);
            const red: u32 = @truncate((row +% y_offset) << 16);
            pixels[row * width + column] = red | green | blue;
        }
    }
}
