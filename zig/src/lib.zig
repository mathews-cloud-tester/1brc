//! 1BR Challenge - Zig FFI Library
//! ================================
//!
//! High-performance parsing library for the 1 Billion Row Challenge,
//! designed to be called from Bun/TypeScript via FFI (Foreign Function Interface).
//!
//! ## Architecture Overview
//!
//! ```
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │                           Bun/TypeScript                                │
//! │                         (main-zig.ts, ffi.ts)                           │
//! └─────────────────────────────────────────────────────────────────────────┘
//!                                    │
//!                              FFI calls via dlopen
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │                         This Library (lib.zig)                          │
//! │                                                                         │
//! │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 │
//! │  │  onebr_open │───▶│onebr_process│───▶│onebr_get_*  │                 │
//! │  │   (mmap)    │    │ (parallel)  │    │  (results)  │                 │
//! │  └─────────────┘    └─────────────┘    └─────────────┘                 │
//! │         │                  │                                            │
//! │         ▼                  ▼                                            │
//! │  ┌─────────────┐    ┌─────────────────────────────────┐                │
//! │  │  simd.zig   │    │         parser.zig              │                │
//! │  │ (scanning)  │    │ (temperature parsing, stats)    │                │
//! │  └─────────────┘    └─────────────────────────────────┘                │
//! └─────────────────────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Key Performance Techniques
//!
//! 1. **mmap (Memory-Mapped File I/O)**
//!    - File is mapped directly into virtual address space
//!    - No read() syscalls, no buffer copies
//!    - OS kernel handles paging and caching automatically
//!    - Second run is ~4x faster due to OS page cache (data already in RAM)
//!
//! 2. **SIMD Scanning** (see simd.zig)
//!    - Uses ARM NEON 128-bit vectors on Apple Silicon
//!    - Scans 16 bytes at once for newlines and semicolons
//!    - ~8-16x faster than byte-by-byte scanning
//!
//! 3. **Fixed-Point Arithmetic** (see parser.zig)
//!    - Temperatures stored as i16 (multiply by 10)
//!    - "-12.3" → -123, "45.6" → 456
//!    - Avoids all floating-point operations during parsing
//!
//! 4. **Parallel Processing with Native Threads**
//!    - Uses std.Thread for true parallel execution
//!    - File divided into N chunks (one per CPU core)
//!    - Each thread processes its chunk independently
//!    - Results merged at the end
//!
//! 5. **Arena Allocation**
//!    - Thread-local arenas for temporary allocations
//!    - One deinit() frees everything when thread completes
//!    - No individual malloc/free overhead, no GC pauses
//!

const std = @import("std");
const simd = @import("simd.zig");
const parser = @import("parser.zig");

const StationStats = parser.StationStats;

// ============================================================================
// TIMING / INSTRUMENTATION
// ============================================================================

/// Timing breakdown for performance analysis.
/// All values are in nanoseconds for precision, converted to milliseconds on output.
const Timing = struct {
    /// Time spent setting up the memory mapping (typically ~100ms for 13GB file)
    mmap_ns: u64 = 0,

    /// Time spent finding chunk boundaries using SIMD newline scanning
    /// (typically <1ms - very fast due to SIMD)
    chunk_find_ns: u64 = 0,

    /// Time spent in parallel processing (the main work)
    /// This is where SIMD scanning, temperature parsing, and stats aggregation happen
    process_ns: u64 = 0,

    /// Time spent merging results from all threads into the final map
    /// (typically <10ms - just HashMap operations)
    merge_ns: u64 = 0,

    /// Time spent generating JSON output (lazy - only when requested)
    json_ns: u64 = 0,

    /// Total wall-clock time from start to finish
    total_ns: u64 = 0,

    /// Total number of lines (rows) processed across all threads
    lines_processed: u64 = 0,
};

// ============================================================================
// HANDLE STRUCTURE
// ============================================================================

