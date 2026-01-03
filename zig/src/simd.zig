//! SIMD-accelerated utilities for 1BR parsing
//! Optimized for Apple Silicon (ARM NEON)

const std = @import("std");
const builtin = @import("builtin");

// Apple Silicon uses ARM NEON with 128-bit vectors
const Vec = @Vector(16, u8);
const vec_len = 16;

// Pre-computed masks for common characters
const newline_mask: Vec = @splat('\n');
const semicolon_mask: Vec = @splat(';');

/// Find the next newline character using SIMD
/// Returns the index relative to `start`, or null if not found
pub fn findNewline(data: []const u8, start: usize) ?usize {
    var i = start;

    // SIMD path: process 16 bytes at a time
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const matches = chunk == newline_mask;
        const mask = @as(u16, @bitCast(matches));

        if (mask != 0) {
            return i + @ctz(mask);
        }
        i += vec_len;
    }

    // Scalar fallback for remaining bytes
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            return i;
        }
    }

    return null;
}

/// Find the next semicolon character using SIMD
/// Searches within a bounded range [start, end)
pub fn findSemicolon(data: []const u8, start: usize, end: usize) ?usize {
    const search_end = @min(end, data.len);
    var i = start;

    // SIMD path
    while (i + vec_len <= search_end) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const matches = chunk == semicolon_mask;
        const mask = @as(u16, @bitCast(matches));

        if (mask != 0) {
            const pos = i + @ctz(mask);
            if (pos < search_end) {
                return pos;
            }
            return null;
        }
        i += vec_len;
    }

    // Scalar fallback
    while (i < search_end) : (i += 1) {
        if (data[i] == ';') {
            return i;
        }
    }

    return null;
}

/// Find chunk boundaries aligned to newlines
/// Returns an array of byte offsets where each chunk starts
/// Each chunk boundary is guaranteed to be at the start of a line
pub fn findChunkBoundaries(
    allocator: std.mem.Allocator,
    data: []const u8,
    num_chunks: usize,
) ![]usize {
    var boundaries = try allocator.alloc(usize, num_chunks + 1);
    errdefer allocator.free(boundaries);

    boundaries[0] = 0;
    boundaries[num_chunks] = data.len;

    if (num_chunks == 1) {
        return boundaries;
    }

    const chunk_size = data.len / num_chunks;

    for (1..num_chunks) |i| {
        const target = i * chunk_size;

        // Search backwards from target to find a newline
        // This ensures we don't split a line
        if (findPreviousNewline(data, target)) |newline_pos| {
            // Start chunk after the newline
            boundaries[i] = newline_pos + 1;
        } else {
            // No newline found before target, search forward
            if (findNewline(data, target)) |newline_pos| {
                boundaries[i] = newline_pos + 1;
            } else {
                // No newline at all, use target
                boundaries[i] = target;
            }
        }
    }

    return boundaries;
}

/// Find previous newline searching backwards from `start`
fn findPreviousNewline(data: []const u8, start: usize) ?usize {
    if (start == 0) return null;

    var i = start - 1;

    // For backward search, scalar is simpler and sufficient
    // (we only do this once per chunk, not performance critical)
    while (true) {
        if (data[i] == '\n') {
            return i;
        }
        if (i == 0) break;
        i -= 1;
    }

    return null;
}

/// Count newlines in a range using SIMD
/// Useful for progress reporting
pub fn countNewlines(data: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    // SIMD path
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const matches = chunk == newline_mask;
        const mask = @as(u16, @bitCast(matches));
        count += @popCount(mask);
        i += vec_len;
    }

    // Scalar fallback
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            count += 1;
        }
    }

    return count;
}

// ============================================================================
// TESTS
// ============================================================================

test "findNewline basic" {
    const data = "hello\nworld\n";
    try std.testing.expectEqual(@as(?usize, 5), findNewline(data, 0));
    try std.testing.expectEqual(@as(?usize, 11), findNewline(data, 6));
    try std.testing.expectEqual(@as(?usize, null), findNewline(data, 12));
}

test "findNewline no newline" {
    const data = "hello world";
    try std.testing.expectEqual(@as(?usize, null), findNewline(data, 0));
}

test "findNewline SIMD boundary" {
    // Test with data longer than 16 bytes to trigger SIMD path
    const data = "0123456789abcdef\n0123456789abcdef\n";
    try std.testing.expectEqual(@as(?usize, 16), findNewline(data, 0));
    try std.testing.expectEqual(@as(?usize, 33), findNewline(data, 17));
}

test "findSemicolon basic" {
    const data = "Tokyo;35.2\n";
    try std.testing.expectEqual(@as(?usize, 5), findSemicolon(data, 0, data.len));
}

test "findSemicolon within bounds" {
    const data = "Tokyo;35.2\nOsaka;28.5\n";
    try std.testing.expectEqual(@as(?usize, 5), findSemicolon(data, 0, 10));
    try std.testing.expectEqual(@as(?usize, 16), findSemicolon(data, 11, 22));
}

test "findSemicolon SIMD boundary" {
    // Long station name to trigger SIMD
    const data = "San Francisco Bay Area;22.5\n";
    try std.testing.expectEqual(@as(?usize, 22), findSemicolon(data, 0, data.len));
}

test "countNewlines" {
    const data = "a\nb\nc\nd\n";
    try std.testing.expectEqual(@as(usize, 4), countNewlines(data));
}

test "countNewlines large" {
    // Test with > 16 bytes
    const data = "line1\nline2\nline3\nline4\nline5\n";
    try std.testing.expectEqual(@as(usize, 5), countNewlines(data));
}

test "findChunkBoundaries" {
    const data = "a;1.0\nb;2.0\nc;3.0\nd;4.0\n";
    const allocator = std.testing.allocator;

    const boundaries = try findChunkBoundaries(allocator, data, 2);
    defer allocator.free(boundaries);

    try std.testing.expectEqual(@as(usize, 3), boundaries.len);
    try std.testing.expectEqual(@as(usize, 0), boundaries[0]);
    try std.testing.expectEqual(@as(usize, data.len), boundaries[2]);
    // Middle boundary should be at a line start
    try std.testing.expect(boundaries[1] == 0 or data[boundaries[1] - 1] == '\n');
}
