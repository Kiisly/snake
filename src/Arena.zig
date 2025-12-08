const assert = @import("std").debug.assert;

memory: []u8,
used: MemoryIndex,

pub fn init(memory: []u8) Arena {
    return .{ .memory = memory, .used = 0 };
}

pub fn push(arena: *Arena, T: type) *T {
    const size = @sizeOf(T);
    assert((arena.used + size) <= arena.memory.len);
    const memory: *T = @ptrCast(&arena.memory[arena.used]);
    arena.used += size;
    return memory;
}

pub fn pushMany(arena: *Arena, T: type, count: usize) []T {
    const size = count * @sizeOf(T);
    assert((arena.used + size) <= arena.memory.len);
    const memory: []T = @ptrCast(@alignCast(arena.memory[arena.used..size]));
    arena.used += size;
    return memory;
}

const Arena = @This();
const MemoryIndex = usize;
