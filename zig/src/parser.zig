//! Parsing utilities for 1BR challenge
//! Uses fixed-point arithmetic for temperatures (multiply by 10)

const std = @import("std");
const simd = @import("simd.zig");

/// Station statistics using fixed-point arithmetic
/// All temperature values are multiplied by 10 (e.g., 23.5 -> 235)
pub const StationStats = struct {
    min: i16, // temperature * 10
    max: i16,
    sum: i64,
    count: u64,

    pub fn init(temp: i16) StationStats {
        return .{
            .min = temp,
            .max = temp,
            .sum = temp,
            .count = 1,
        };
    }

    pub fn update(self: *StationStats, temp: i16) void {
        if (temp < self.min) self.min = temp;
        if (temp > self.max) self.max = temp;
        self.sum += temp;
        self.count += 1;
    }

    pub fn merge(self: *StationStats, other: StationStats) void {
        if (other.min < self.min) self.min = other.min;
        if (other.max > self.max) self.max = other.max;
        self.sum += other.sum;
        self.count += other.count;
    }
};

/// Parse a temperature value from bytes
/// Input: "-12.3" or "45.6" or "0.0"
/// Output: fixed-point i16 (-123, 456, 0)
pub fn parseTemperature(data: []const u8) i16 {
    if (data.len == 0) return 0;

    var i: usize = 0;
    var negative = false;
    var result: i16 = 0;

    // Check for negative sign
    if (data[0] == '-') {
        negative = true;
        i = 1;
    }

    // Parse integer part
    while (i < data.len and data[i] != '.') : (i += 1) {
        result = result * 10 + @as(i16, @intCast(data[i] - '0'));
    }

    // Skip decimal point
    if (i < data.len and data[i] == '.') {
        i += 1;
    }

    // Parse single decimal digit
    if (i < data.len and data[i] >= '0' and data[i] <= '9') {
        result = result * 10 + @as(i16, @intCast(data[i] - '0'));
    } else {
        // No decimal digit, multiply by 10 to maintain scale
        result = result * 10;
    }

    return if (negative) -result else result;
}

/// Process a single line and update the stats map
/// Line format: "StationName;Temperature\n"
pub fn processLine(
    data: []const u8,
    line_start: usize,
    line_end: usize,
    stats: *std.StringHashMap(StationStats),
    allocator: std.mem.Allocator,
) !void {
    const line_len = line_end - line_start;
    if (line_len == 0) return;

    // Find semicolon
    const semicolon_pos = simd.findSemicolon(data, line_start, line_end) orelse return;

    // Extract station name
    const station_name = data[line_start..semicolon_pos];

    // Parse temperature (everything after semicolon until line end)
    const temp_start = semicolon_pos + 1;
    const temp_data = data[temp_start..line_end];
    const temperature = parseTemperature(temp_data);

    // Update stats
    const result = stats.getOrPut(station_name) catch return;
    if (result.found_existing) {
        result.value_ptr.update(temperature);
    } else {
        // Need to duplicate the key since data is from mmap
        result.key_ptr.* = allocator.dupe(u8, station_name) catch {
            _ = stats.remove(station_name);
            return;
        };
        result.value_ptr.* = StationStats.init(temperature);
    }
}

/// Process a chunk of data (from start to end byte positions)
/// This is the main workhorse function called by each thread
pub fn processChunk(
    data: []const u8,
    chunk_start: usize,
    chunk_end: usize,
    stats: *std.StringHashMap(StationStats),
    allocator: std.mem.Allocator,
) !usize {
    var line_start = chunk_start;
    var lines_processed: usize = 0;

    while (line_start < chunk_end) {
        // Find end of line
        const newline_pos = simd.findNewline(data, line_start) orelse chunk_end;
        const line_end = @min(newline_pos, chunk_end);

        if (line_end > line_start) {
            try processLine(data, line_start, line_end, stats, allocator);
            lines_processed += 1;
        }

        // Move to next line
        line_start = if (newline_pos < chunk_end) newline_pos + 1 else chunk_end;
    }

    return lines_processed;
}

/// Merge stats from source into destination
pub fn mergeStats(
    dest: *std.StringHashMap(StationStats),
    source: *std.StringHashMap(StationStats),
    allocator: std.mem.Allocator,
) !void {
    var iter = source.iterator();
    while (iter.next()) |entry| {
        const result = try dest.getOrPut(entry.key_ptr.*);
        if (result.found_existing) {
            result.value_ptr.merge(entry.value_ptr.*);
        } else {
            // Duplicate the key for the destination map
            result.key_ptr.* = try allocator.dupe(u8, entry.key_ptr.*);
            result.value_ptr.* = entry.value_ptr.*;
        }
    }
}

/// Convert fixed-point temperature to float for output
pub fn tempToFloat(temp: i16) f64 {
    return @as(f64, @floatFromInt(temp)) / 10.0;
}

