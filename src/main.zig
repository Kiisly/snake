comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const assert = std.debug.assert;
const c = @import("c.zig").c;
const sdl_log = std.log.scoped(.sdl);
const log = std.log.scoped(.app);

const game_API = @import("game_API.zig");
const GameMemory = game_API.Memory;
const GameInput = game_API.Input;
const GameOffscreenBuffer = game_API.OffscreenBuffer;
const getButton = game_API.getButton;

const target_triple: [:0]const u8 = lable: {
    var buffer: [256]u8 = undefined;
    var ally: std.heap.FixedBufferAllocator = .init(&buffer);
    break :lable (builtin.target.zigTriple(ally.allocator()) catch unreachable) ++ "";
};

const PlatformOffscreenBuffer = struct {
    // NOTE: Pixels are always 32 bits wide. Memory order (little-endian): B-G-R-A
    //memory: []u8,
    texture: *c.SDL_Texture,
    width: i32,
    height: i32,
    pitch: i32,
};

pub fn main() !void {
    errdefer |err| if (err == error.SdlError) {
        sdl_log.debug("SDL error: {s}", .{c.SDL_GetError()});
    };

    std.log.debug("{s} {s}", .{ target_triple, @tagName(builtin.mode) });
    const platform: [*:0]const u8 = c.SDL_GetPlatform();
    sdl_log.debug("SDL platform: {s}", .{platform});
    sdl_log.debug("SDL build time version: {d}.{d}.{d}", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_MICRO_VERSION,
    });

    sdl_log.debug("SDL build time revesion: {s}", .{c.SDL_REVISION});

    {
        const version = c.SDL_GetVersion();
        sdl_log.debug("SDL runtime version: {d}.{d}.{d}", .{
            c.SDL_VERSIONNUM_MAJOR(version),
            c.SDL_VERSIONNUM_MINOR(version),
            c.SDL_VERSIONNUM_MICRO(version),
        });
        const revision: [*:0]const u8 = c.SDL_GetRevision();
        sdl_log.debug("SDL runtime revision: {s}", .{revision});
    }

    // For programs that provide their own entry point instead of relying on SDL's main function macro magic,
    // 'SDL_SetMainReady' should be called before calling 'SDL_Init'.
    c.SDL_SetMainReady();

    if (!c.SDL_SetAppMetadata("Snake", "0.1.0", null)) {
        sdl_log.debug("SDL error: {s}", .{c.SDL_GetError()});
    }

    try errify(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();

    sdl_log.debug("SDL video drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetCurrentVideoDriver().?,
        c.SDL_GetNumVideoDrivers(),
        c.SDL_GetVideoDriver,
    )});

    if (!c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) {
        sdl_log.debug("Unable to turn on VSYNC: {s}", .{c.SDL_GetError()});
    }

    const window_width = 960;
    const window_height = 540;
    const window, const renderer = get_window_and_renderer: {
        var window: ?*c.SDL_Window = null;
        var renderer: ?*c.SDL_Renderer = null;
        try errify(c.SDL_CreateWindowAndRenderer(
            "Snake",
            window_width,
            window_height,
            c.SDL_WINDOW_RESIZABLE,
            &window,
            &renderer,
        ));
        break :get_window_and_renderer .{ window.?, renderer.? };
    };
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);

    if (!c.SDL_SetRenderLogicalPresentation(
        renderer,
        window_width,
        window_height,
        c.SDL_LOGICAL_PRESENTATION_LETTERBOX,
    )) {
        sdl_log.debug("Failed to set logical presentation: {s}", .{c.SDL_GetError()});
    }

    sdl_log.debug("SDL render drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetRendererName(renderer).?,
        c.SDL_GetNumRenderDrivers(),
        c.SDL_GetRenderDriver,
    )});

    var buffer_exe_dir_path: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path_exe_dir: []const u8 = try std.fs.selfExeDirPath(&buffer_exe_dir_path);

    var buffer_path_game_lib: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path_game_lib = buildExePathFileName(abs_path_exe_dir, "libsnake.so", &buffer_path_game_lib);

    var buffer_path_game_lib_copy: [std.fs.max_path_bytes]u8 = undefined;
    // This needs to be null terminated for c interop
    const abs_path_game_lib_copy = buildExePathFileName(abs_path_exe_dir, "copy_libsnake.so", &buffer_path_game_lib_copy);

    var game_code = try loadGameCodeLinux(abs_path_game_lib, abs_path_game_lib_copy);

    // NOTE: In debug mode memory returned by page allocator is NOT zero initialized!
    // Use @memset to fix this
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();
    const arena = allocator.allocator();

    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch {
        seed = 92;
    };
    var prng = std.Random.DefaultPrng.init(seed);

    var game_memory: GameMemory = undefined;
    game_memory.rand = prng.random();
    game_memory.is_initialized = false;
    game_memory.permanent_storage.len = megabytes(16);
    game_memory.transient_storage.len = megabytes(8);
    game_memory.cache_transient_storage.len = megabytes(8);

    const total_game_memory_size = (game_memory.permanent_storage.len +
        game_memory.transient_storage.len + game_memory.cache_transient_storage.len);
    const game_memory_block = try arena.alloc(u8, total_game_memory_size);
    @memset(game_memory_block, 0);

    game_memory.permanent_storage.ptr = game_memory_block.ptr;
    game_memory.transient_storage.ptr = game_memory.permanent_storage.ptr + game_memory.permanent_storage.len;
    game_memory.cache_transient_storage.ptr = (game_memory.permanent_storage.ptr +
        game_memory.permanent_storage.len + game_memory.transient_storage.len);

    const backbuffer = PlatformOffscreenBuffer{
        .width = window_width,
        .height = window_height,
        .pitch = window_width * 4,
        .texture = try errify(c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            window_width,
            window_height,
        )),
    };
    defer c.SDL_DestroyTexture(backbuffer.texture);

    var fullscreen = false;

    const target_fps = 60.0;
    const dt = 1.0 / target_fps;

    var input: [2]GameInput = undefined;
    const game_new_input = &input[0];

    main_loop: while (true) {
        const current_write_time = try getFileLastWriteTime(abs_path_game_lib);
        if (current_write_time != game_code.file_last_write_time) {
            unloadGameCodeLinux(&game_code);
            game_code = try loadGameCodeLinux(abs_path_game_lib, abs_path_game_lib_copy);
        }

        game_new_input.delta_time = dt;

        var new_kb_controller = game_API.getController(game_new_input, 0);
        new_kb_controller.* = .init();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    break :main_loop;
                },

                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    const is_down, const is_up = which_event: {
                        if (event.type == c.SDL_EVENT_KEY_DOWN) {
                            break :which_event .{ true, false };
                        } else {
                            break :which_event .{ false, true };
                        }
                    };
                    _ = is_up;

                    // Remove key repeat
                    if (!event.key.repeat) {
                        switch (event.key.scancode) {
                            c.SDL_SCANCODE_W, c.SDL_SCANCODE_UP => {
                                handleKeyboardInput(getButton(&new_kb_controller.buttons, .up), is_down);
                            },

                            c.SDL_SCANCODE_S, c.SDL_SCANCODE_DOWN => {
                                handleKeyboardInput(getButton(&new_kb_controller.buttons, .down), is_down);
                            },

                            c.SDL_SCANCODE_D, c.SDL_SCANCODE_RIGHT => {
                                handleKeyboardInput(getButton(&new_kb_controller.buttons, .right), is_down);
                            },

                            c.SDL_SCANCODE_A, c.SDL_SCANCODE_LEFT => {
                                handleKeyboardInput(getButton(&new_kb_controller.buttons, .left), is_down);
                            },

                            c.SDL_SCANCODE_SPACE => {
                                handleKeyboardInput(getButton(&new_kb_controller.buttons, .pause), is_down);
                            },

                            else => {
                                if (is_down) {
                                    const alt_was_pressed = (c.SDL_GetModState() & c.SDL_KMOD_ALT) != 0;
                                    if (event.key.key == c.SDLK_RETURN and alt_was_pressed) {
                                        _ = c.SDL_SetWindowFullscreen(window, !fullscreen);
                                    }
                                }
                            },
                        }
                    }
                },

                c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN => {
                    fullscreen = true;
                    var width: c_int = 0;
                    var height: c_int = 0;
                    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);
                    print("Enter fullscreen, width: {d}, height: {d}\n", .{ width, height });
                },

                c.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN => {
                    fullscreen = false;
                    var width: c_int = 0;
                    var height: c_int = 0;
                    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);
                    print("Leave fullscreen, width: {d}, height: {d}\n", .{ width, height });
                },

                else => {},
            }
        }

        var game_backbuffer: GameOffscreenBuffer = .{
            .memory = undefined,
            .width = backbuffer.width,
            .height = backbuffer.height,
            .pitch = undefined,
            .bytes_per_pixel = 4,
        };

        try errify(c.SDL_LockTexture(
            backbuffer.texture,
            null,
            @ptrCast(&game_backbuffer.memory),
            &game_backbuffer.pitch,
        ));
        assert(game_backbuffer.pitch == backbuffer.pitch);

        if (game_code.gameUpdateAndRender) |gameUpdateAndRender| {
            gameUpdateAndRender(&game_memory, game_new_input, &game_backbuffer);
        } else {
            print("Callback is null\n", .{});
        }
        c.SDL_UnlockTexture(backbuffer.texture);

        const width: c_int = 0;
        const height: c_int = 0;
        copyBufferToWindow(renderer, width, height, fullscreen, &backbuffer);
    }
}