/// Opaque handle representing an open 1BR processing session.
///
/// This struct is allocated on the heap and returned to the caller as a pointer.
/// The caller must call onebr_close() to free all resources.
///
/// ## Memory Layout
///
/// ```
/// OnebrHandle (heap-allocated)
///     │
///     ├── data ──────────────▶ [mmap'd file: 13GB virtual address space]
///     │                        (pages loaded on-demand by OS kernel)
///     │
///     ├── results ───────────▶ HashMap<station_name, StationStats>
///     │                        Keys: heap-allocated copies of station names
///     │                        Values: inline StationStats structs
///     │
///     ├── sorted_keys ───────▶ [array of pointers to keys in results]
///     │                        (for alphabetical JSON output)
///     │
///     ├── json_output ───────▶ [heap-allocated JSON string]
///     │                        (lazily generated on first request)
///     │
///     └── timing_output ─────▶ [heap-allocated timing JSON string]
/// ```
const OnebrHandle = struct {
    // ========================================================================
    // FILE DATA (mmap'd)
    // ========================================================================

    /// Memory-mapped file data.
    ///
    /// This is NOT a copy of the file - it's a view into the kernel's page cache.
    /// When we access bytes, the OS transparently pages them in from disk (or RAM
    /// if already cached). The alignment is required by mmap.
    ///
    /// IMPORTANT: This data is read-only and must not be modified.
    /// The .PRIVATE flag means writes would create copy-on-write pages,
    /// but we never write so this doesn't matter.
    data: []align(std.heap.page_size_min) const u8,

    /// Original file size in bytes (for reference)
    file_size: usize,

    // ========================================================================
    // MEMORY MANAGEMENT
    // ========================================================================

    /// Allocator for long-lived data (station name keys, JSON output, etc.)
    /// We use page_allocator for simplicity and to avoid any GC overhead.
    allocator: std.mem.Allocator,

    // ========================================================================
    // RESULTS
    // ========================================================================

    /// Aggregated statistics per station.
    ///
    /// Key: station name (heap-allocated copy, since mmap data goes away on close)
    /// Value: StationStats { min, max, sum, count } using fixed-point i16 temps
    ///
    /// After processing 1 billion rows, this typically contains ~400 entries
    /// (one per unique station in the dataset).
    results: std.StringHashMap(StationStats),

    /// Sorted array of station names for alphabetical JSON output.
    /// Populated lazily when onebr_get_json() is first called.
    sorted_keys: [][]const u8,

    // ========================================================================
    // OUTPUT BUFFERS (lazily populated)
    // ========================================================================

    /// Cached JSON output string.
    /// Generated once on first call to onebr_get_json(), then reused.
    /// Format: {"StationA":{"min":1.2,"max":3.4,"mean":2.3},...}
    json_output: ?[]u8,

    /// Cached timing JSON string.
    /// Generated once on first call to onebr_get_timing(), then reused.
    timing_output: ?[]u8,

    // ========================================================================
    // INSTRUMENTATION
    // ========================================================================

    /// Timing breakdown for performance analysis
    timing: Timing,

    // ========================================================================
    // CLEANUP
    // ========================================================================

    /// Release all resources associated with this handle.
    ///
    /// This function:
    /// 1. Frees the sorted_keys array
    /// 2. Frees the JSON output buffer
    /// 3. Frees the timing output buffer
    /// 4. Frees all station name keys in the results HashMap
    /// 5. Deinitializes the HashMap itself
    /// 6. Unmaps the file (releases virtual address space)
    /// 7. Frees the handle struct itself
    ///
    /// After this call, the handle pointer is invalid and must not be used.
    fn deinit(self: *OnebrHandle) void {
        // Free sorted keys array (but not the keys themselves - they're in results)
        if (self.sorted_keys.len > 0) {
            self.allocator.free(self.sorted_keys);
        }

        // Free JSON output buffer
        if (self.json_output) |json| {
            self.allocator.free(json);
        }

        // Free timing output buffer
        if (self.timing_output) |timing| {
            self.allocator.free(timing);
        }

        // Free station name keys (these are heap-allocated copies)
        // We need to do this because the original names point into mmap'd memory
        // which will be unmapped below
        var iter = self.results.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.results.deinit();

        // Unmap the file - this releases the virtual address space
        // The actual file data may remain in the OS page cache for future use
        std.posix.munmap(self.data);

        // Free the handle struct itself
        self.allocator.destroy(self);
    }
};

