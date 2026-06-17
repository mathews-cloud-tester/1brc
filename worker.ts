import { createReadStream } from "fs";
import { parentPort, workerData } from "worker_threads";

interface WorkerData {
  fileDescriptor: number;
  filePath: string;
  startByte: number;
  endByte: number;
}

interface StationStats {
  sum: number;
  cnt: number;
  min: number;
  max: number;
}

interface WorkerResult {
  rowsProcessed: number;
  processingTime: number;
  stats: Record<string, StationStats>;
}

const NEWLINE = '\n'.charCodeAt(0);
const ASCII_0 = '0'.charCodeAt(0);
const ASCII_9 = '9'.charCodeAt(0);
const ASCII_DECIMAL = '.'.charCodeAt(0);
const ASCII_MINUS = '-'.charCodeAt(0);
const ASCII_SEMICOLON = ';'.charCodeAt(0);

async function processFileChunk() {
  const { filePath, startByte, endByte }: WorkerData = workerData;
  const startTime = performance.now();

  console.log(
    `🔧 Worker starting: bytes ${startByte.toLocaleString()} to ${endByte.toLocaleString()}`
  );

  let rowsProcessed = 0;
  const stats = new Map<string, StationStats>();

  try {
    // Create a read stream for the specific byte range
    const stream = createReadStream(filePath, {
      start: startByte,
      end: endByte,
      highWaterMark: 1 << 20, // 1MB buffer (sweet spot for performance)
    });

    // Holds the unprocessed tail of the previous chunk (at most one partial line).
    // Using a slice avoids re-copying the entire accumulated buffer on every iteration.
    let tail: Buffer = Buffer.alloc(0);

    for await (const rawChunk of stream) {
      // Only allocate a new Buffer when there are leftover bytes from the previous chunk.
      // In the common case (tail is empty) we work directly on the incoming chunk.
      const buffer: Buffer = tail.length > 0
        ? Buffer.concat([tail, rawChunk as Buffer])
        : rawChunk as Buffer;

      // Process complete lines in the buffer
      let lineStart = 0;
      for (let i = 0; i < buffer.length; i++) {
        if (buffer[i] === NEWLINE) {
          // Found a complete line
          const lineLength = i - lineStart;
          if (lineLength > 0) {
            processLineFromBuffer(buffer, lineStart, lineLength, stats);
            rowsProcessed++;
          }
          lineStart = i + 1;
        }
      }

      // Retain only the incomplete trailing fragment (typically a few bytes)
      tail = lineStart < buffer.length
        ? buffer.subarray(lineStart)
        : Buffer.alloc(0);
    }

    // Process final line if tail has content (last line with no trailing newline)
    if (tail.length > 0) {
      processLineFromBuffer(tail, 0, tail.length, stats);
      rowsProcessed++;
    }

    const processingTime = performance.now() - startTime;

    // Convert Map back to Record for serialization
    const statsObj: Record<string, StationStats> = {};
    for (const [station, stationStats] of stats) {
      statsObj[station] = stationStats;
    }

    const result: WorkerResult = {
      rowsProcessed,
      processingTime,
      stats: statsObj, // Send as Record object
    };

    // Send result back to main thread
    if (parentPort) {
      parentPort.postMessage(result);
    }
  } catch (error) {
    console.error(`❌ Worker error:`, error);
    if (parentPort) {
      parentPort.postMessage({
        error: error instanceof Error ? error.message : String(error),
      });
    }
    throw error;
  }
}

function processLineFromBuffer(
  buffer: Buffer, 
  start: number, 
  length: number, 
  stats: Map<string, StationStats>
) {
  // Find semicolon position
  let semicolonPos = -1;
  for (let i = start; i < start + length; i++) {
    const isSemicolon = buffer[i] === ASCII_SEMICOLON;
    if (isSemicolon) {
      semicolonPos = i;
      break;
    }
  }
  
  if (semicolonPos === -1) return; // No semicolon found, invalid line
  
  // Extract station name (trim whitespace)
  let stationStart = start;
  let stationEnd = semicolonPos;
  
  const station = buffer.toString('utf8', stationStart, stationEnd);
  
  // Extract temperature value cursors (all values after the semicolon)
  const tempStart = semicolonPos + 1;
  const tempEnd = start + length;
  
  // Skip leading whitespace for temperature
  let tempPos = tempStart;
  
  // =========================================================================
  // Build the temperature value from the digits, decimal, and negative sign
  // =========================================================================
  let temperature = 0;
  let isNegative = false;
  let hasDecimal = false;
  let decimalDivisor = 1;

  const detectedNegativeSign = buffer[tempPos]! === ASCII_MINUS;
  if (detectedNegativeSign) {
    isNegative = true;
    tempPos++;
  }
  
  const isDigit = (char: number) => char! >= ASCII_0 && char! <= ASCII_9;

  for (let i = tempPos; i < tempEnd; i++) {
    const char = buffer[i];
    if (isDigit(char!)) {
      // Convert ASCII digit to number
      // Ex. ASCII code 55 - ASCII_0 (code 48) = 7
      const digit = char! - ASCII_0;

      if (hasDecimal) {
        // Build the decimal value from the digits
        decimalDivisor *= 10;
        temperature += digit / decimalDivisor;
      } else {
        // Build the integer value from the digits
        temperature = temperature * 10 + digit;
      }
    } else if (char! === ASCII_DECIMAL) {
      hasDecimal = true;
    }
  }
  
  if (isNegative) {
    temperature = -temperature;
  }
  
  // =========================================================================
  // Update min/max/sum/cnt stats
  // =========================================================================
  let stationStats = stats.get(station);
  if (!stationStats) {
    stationStats = {
      sum: temperature,
      cnt: 1,
      min: temperature,
      max: temperature,
    };
    stats.set(station, stationStats);
  } else {
    stationStats.sum += temperature;
    stationStats.cnt += 1;

    // Avoid doing Math.min/max to avoid function call overhead
    if (temperature < stationStats.min) {
      stationStats.min = temperature;
    }
    if (temperature > stationStats.max) {
      stationStats.max = temperature;
    }
  }
}

if (parentPort) {
  processFileChunk().catch((error) => {
    console.error(`💥 Worker ${workerData.workerId} failed:`, error);
    process.exit(1);
  });
} else {
  console.error("This script should only be run as a worker thread");
  process.exit(1);
}
