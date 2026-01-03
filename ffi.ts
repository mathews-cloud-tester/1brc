/**
 * Bun FFI bindings for the Zig 1BR library
 *
 * This module provides TypeScript bindings to call the high-performance
 * Zig parsing library via Bun's FFI interface.
 */

import { dlopen, FFIType, ptr, toArrayBuffer, suffix } from "bun:ffi";
import { existsSync } from "fs";
import { join, dirname } from "path";

// Find the library path
function findLibrary(): string {
  const candidates = [
    // Relative to this file
    join(dirname(import.meta.path), "zig", "zig-out", "lib", `lib1br.${suffix}`),
    // From project root
    join(process.cwd(), "zig", "zig-out", "lib", `lib1br.${suffix}`),
  ];

  for (const path of candidates) {
    if (existsSync(path)) {
      return path;
    }
  }

  throw new Error(
    `Could not find lib1br library. Searched:\n${candidates.join("\n")}\n\nRun: cd zig && zig build -Doptimize=ReleaseFast`
  );
}

const libPath = findLibrary();

const lib = dlopen(libPath, {
  onebr_open: {
    args: [FFIType.cstring],
    returns: FFIType.ptr,
  },
  onebr_process: {
    args: [FFIType.ptr, FFIType.u32],
    returns: FFIType.i32,
  },
  onebr_result_count: {
    args: [FFIType.ptr],
    returns: FFIType.u32,
  },
  onebr_get_json: {
    args: [FFIType.ptr, FFIType.ptr],
    returns: FFIType.ptr,
  },
  onebr_get_timing: {
    args: [FFIType.ptr, FFIType.ptr],
    returns: FFIType.ptr,
  },
  onebr_close: {
    args: [FFIType.ptr],
    returns: FFIType.void,
  },
});

export const { symbols } = lib;

/**
 * High-level wrapper for the 1BR library
 */
export class OnebrProcessor {
  private handle: number | null = null;

  /**
   * Open a file for processing
   */
  open(filePath: string): boolean {
    const pathBuffer = Buffer.from(filePath + "\0", "utf-8");
    this.handle = symbols.onebr_open(ptr(pathBuffer)) as number;
    return this.handle !== 0 && this.handle !== null;
  }

  /**
   * Process the file using the specified number of threads
   * @returns Number of unique stations found, or -1 on error
   */
  process(numThreads: number): number {
    if (!this.handle) {
      throw new Error("File not opened");
    }
    return symbols.onebr_process(this.handle, numThreads) as number;
  }

  /**
   * Get the number of unique stations
   */
  getResultCount(): number {
    if (!this.handle) {
      throw new Error("File not opened");
    }
    return symbols.onebr_result_count(this.handle) as number;
  }

  /**
   * Get the results as a JSON string
   */
  getJson(): string {
    if (!this.handle) {
      throw new Error("File not opened");
    }

    const lenBuffer = new BigUint64Array(1);
    const jsonPtr = symbols.onebr_get_json(this.handle, ptr(lenBuffer)) as number;

    if (jsonPtr === 0 || jsonPtr === null) {
      throw new Error("Failed to get JSON");
    }

    const len = Number(lenBuffer[0]);
    const arrayBuffer = toArrayBuffer(jsonPtr, 0, len);
    return new TextDecoder().decode(arrayBuffer);
  }

  /**
   * Get timing information as a JSON object
   */
  getTiming(): {
    mmap_ms: number;
    chunk_find_ms: number;
    process_ms: number;
    merge_ms: number;
    json_ms: number;
    total_ms: number;
    lines: number;
  } {
    if (!this.handle) {
      throw new Error("File not opened");
    }

    const lenBuffer = new BigUint64Array(1);
    const timingPtr = symbols.onebr_get_timing(this.handle, ptr(lenBuffer)) as number;

    if (timingPtr === 0 || timingPtr === null) {
      throw new Error("Failed to get timing");
    }

    const len = Number(lenBuffer[0]);
    const arrayBuffer = toArrayBuffer(timingPtr, 0, len);
    const timingJson = new TextDecoder().decode(arrayBuffer);
    return JSON.parse(timingJson);
  }

  /**
   * Close and release all resources
   */
  close(): void {
    if (this.handle) {
      symbols.onebr_close(this.handle);
      this.handle = null;
    }
  }
}
