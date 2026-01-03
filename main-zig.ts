/**
 * 1 Billion Row Challenge - Zig-accelerated version
 *
 * This uses Bun's FFI to call a high-performance Zig library that:
 * - Uses mmap for zero-copy file reading
 * - Uses SIMD for fast line/delimiter scanning
 * - Uses fixed-point arithmetic for temperature parsing
 * - Uses parallel processing with arena allocation
 */

import { OnebrProcessor } from "./ffi";
import os from "os";

const filePath = process.argv[2];

if (!filePath) {
  console.error("Usage: bun main-zig.ts <file_path> [num_threads]");
  console.error("Example: bun main-zig.ts measurements.txt");
  process.exit(1);
}

const numThreads = process.argv[3]
  ? parseInt(process.argv[3], 10)
  : os.cpus().length;

console.log(`1BR Challenge - Zig Accelerated`);
console.log(`================================`);
console.log(`File: ${filePath}`);
console.log(`Threads: ${numThreads}`);
console.log();

const overallStart = performance.now();

const processor = new OnebrProcessor();

try {
  // Open file
  console.log("Opening file...");
  if (!processor.open(filePath)) {
    console.error("Failed to open file");
    process.exit(1);
  }

  // Process
  console.log("Processing...");
  const stationCount = processor.process(numThreads);

  if (stationCount < 0) {
    console.error("Failed to process file");
    process.exit(1);
  }

  console.log(`Found ${stationCount} unique stations`);

  // Get timing breakdown
  const timing = processor.getTiming();
  console.log();
  console.log("Timing breakdown:");
  console.log(`  mmap:        ${timing.mmap_ms.toFixed(2)} ms`);
  console.log(`  chunk_find:  ${timing.chunk_find_ms.toFixed(2)} ms`);
  console.log(`  process:     ${timing.process_ms.toFixed(2)} ms`);
  console.log(`  merge:       ${timing.merge_ms.toFixed(2)} ms`);
  console.log(`  json:        ${timing.json_ms.toFixed(2)} ms`);
  console.log(`  total (zig): ${timing.total_ms.toFixed(2)} ms`);
  console.log(`  lines:       ${timing.lines.toLocaleString()}`);

  // Get JSON output
  const json = processor.getJson();

  const overallEnd = performance.now();
  const totalSeconds = (overallEnd - overallStart) / 1000;

  console.log();
  console.log(`COMPLETE!`);
  console.log(`Total time (including FFI overhead): ${totalSeconds.toFixed(2)}s`);
  console.log(`Throughput: ${Math.round(timing.lines / totalSeconds).toLocaleString()} rows/second`);

  // Print preview of results
  console.log();
  console.log(`Results preview (first 500 chars):`);
  console.log(json.substring(0, 500) + "...");

  // Optionally write full results to file
  if (process.argv[4] === "--output") {
    const outputPath = process.argv[5] || "results.json";
    await Bun.write(outputPath, json);
    console.log(`\nFull results written to: ${outputPath}`);
  }
} finally {
  processor.close();
}
