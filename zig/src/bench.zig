//! Standalone benchmark executable for testing without Bun FFI

const std = @import("std");
const lib = @import("lib.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    _ = allocator;

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    const file_path = args.next() orelse {
        std.debug.print("Usage: bench <file_path> [num_threads]\n", .{});
        return;
    };

    const num_threads: u32 = if (args.next()) |n|
        std.fmt.parseInt(u32, n, 10) catch 8
    else
        8;

    std.debug.print("Opening file: {s}\n", .{file_path});
    std.debug.print("Using {d} threads\n", .{num_threads});

    // Open file
    const path_z = try std.heap.page_allocator.dupeZ(u8, file_path);
    defer std.heap.page_allocator.free(path_z);

    const handle = lib.onebr_open(path_z) orelse {
        std.debug.print("Failed to open file\n", .{});
        return;
    };
    defer lib.onebr_close(handle);

    // Process
    const station_count = lib.onebr_process(handle, num_threads);
    if (station_count < 0) {
        std.debug.print("Failed to process file\n", .{});
        return;
    }

    std.debug.print("Found {d} unique stations\n", .{station_count});

    // Get JSON output
    var json_len: usize = 0;
    const json_ptr = lib.onebr_get_json(handle, &json_len);
    if (json_ptr) |ptr| {
        const json = ptr[0..json_len];
        // Print first 500 chars
        const preview_len = @min(json_len, 500);
        std.debug.print("\nJSON preview ({d} chars total):\n{s}...\n", .{ json_len, json[0..preview_len] });
    }

    // Get timing
    var timing_len: usize = 0;
    const timing_ptr = lib.onebr_get_timing(handle, &timing_len);
    if (timing_ptr) |ptr| {
        const timing = ptr[0..timing_len];
        std.debug.print("\nTiming:\n{s}\n", .{timing});
    }
}
