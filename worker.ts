import { createReadStream } from "fs";
import { parentPort, workerData } from "worker_threads";
import { processLineFromBuffer, type StationStats } from "./stats";

interface WorkerData {
  fileDescriptor: number;
  filePath: string;
  startByte: number;
  endByte: number;
}

interface WorkerResult {
  rowsProcessed: number;
  processingTime: number;
  stats: Record<string, StationStats>;
}

const NEWLINE = '\n'.charCodeAt(0);

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

    let buffer = Buffer.alloc(0);

    for await (const chunk of stream) {
      buffer = Buffer.concat([buffer, chunk]);
      
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
      
      // Keep remaining incomplete line in buffer
      if (lineStart < buffer.length) {
        buffer = buffer.subarray(lineStart);
      } else {
        buffer = Buffer.alloc(0);
      }
    }

    // Process final line if buffer has content
    if (buffer.length > 0) {
      processLineFromBuffer(buffer, 0, buffer.length, stats);
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

if (parentPort) {
  processFileChunk().catch((error) => {
    console.error(`💥 Worker ${workerData.workerId} failed:`, error);
    process.exit(1);
  });
} else {
  console.error("This script should only be run as a worker thread");
  process.exit(1);
}