// ============================================================================
// C API EXPORTS
// ============================================================================
//
// These functions are exported with C ABI for FFI compatibility.
// They use simple types (pointers, integers) that are easy to marshal.
//
// The `export` keyword makes these symbols visible in the shared library.
// The `pub` keyword allows them to also be called from Zig code (e.g., bench.zig).

/// Global allocator used for all heap allocations.
/// We use page_allocator because:
/// 1. It's simple and has no overhead
/// 2. We don't need the complexity of a general-purpose allocator
/// 3. Our allocations are large and long-lived
var global_allocator: std.mem.Allocator = std.heap.page_allocator;

/// Open a file for processing using mmap.
///
/// ## How mmap Works
///
/// ```
/// Traditional read():                    mmap():
/// ┌─────────┐                           ┌─────────┐
/// │  Disk   │                           │  Disk   │
/// └────┬────┘                           └────┬────┘
///      │ read() syscall                      │ page fault
///      ▼                                     ▼
/// ┌─────────┐                           ┌─────────┐
/// │ Kernel  │                           │ Kernel  │
/// │ Buffer  │                           │  Page   │
/// └────┬────┘                           │  Cache  │
///      │ copy to userspace              └────┬────┘
///      ▼                                     │ direct mapping
/// ┌─────────┐                                ▼
/// │ User    │                           ┌─────────┐
/// │ Buffer  │                           │ Virtual │
/// └─────────┘                           │ Address │
///                                       │  Space  │
///   2 copies!                           └─────────┘
///                                         0 copies!
/// ```
///
/// With mmap, the kernel maps the file directly into our address space.
/// When we access a byte, if it's not in RAM, a page fault occurs and
/// the kernel loads just that 16KB page from disk. This is "zero-copy"
/// because data never moves through an intermediate buffer.
///
/// ## Parameters
/// - path_ptr: Null-terminated C string containing the file path
///
/// ## Returns
/// - Pointer to OnebrHandle on success
/// - null on failure (file not found, mmap failed, etc.)
///
/// ## Example (from TypeScript via FFI)
/// ```typescript
/// const handle = symbols.onebr_open(Buffer.from("measurements.txt\0"));
/// if (!handle) throw new Error("Failed to open file");
/// ```
pub export fn onebr_open(path_ptr: [*:0]const u8) ?*OnebrHandle {
    // Start timing the mmap operation
    var timer = std.time.Timer.start() catch return null;

    // Convert null-terminated C string to Zig slice
    const path = std.mem.span(path_ptr);

    // Open the file (we only need it briefly to get the fd for mmap)
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close(); // Close fd after mmap - the mapping persists

    // Get file size for mmap
    const stat = file.stat() catch return null;
    const file_size = stat.size;

    // Memory map the file
    //
    // Arguments:
    // - null: let the kernel choose the address
    // - file_size: map the entire file
    // - PROT.READ: we only need read access
    // - .PRIVATE: changes are not written back (copy-on-write, but we don't write)
    // - file.handle: the file descriptor
    // - 0: offset from start of file
    //
    // This returns immediately - no data is read yet!
    // Data is loaded on-demand when we access it (page faults).
    const data = std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    ) catch return null;

    // Allocate the handle struct on the heap
    const handle = global_allocator.create(OnebrHandle) catch {
        // If allocation fails, unmap the file before returning
        std.posix.munmap(data);
        return null;
    };

    // Initialize all fields
    handle.* = .{
        .data = data,
        .file_size = file_size,
        .allocator = global_allocator,
        .results = std.StringHashMap(StationStats).init(global_allocator),
        .sorted_keys = &[_][]const u8{}, // Empty slice, populated later
        .json_output = null, // Lazy
        .timing_output = null, // Lazy
        .timing = .{
            .mmap_ns = timer.read(), // Record mmap time
        },
    };

    return handle;
}