inline fn kilobytes(n: usize) usize {
    return n * 1024;
}

inline fn megabytes(n: usize) usize {
    return kilobytes(n) * 1024;
}

inline fn gigabytes(n: usize) usize {
    return megabytes(n) * 1024;
}

fn handleKeyboardInput(button: *game_API.ButtonState, is_down: bool) void {
    button.ended_down = is_down;
}

fn getFileLastWriteTime(file_path: [:0]const u8) !i128 {
    const file_handle = try std.fs.openFileAbsolute(file_path, .{});
    defer file_handle.close();
    const metadata = try file_handle.stat();
    return metadata.mtime;
}

const GameCodeLinux = struct {
    file_last_write_time: i128,
    handle: ?*anyopaque,
    gameUpdateAndRender: game_API.UpdateAndRender,
    is_valid: bool,
};

fn unloadGameCodeLinux(game_code: *GameCodeLinux) void {
    if (game_code.is_valid) {
        const err = std.c.dlclose(game_code.handle.?);
        if (err != 0) {
            std.log.debug("Error unloading game code", .{});
        }
        game_code.gameUpdateAndRender = null;
        game_code.is_valid = false;
    }
}

fn loadGameCodeLinux(path_to_game_lib: [:0]const u8, path_to_game_lib_copy: [:0]const u8) !GameCodeLinux {
    var result: GameCodeLinux = undefined;
    var copied_game_lib = true;
    std.fs.copyFileAbsolute(path_to_game_lib, path_to_game_lib_copy, .{}) catch |err| {
        std.log.debug("Failed to copy game library: {}", .{err});
        copied_game_lib = false;
        // TODO: Do we need result.is_valid field?
        result.is_valid = false;
    };

    if (copied_game_lib) {
        result.file_last_write_time = try getFileLastWriteTime(path_to_game_lib);

        result.handle = std.c.dlopen(path_to_game_lib_copy, .{ .NOW = true });
        if (result.handle) |handle| {
            result.gameUpdateAndRender = @ptrCast(std.c.dlsym(handle, "gameUpdateAndRender"));
            result.is_valid = result.gameUpdateAndRender != null;
        } else {
            result.is_valid = false;
            std.log.debug("Unable to open shared library", .{});
        }
    }

    if (!result.is_valid) {
        result.gameUpdateAndRender = null;
    }
    return result;
}

