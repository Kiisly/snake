comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;

const Vector2 = @import("Vector2.zig");
const game_API = @import("game_API.zig");
const GameMemory = game_API.Memory;
const GameInput = game_API.Input;
const GameOffscreenBuffer = game_API.OffscreenBuffer;

const TileMapPosition = struct {
    offset: Vector2 = .{}, // Offset from the center of a tile
    coord_x: u32 = 0,
    coord_y: u32 = 0,
};

const Entity = struct {
    position: TileMapPosition = .{},
    dimensions: Vector2 = .{ .x = 1.0, .y = 1.0 },
    velocity: Vector2 = .{},
    direction: Vector2 = .right,
    new_direction: Vector2 = .right,
};

const GameState = struct {
    snake_segments: [tile_count]Entity,
    snake_segment_count: u8 = 3,

    tile_map: [tile_count]Vector2 = [_]Vector2{.{}} ** tile_count,

    x_offset: u8 = 0,
    y_offset: u8 = 0,

    const window_height = 540;
    const window_width = 960;
    pub const tile_side_pixels = 60.0;
    pub const tiles_per_height: u32 = window_height / tile_side_pixels;
    pub const tiles_per_width: u32 = window_width / tile_side_pixels;
    const tile_count = tiles_per_height * tiles_per_width;
};