/// Process the file in parallel using multiple threads.
///
/// ## Processing Pipeline
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         Step 1: Find Chunk Boundaries                   │
/// │                                                                         │
/// │  File: [==========|==========|==========|==========]                   │
/// │                   ↑          ↑          ↑                              │
/// │              newline     newline    newline                            │
/// │                                                                         │
/// │  We use SIMD to quickly find newlines near the chunk boundaries.       │
/// │  This ensures each chunk contains complete lines (no line splitting).  │
/// └─────────────────────────────────────────────────────────────────────────┘
///                                    │
///                                    ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                      Step 2: Parallel Processing                        │
/// │                                                                         │
/// │  Thread 0          Thread 1          Thread 2          Thread 3        │
/// │  ┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐       │
/// │  │ Chunk 0 │      │ Chunk 1 │      │ Chunk 2 │      │ Chunk 3 │       │
/// │  │         │      │         │      │         │      │         │       │
/// │  │ SIMD    │      │ SIMD    │      │ SIMD    │      │ SIMD    │       │
/// │  │ scan    │      │ scan    │      │ scan    │      │ scan    │       │
/// │  │   +     │      │   +     │      │   +     │      │   +     │       │
/// │  │ Parse   │      │ Parse   │      │ Parse   │      │ Parse   │       │
/// │  │   +     │      │   +     │      │   +     │      │   +     │       │
/// │  │ Stats   │      │ Stats   │      │ Stats   │      │ Stats   │       │
/// │  └────┬────┘      └────┬────┘      └────┬────┘      └────┬────┘       │
/// │       │                │                │                │            │
/// │       ▼                ▼                ▼                ▼            │
/// │  Local HashMap   Local HashMap   Local HashMap   Local HashMap       │
/// └─────────────────────────────────────────────────────────────────────────┘
///                                    │
///                                    ▼
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         Step 3: Merge Results                           │
/// │                                                                         │
/// │  All thread-local HashMaps are merged into the final results map.      │
/// │  For each station: min = min(all mins), max = max(all maxs),           │
/// │                    sum = sum(all sums), count = sum(all counts)        │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Parameters
/// - handle: Pointer to OnebrHandle from onebr_open()
/// - num_threads: Number of threads to use (capped at 16)
///
/// ## Returns
/// - Number of unique stations found (typically ~400)
/// - -1 on error
pub export fn onebr_process(handle: ?*OnebrHandle, num_threads: u32) i32 {
    const h = handle orelse return -1;

    // Start overall timer
    var total_timer = std.time.Timer.start() catch return -1;

    // Cap threads at 16 (our static thread array size)
    const actual_threads: usize = @min(num_threads, 16);
    if (actual_threads == 0) return -1;

    // ========================================================================
    // STEP 1: FIND CHUNK BOUNDARIES
    // ========================================================================
    //
    // We need to divide the file into N chunks, but we can't just split at
    // arbitrary byte positions - that would cut lines in half!
    //
    // Solution: Use SIMD to find newlines near each target boundary,
    // then adjust the boundary to the nearest newline.

    var chunk_timer = std.time.Timer.start() catch return -1;
    const boundaries = simd.findChunkBoundaries(
        h.allocator,
        h.data,
        actual_threads,
    ) catch return -1;
    defer h.allocator.free(boundaries);
    h.timing.chunk_find_ns = chunk_timer.read();

    // ========================================================================
    // STEP 2: PARALLEL PROCESSING
    // ========================================================================

    var process_timer = std.time.Timer.start() catch return -1;

    if (actual_threads == 1) {
        // Single-threaded path (simpler, no thread overhead)
        const lines = parser.processChunk(
            h.data,
            boundaries[0],
            boundaries[1],
            &h.results,
            h.allocator,
        ) catch return -1;
        h.timing.lines_processed = lines;
    } else {
        // Multi-threaded path

        // Context struct passed to each thread
        // Each thread gets its own HashMap to avoid lock contention
        const ThreadContext = struct {
            data: []const u8, // Pointer to mmap'd data (shared, read-only)
            start: usize, // Start byte offset for this chunk
            end: usize, // End byte offset for this chunk
            stats: std.StringHashMap(StationStats), // Thread-local results
            lines: usize, // Lines processed by this thread
            allocator: std.mem.Allocator, // Allocator for station name keys
        };

        // Allocate context structs for all threads
        var contexts = h.allocator.alloc(ThreadContext, actual_threads) catch return -1;
        defer h.allocator.free(contexts);

        // Initialize each thread's context
        for (0..actual_threads) |i| {
            contexts[i] = .{
                .data = h.data,
                .start = boundaries[i],
                .end = boundaries[i + 1],
                .stats = std.StringHashMap(StationStats).init(h.allocator),
                .lines = 0,
                .allocator = h.allocator,
            };
        }

        // Worker function that each thread executes
        const worker = struct {
            fn run(ctx: *ThreadContext) void {
                // Create a thread-local arena for temporary allocations
                // This is freed automatically when the thread completes
                // (though we don't actually use it currently - keys go to main allocator)
                var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                defer arena.deinit();

                // Process this thread's chunk
                // This does SIMD scanning + temperature parsing + stats aggregation
                ctx.lines = parser.processChunk(
                    ctx.data,
                    ctx.start,
                    ctx.end,
                    &ctx.stats,
                    ctx.allocator, // Keys need to survive for merge, so use main allocator
                ) catch 0;
            }
        }.run;

        // Spawn all threads
        var threads: [16]?std.Thread = [_]?std.Thread{null} ** 16;
        for (0..actual_threads) |i| {
            threads[i] = std.Thread.spawn(.{}, worker, .{&contexts[i]}) catch null;
        }

        // Wait for all threads to complete
        for (0..actual_threads) |i| {
            if (threads[i]) |thread| {
                thread.join();
            }
        }

        h.timing.process_ns = process_timer.read();

        // ====================================================================
        // STEP 3: MERGE RESULTS
        // ====================================================================
        //
        // Combine all thread-local HashMaps into the final results map.
        // For each station that appears in multiple threads:
        // - min = minimum of all thread mins
        // - max = maximum of all thread maxs
        // - sum = sum of all thread sums
        // - count = sum of all thread counts

        var merge_timer = std.time.Timer.start() catch return -1;
        var total_lines: usize = 0;

        for (0..actual_threads) |i| {
            total_lines += contexts[i].lines;

            // Merge this thread's stats into the main results
            parser.mergeStats(&h.results, &contexts[i].stats, h.allocator) catch {};

            // Free thread-local HashMap
            // Note: We need to be careful about the keys - they might have been
            // moved to the main results map during merge
            var iter = contexts[i].stats.keyIterator();
            while (iter.next()) |key| {
                // Only free if this key is NOT in the main results
                // (meaning it was already there and the merge used the existing key)
                if (h.results.get(key.*) == null) {
                    h.allocator.free(key.*);
                }
            }
            contexts[i].stats.deinit();
        }

        h.timing.lines_processed = total_lines;
        h.timing.merge_ns = merge_timer.read();
    }

    h.timing.total_ns = total_timer.read();

    // Return the number of unique stations found
    return @intCast(h.results.count());
}