/// Format a single station result as JSON
pub fn formatStationJson(
    writer: anytype,
    name: []const u8,
    stats: StationStats,
) !void {
    const min_f = tempToFloat(stats.min);
    const max_f = tempToFloat(stats.max);
    const mean_f = @as(f64, @floatFromInt(stats.sum)) / @as(f64, @floatFromInt(stats.count)) / 10.0;

    try writer.print("\"{s}\":{{\"min\":{d:.1},\"max\":{d:.1},\"mean\":{d:.1}}}", .{
        name,
        min_f,
        max_f,
        mean_f,
    });
}

// ============================================================================
// TESTS
// ============================================================================

test "parseTemperature positive" {
    try std.testing.expectEqual(@as(i16, 235), parseTemperature("23.5"));
    try std.testing.expectEqual(@as(i16, 0), parseTemperature("0.0"));
    try std.testing.expectEqual(@as(i16, 999), parseTemperature("99.9"));
    try std.testing.expectEqual(@as(i16, 10), parseTemperature("1.0"));
    try std.testing.expectEqual(@as(i16, 5), parseTemperature("0.5"));
}

test "parseTemperature negative" {
    try std.testing.expectEqual(@as(i16, -235), parseTemperature("-23.5"));
    try std.testing.expectEqual(@as(i16, -999), parseTemperature("-99.9"));
    try std.testing.expectEqual(@as(i16, -10), parseTemperature("-1.0"));
    try std.testing.expectEqual(@as(i16, -5), parseTemperature("-0.5"));
}

test "StationStats init and update" {
    var stats = StationStats.init(100);
    try std.testing.expectEqual(@as(i16, 100), stats.min);
    try std.testing.expectEqual(@as(i16, 100), stats.max);
    try std.testing.expectEqual(@as(i64, 100), stats.sum);
    try std.testing.expectEqual(@as(u64, 1), stats.count);

    stats.update(50);
    try std.testing.expectEqual(@as(i16, 50), stats.min);
    try std.testing.expectEqual(@as(i16, 100), stats.max);
    try std.testing.expectEqual(@as(i64, 150), stats.sum);
    try std.testing.expectEqual(@as(u64, 2), stats.count);

    stats.update(200);
    try std.testing.expectEqual(@as(i16, 50), stats.min);
    try std.testing.expectEqual(@as(i16, 200), stats.max);
    try std.testing.expectEqual(@as(i64, 350), stats.sum);
    try std.testing.expectEqual(@as(u64, 3), stats.count);
}

test "StationStats merge" {
    var stats1 = StationStats.init(100);
    stats1.update(50);

    var stats2 = StationStats.init(200);
    stats2.update(25);

    stats1.merge(stats2);
    try std.testing.expectEqual(@as(i16, 25), stats1.min);
    try std.testing.expectEqual(@as(i16, 200), stats1.max);
    try std.testing.expectEqual(@as(i64, 375), stats1.sum);
    try std.testing.expectEqual(@as(u64, 4), stats1.count);
}

test "processLine" {
    const allocator = std.testing.allocator;
    var stats = std.StringHashMap(StationStats).init(allocator);
    defer {
        var iter = stats.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        stats.deinit();
    }

    const data = "Tokyo;35.2\nOsaka;28.5\nTokyo;30.0\n";

    try processLine(data, 0, 10, &stats, allocator);
    try processLine(data, 11, 21, &stats, allocator);
    try processLine(data, 22, 32, &stats, allocator);

    try std.testing.expectEqual(@as(usize, 2), stats.count());

    const tokyo = stats.get("Tokyo").?;
    try std.testing.expectEqual(@as(i16, 300), tokyo.min);
    try std.testing.expectEqual(@as(i16, 352), tokyo.max);
    try std.testing.expectEqual(@as(u64, 2), tokyo.count);

    const osaka = stats.get("Osaka").?;
    try std.testing.expectEqual(@as(i16, 285), osaka.min);
    try std.testing.expectEqual(@as(i16, 285), osaka.max);
    try std.testing.expectEqual(@as(u64, 1), osaka.count);
}

test "processChunk" {
    const allocator = std.testing.allocator;
    var stats = std.StringHashMap(StationStats).init(allocator);
    defer {
        var iter = stats.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        stats.deinit();
    }

    const data = "Tokyo;35.2\nOsaka;28.5\nKyoto;22.0\n";

    const lines = try processChunk(data, 0, data.len, &stats, allocator);
    try std.testing.expectEqual(@as(usize, 3), lines);
    try std.testing.expectEqual(@as(usize, 3), stats.count());
}

test "tempToFloat" {
    try std.testing.expectApproxEqRel(@as(f64, 23.5), tempToFloat(235), 0.01);
    try std.testing.expectApproxEqRel(@as(f64, -12.3), tempToFloat(-123), 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 0.0), tempToFloat(0), 0.01);
}