pub export fn gameUpdateAndRender(
    memory: *GameMemory,
    input: *GameInput,
    buffer: *GameOffscreenBuffer,
) callconv(.C) void {

    //@breakpoint();
    assert(@sizeOf(GameState) <= memory.permanent_storage.len);
    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));

    const tile_side_meters = 1.0;
    const tile_side_pixels = GameState.tile_side_pixels;
    const meters_to_pixels = tile_side_pixels / tile_side_meters;
    const tiles_per_height = GameState.tiles_per_height;
    const tiles_per_width = GameState.tiles_per_width;

    if (!memory.is_initialized) {
        memory.is_initialized = true;
        game_state.* = .{ .snake_segments = undefined };

        for (0..game_state.snake_segment_count) |i| {
            const snake_segment = &game_state.snake_segments[i];
            const coord_x = (game_state.snake_segment_count - 1 - @as(u8, @intCast(i)));
            snake_segment.* = .{
                .position = .{ .offset = .{}, .coord_x = coord_x, .coord_y = 1 },
                .dimensions = .{ .x = tile_side_meters, .y = tile_side_meters },
            };
        }
    }
    const snake_head = &game_state.snake_segments[0];

    const controller = game_API.getController(input, 0);
    for (controller.buttons) |button| {
        if (button.ended_down) {
            switch (button.name) {
                .up => {
                    snake_head.new_direction = .up;
                },

                .down => {
                    snake_head.new_direction = .down;
                },

                .left => {
                    snake_head.new_direction = .left;
                },

                .right => {
                    snake_head.new_direction = .right;
                },
            }
        }
    }

    moveSnake(
        &game_state.snake_segments,
        game_state.snake_segment_count,
        &game_state.tile_map,
        input.delta_time,
        tiles_per_width,
        tiles_per_height,
        tile_side_meters,
    );

    drawGradient(buffer, game_state.x_offset, game_state.y_offset);
    game_state.x_offset +%= 1;
    game_state.y_offset +%= 1;

    { // Draw snake segments
        //const screen_center_x = @as(f32, @floatFromInt(backbuffer.width)) * 0.5;
        //const screen_center_y = @as(f32, @floatFromInt(backbuffer.height)) * 0.5;
        //const central_tile_upper_left = Vector2{
        //    .x = screen_center_x - 0.5 * tile_side_pixels,
        //    .y = screen_center_y - 0.5 * tile_side_pixels,
        //};
        //const central_tile_lower_right = Vector2{
        //    .x = screen_center_x + 0.5 * tile_side_pixels,
        //    .y = screen_center_y + 0.5 * tile_side_pixels,
        //};
        //drawRectangle(&backbuffer, central_tile_upper_left, central_tile_lower_right, 0.1, 0.4, 0.7);

        //const half_tile_side_meters = tile_side_meters * 0.5;
        for (0..game_state.snake_segment_count) |i| {
            //const is_snake_tail = i == (game_state.snake_segment_count - 1);
            const snake_segment = &game_state.snake_segments[i];

            const max_coord_y = tiles_per_height - 1;
            const tile_upper_left = Vector2{
                .x = @as(f32, @floatFromInt(snake_segment.position.coord_x)) * tile_side_pixels,
                .y = @as(f32, @floatFromInt(max_coord_y - snake_segment.position.coord_y)) * tile_side_pixels,
            };
            //const tile_lower_right = Vector2{
            //    .x = tile_upper_left.x + tile_side_pixels,
            //    .y = tile_upper_left.y + tile_side_pixels,
            //};
            //if (i == 0) {
            //    drawRectangle(buffer, tile_upper_left, tile_lower_right, 1, 1, 1);
            //}

            const tile_center = Vector2{
                .x = tile_upper_left.x + 0.5 * tile_side_pixels,
                .y = tile_upper_left.y + 0.5 * tile_side_pixels,
            };

            const snake_center = Vector2{
                .x = tile_center.x + snake_segment.position.offset.x * meters_to_pixels,
                .y = tile_center.y - snake_segment.position.offset.y * meters_to_pixels,
            };

            const snake_upper_left = Vector2{
                .x = snake_center.x - 0.5 * snake_segment.dimensions.x * meters_to_pixels,
                .y = snake_center.y - 0.5 * snake_segment.dimensions.y * meters_to_pixels,
            };

            const snake_lower_right = Vector2{
                .x = snake_upper_left.x + snake_segment.dimensions.x * meters_to_pixels,
                .y = snake_upper_left.y + snake_segment.dimensions.y * meters_to_pixels,
            };

            //if (!is_snake_tail) {
            //    snake_lower_right = snake_lower_right.add(
            //        snake_segment.direction.scale(-snake_segment.position.offset.length() * meters_to_pixels).scale(meters_to_pixels),
            //    );
            //}
            drawRectangle(buffer, snake_upper_left, snake_lower_right, 0.0, 0.7, 0.4);

            //if (!is_snake_tail) {
            //    //const snake_bottom = snake_center.add(snake_segment.direction.scale(tile_side_pixels * -0.5));
            //    const new_pos = getNewPosition(
            //        snake_segment.position,
            //        snake_segment.direction.scale(-half_tile_side_meters),
            //        tiles_per_width,
            //        tiles_per_height,
            //        tile_side_meters,
            //    );
            //    tile_upper_left = Vector2{
            //        .x = @as(f32, @floatFromInt(new_pos.coord_x)) * tile_side_pixels,
            //        .y = @as(f32, @floatFromInt(max_coord_y - new_pos.coord_y)) * tile_side_pixels,
            //    };
            //    const tile_lower_right = Vector2{
            //        .x = tile_upper_left.x + tile_side_pixels,
            //        .y = tile_upper_left.y + tile_side_pixels,
            //    };
            //    drawRectangle(buffer, tile_upper_left, tile_lower_right, 0.0, 0.7, 0.4);
            //}
        }
    }
}