/// Get the number of unique stations in the results.
///
/// ## Returns
/// - Number of unique stations (typically ~400 for the 1BR dataset)
/// - 0 if handle is null
pub export fn onebr_result_count(handle: ?*OnebrHandle) u32 {
    const h = handle orelse return 0;
    return @intCast(h.results.count());
}

/// Generate JSON output and return a pointer to it.
///
/// The JSON is formatted as:
/// ```json
/// {"Abha":{"min":-35.8,"max":66.5,"mean":18.0},"Abidjan":{"min":-25.6,...},...}
/// ```
///
/// Station names are sorted alphabetically.
///
/// ## Memory Management
/// The returned pointer points to memory owned by the handle.
/// The caller must NOT free this memory - it will be freed when onebr_close() is called.
/// The same pointer is returned on subsequent calls (cached).
///
/// ## Parameters
/// - handle: Pointer to OnebrHandle
/// - out_len: Output parameter for the length of the JSON string
///
/// ## Returns
/// - Pointer to the JSON string on success
/// - null on error
pub export fn onebr_get_json(handle: ?*OnebrHandle, out_len: *usize) ?[*]const u8 {
    const h = handle orelse return null;

    // Return cached JSON if we've already generated it
    if (h.json_output) |json| {
        out_len.* = json.len;
        return json.ptr;
    }

    var json_timer = std.time.Timer.start() catch return null;

    // ========================================================================
    // STEP 1: SORT STATION NAMES ALPHABETICALLY
    // ========================================================================

    var keys = h.allocator.alloc([]const u8, h.results.count()) catch return null;
    var i: usize = 0;
    var iter = h.results.keyIterator();
    while (iter.next()) |key| {
        keys[i] = key.*;
        i += 1;
    }

    // Sort using lexicographic comparison
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    h.sorted_keys = keys;

    // ========================================================================
    // STEP 2: BUILD JSON STRING
    // ========================================================================

    var json_buf: std.ArrayList(u8) = .empty;
    errdefer json_buf.deinit(h.allocator);

    json_buf.append(h.allocator, '{') catch return null;

    for (keys, 0..) |key, idx| {
        if (idx > 0) {
            json_buf.append(h.allocator, ',') catch return null;
        }

        const stats = h.results.get(key).?;
        // formatStationJson writes: "StationName":{"min":X,"max":Y,"mean":Z}
        parser.formatStationJson(json_buf.writer(h.allocator), key, stats) catch return null;
    }

    json_buf.append(h.allocator, '}') catch return null;

    // Convert to owned slice and cache it
    h.json_output = json_buf.toOwnedSlice(h.allocator) catch return null;
    h.timing.json_ns = json_timer.read();

    out_len.* = h.json_output.?.len;
    return h.json_output.?.ptr;
}

