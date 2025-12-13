const std = @import("std");
const assert = std.debug.assert;

const Arena = @import("Arena.zig");

/// Generic queue initialized with static size
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const MemoryIndex = usize;

        head: MemoryIndex,
        tail: MemoryIndex,
        size: MemoryIndex,
        items: []T,

        pub fn init(arena: *Arena, count: MemoryIndex) Self {
            return .{
                .head = 0,
                .tail = 0,
                .size = 0,
                .items = arena.pushMany(T, count),
            };
        }

        pub fn enqueue(queue: *Self, item: T) void {
            assert(!queue.isFull());
            queue.items[queue.tail] = item;
            queue.tail += 1;
            queue.tail %= queue.items.len;
            queue.size += 1;
        }

        pub fn dequeue(queue: *Self) T {
            assert(!queue.isEmpty());
            const result = queue.items[queue.head];
            queue.head += 1;
            queue.head %= queue.items.len;
            queue.size -= 1;
            return result;
        }

        pub fn get(queue: *const Self, index: MemoryIndex) T {
            assert(!queue.isEmpty());
            const queue_index = (queue.head + index) % queue.items.len;
            return queue.items[queue_index];
        }

        pub fn isFull(queue: *const Self) bool {
            return ((queue.head == queue.tail + 1) or
                ((queue.head == 0) and (queue.tail + 1 == queue.items.len)));
        }

        pub fn isEmpty(queue: *const Self) bool {
            return queue.head == queue.tail;
        }

        pub fn iterator(queue: *const Self) struct {
            head: MemoryIndex,
            tail: MemoryIndex,
            items: []T,

            const Iterator = @This();
            pub fn next(it: *Iterator) ?T {
                if (it.head == it.tail) return null;
                const result = it.items[it.head];
                it.head += 1;
                it.head %= it.items.len;
                return result;
            }
        } {
            return .{ .head = queue.head, .tail = queue.tail, .items = queue.items };
        }
    };
}