fn moveSnake(
    snake_segments: []Entity,
    snake_segment_count: u8,
    direction_map: []Vector2,
    dt: f32,
    tiles_per_width: i32,
    tiles_per_height: i32,
    tile_side_meters: f32,
) void {
    const snake_head = &snake_segments[0];
    const snake_speed = 55.0;
    var acceleration = snake_head.direction.scale(snake_speed).sub(
        snake_head.velocity.scale(10),
    );
    var snake_delta = Vector2.add(
        acceleration.scale(0.5 * dt * dt),
        snake_head.velocity.scale(dt),
    );
    snake_head.velocity = snake_head.velocity.add(acceleration.scale(dt));
    const distance_traveled = snake_delta.length();

    var new_position = getNewPosition(
        snake_head.position,
        snake_delta,
        tiles_per_width,
        tiles_per_height,
        tile_side_meters,
    );

    for (0..snake_segment_count) |i| {
        const snake_segment = &snake_segments[i];
        const is_snake_head = i == 0;

        if (!is_snake_head) {
            acceleration = snake_segment.direction.scale(snake_speed).sub(
                snake_segment.velocity.scale(10),
            );
            snake_delta = snake_segment.direction.scale(distance_traveled);
            snake_segment.velocity = snake_segment.velocity.add(acceleration.scale(dt));

            new_position = getNewPosition(
                snake_segment.position,
                snake_delta,
                tiles_per_width,
                tiles_per_height,
                tile_side_meters,
            );

            const previous_snake_segment = &snake_segments[i - 1];
            if (new_position.coord_x == previous_snake_segment.position.coord_x and
                new_position.coord_y == previous_snake_segment.position.coord_y)
            {
                break;
            }
        }

        const crossed_center_of_tile = snake_segment.position.offset.dot(
            snake_segment.position.offset.add(snake_delta),
        ) <= 0.0;
        const accept_change_of_direction = snake_segment.new_direction.dot(
            snake_segment.direction,
        ) == 0.0;
        if (accept_change_of_direction and crossed_center_of_tile) {
            snake_segment.direction = snake_segment.new_direction;
            snake_segment.position.offset = snake_segment.new_direction.scale(
                snake_segment.position.offset.add(snake_delta).length(),
            );
            snake_segment.velocity = .{};
        } else {
            snake_segment.position = new_position;
        }

        const change_of_tile = ((new_position.coord_x != snake_segment.position.coord_x) or
            (new_position.coord_y != snake_segment.position.coord_y));

        const tile_index = (snake_segment.position.coord_y * @as(u32, @intCast(tiles_per_width)) +
            snake_segment.position.coord_x);
        if (change_of_tile and !is_snake_head) {
            snake_segment.new_direction = direction_map[tile_index];
        }
        direction_map[tile_index] = snake_segment.direction;
    }
}

fn drawRectangle(
    buffer: *GameOffscreenBuffer,
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

fn drawGradient(
    buffer: *GameOffscreenBuffer,
    x_offset: u8,
    y_offset: u8,
) void {
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

fn getNewPosition(
    old_position: TileMapPosition,
    new_offset: Vector2,
    tiles_per_width: i32,
    tiles_per_height: i32,
    tile_side_meters: f32,
) TileMapPosition {
    var result: TileMapPosition = undefined;
    result.offset = old_position.offset.add(new_offset);
    result.coord_x, result.offset.x = getNewCoordinateAndRelativeOffset(
        old_position.coord_x,
        result.offset.x,
        tiles_per_width,
        tile_side_meters,
    );
    result.coord_y, result.offset.y = getNewCoordinateAndRelativeOffset(
        old_position.coord_y,
        result.offset.y,
        tiles_per_height,
        tile_side_meters,
    );
    return result;
}

fn getNewCoordinateAndRelativeOffset(
    coord: u32,
    offset: f32,
    max_coord: i32,
    tile_side_meters: f32,
) struct { u32, f32 } {
    //const new_offset: i32 = @intFromFloat(@round(offset / tile_side_meters));
    var result_coord: i32 = @as(i32, @intCast(coord)) + @as(i32, @intFromFloat(@round(offset / tile_side_meters)));
    if (result_coord >= max_coord) {
        result_coord = 0;
    } else if (result_coord < 0) {
        result_coord = max_coord - 1;
    }
    const result_offset = offset - @round(offset);
    return .{ @intCast(result_coord), result_offset };
}

fn initializeEntity(
    x: u32,
    y: u32,
    offset: Vector2,
    dims: Vector2,
    velocity: Vector2,
    dir: Vector2,
) Entity {
    return .{
        .position = .{
            .coord_x = x,
            .coord_y = y,
            .offset = offset,
        },
        .dimensions = dims,
        .velocity = velocity,
        .direction = dir,
        .new_direction = dir,
    };
}
