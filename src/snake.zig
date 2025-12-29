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
    step_cooldown: f32 = 0,

    egg: Vector2,

    prng: std.Random.Xoshiro256,
    rand: std.Random,

    x_offset: u8 = 0,
    y_offset: u8 = 0,

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

        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = 92;
        };
        game_state.* = .{
            .permanent_arena = .init(memory.permanent_storage[@sizeOf(GameState)..]),
            .snake = .{
                .body = .init(&game_state.permanent_arena, GameState.tile_count),
                .direction = .right,
                .turn_queue = .init(&game_state.permanent_arena, 4),
                .eaten_egg = false,
            },
            .prng = std.Random.DefaultPrng.init(seed),
            .rand = game_state.prng.random(),
            .egg = undefined,
        };

        for (0..Snake.initial_length) |i| {
            const snake_segment: Vector2 = .{ .x = @floatFromInt(i), .y = 3 };
            game_state.snake.body.enqueue(snake_segment);
        }

        game_state.egg = generateRandomEgg(game_state.rand, &game_state.snake);
    }

    const snake = &game_state.snake;

    const controller = game_API.getController(input, 0);
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
            }
        }
    }

    stepSnake(
        snake,
        game_state.egg,
        input.delta_time,
        &game_state.step_cooldown,
        GameState.step_interval,
    );

    drawGradient(buffer, game_state.x_offset, game_state.y_offset);
    game_state.x_offset +%= 1;
    game_state.y_offset +%= 1;

    if (snake.eaten_egg) {
        game_state.egg = generateRandomEgg(game_state.rand, &game_state.snake);
        snake.eaten_egg = false;
    }

    { // Draw egg
        const tile_side_pixels = GameState.tile_side_pixels;
        const egg_upper_left: Vector2 = tilemapSpaceToScreenSpace(game_state.egg);
        const egg_lower_right: Vector2 = .addScalar(egg_upper_left, tile_side_pixels);
        drawRectangle(buffer, egg_upper_left, egg_lower_right, 0.7, 0.5, 0.3);
    }

    drawSnake(
        buffer,
        snake,
        game_state.step_cooldown,
    );
}

fn generateRandomEgg(rand: std.Random, snake: *Snake) Vector2 {
    var result: Vector2 = .{
        .x = @floatFromInt(rand.uintLessThan(u8, GameState.tiles_per_width)),
        .y = @floatFromInt(rand.uintLessThan(u4, GameState.tiles_per_height)),
    };
    while (isTileOccupiedBySnake(result, snake)) {
        result = .{
            .x = @floatFromInt(rand.uintLessThan(u8, GameState.tiles_per_width)),
            .y = @floatFromInt(rand.uintLessThan(u4, GameState.tiles_per_height)),
        };
    }
    return result;
}

fn isTileOccupiedBySnake(tile: Vector2, snake: *Snake) bool {
    var occupied = false;
    var it = snake.body.iterator();
    while (it.next()) |snake_tile| {
        if (tile.x == snake_tile.x and tile.y == snake_tile.y) {
            occupied = true;
            break;
        }
    }
    return occupied;
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

    drawRectangle(buffer, head_upper_left, head_lower_right, 0.0, 0.7, 0.4);

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

    drawRectangle(buffer, tail_upper_left, tail_lower_right, 0.0, 0.7, 0.4);

    // Draw tiles occupied by the snake except head and tail
    for (1..snake.body.size - 1) |i| {
        const tile = snake.body.get(i);
        const tile_upper_left: Vector2 = tilemapSpaceToScreenSpace(tile);
        const tile_lower_right: Vector2 = .addScalar(tile_upper_left, tile_side_pixels);
        drawRectangle(buffer, tile_upper_left, tile_lower_right, 0.0, 0.7, 0.4);
    }
}

fn stepSnake(
    snake: *Snake,
    egg: Vector2,
    dt: f32,
    step_cooldown: *f32,
    step_interval: f32,
) void {
    step_cooldown.* -= dt;
    if (step_cooldown.* <= 0.0) {
        while (!snake.turn_queue.isEmpty()) {
            const new_direction = snake.turn_queue.dequeue();
            if (Vector2.dot(snake.direction, new_direction) == 0.0) {
                snake.direction = new_direction;
                break;
            }
        }

        const current_head: Vector2 = snake.body.get(snake.body.size - 1);
        var next_head: Vector2 = .add(
            current_head,
            snake.direction,
        );
        next_head = .{
            .x = @mod(next_head.x, GameState.tiles_per_width),
            .y = @mod(next_head.y, GameState.tiles_per_height),
        };
        if (current_head.x == egg.x and current_head.y == egg.y) {
            snake.eaten_egg = true;
        } else {
            _ = snake.body.dequeue();
        }
        snake.body.enqueue(next_head);
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