/// Get timing information as a JSON string.
///
/// Returns timing breakdown in milliseconds:
/// ```json
/// {"mmap_ms":99.25,"chunk_find_ms":0.06,"process_ms":3774.70,"merge_ms":1.04,"json_ms":0.37,"total_ms":3875.42,"lines":1000000000}
/// ```
///
/// ## Memory Management
/// Same as onebr_get_json - memory is owned by the handle.
pub export fn onebr_get_timing(handle: ?*OnebrHandle, out_len: *usize) ?[*]const u8 {
    const h = handle orelse return null;

    // Return cached timing if we've already generated it
    if (h.timing_output) |timing| {
        out_len.* = timing.len;
        return timing.ptr;
    }

    // Format timing as JSON
    // We use a stack buffer first, then copy to heap for stability
    var buf: [512]u8 = undefined;
    const timing_json = std.fmt.bufPrint(&buf,
        \\{{"mmap_ms":{d:.2},"chunk_find_ms":{d:.2},"process_ms":{d:.2},"merge_ms":{d:.2},"json_ms":{d:.2},"total_ms":{d:.2},"lines":{d}}}
    , .{
        @as(f64, @floatFromInt(h.timing.mmap_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(h.timing.chunk_find_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(h.timing.process_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(h.timing.merge_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(h.timing.json_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(h.timing.total_ns)) / 1_000_000.0,
        h.timing.lines_processed,
    }) catch return null;

    // Copy to heap-allocated buffer so it survives after this function returns
    // (The stack buffer would be invalid after return)
    h.timing_output = h.allocator.dupe(u8, timing_json) catch return null;
    out_len.* = h.timing_output.?.len;
    return h.timing_output.?.ptr;
}

/// Close the handle and free all resources.
///
/// This must be called when you're done with the handle.
/// After this call, the handle pointer is invalid.
///
/// ## What Gets Freed
/// - The mmap'd file (virtual address space released)
/// - All station name strings
/// - The results HashMap
/// - The JSON output buffer
/// - The timing output buffer
/// - The sorted keys array
/// - The handle struct itself
pub export fn onebr_close(handle: ?*OnebrHandle) void {
    if (handle) |h| {
        h.deinit();
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "open and close" {
    // This test requires a test file - skipped in unit tests
    // Integration testing is done via bench.zig
}

test "parser integration" {
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
    const lines = try parser.processChunk(data, 0, data.len, &stats, allocator);

    try std.testing.expectEqual(@as(usize, 3), lines);
    try std.testing.expectEqual(@as(usize, 2), stats.count());
}