fn copyBufferToWindow(
    renderer: *c.SDL_Renderer,
    window_width: c_int,
    window_height: c_int,
    fullscreen: bool,
    buffer: *const PlatformOffscreenBuffer,
) void {
    _ = window_width;
    _ = window_height;
    _ = fullscreen;

    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_RenderTexture(renderer, buffer.texture, null, null);
    _ = c.SDL_RenderPresent(renderer);
}

fn buildExePathFileName(dir_path: []const u8, file_name: [:0]const u8, buffer: []u8) [:0]const u8 {
    const file_path_len = dir_path.len + file_name.len + 1;
    assert(file_path_len < buffer.len);
    for (0..dir_path.len) |i| {
        buffer[i] = dir_path[i];
    }
    buffer[dir_path.len] = '/';

    for (0..file_name.len, (dir_path.len + 1)..file_path_len) |i, j| {
        buffer[j] = file_name[i];
    }
    buffer[file_path_len] = 0;
    return buffer[0..file_path_len :0];
}

fn fmtSdlDrivers(
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,
) FormatSdlDrivers {
    return .{
        .current_driver = current_driver,
        .num_drivers = num_drivers,
        .getDriver = getDriver,
    };
}

const FormatSdlDrivers = struct {
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,

    pub fn format(context: FormatSdlDrivers, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: c_int = 0;
        while (i < context.num_drivers) : (i += 1) {
            if (i != 0) try writer.writeAll(", ");
            const driver = context.getDriver(i).?;
            try writer.writeAll(std.mem.span(driver));
            if (std.mem.orderZ(u8, context.current_driver, driver) == .eq) {
                try writer.writeAll(" (current)");
            }
        }
    }
};

/// Converts the return of an SDL function to an error union.
inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("Unable to errify type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) value else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}
