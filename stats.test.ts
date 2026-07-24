import { describe, expect, test } from "bun:test";
import { processLineFromBuffer, type StationStats } from "./stats";

describe("processLineFromBuffer", () => {
  test("aggregates min, max, sum, and count for repeated stations", () => {
    const stats = new Map<string, StationStats>();

    processMeasurementLine("Berlin;12.3", stats);
    processMeasurementLine("Berlin;-4.5", stats);
    processMeasurementLine("Berlin;7.7", stats);

    expect(stats.get("Berlin")).toEqual({
      sum: 15.5,
      cnt: 3,
      min: -4.5,
      max: 12.3,
    });
  });

  test("parses a line from a byte offset within a larger buffer", () => {
    const stats = new Map<string, StationStats>();
    const buffer = Buffer.from("ignored\nTokyo;31.1\nignored");
    const start = "ignored\n".length;
    const length = "Tokyo;31.1".length;

    processLineFromBuffer(buffer, start, length, stats);

    expect(stats.get("Tokyo")).toEqual({
      sum: 31.1,
      cnt: 1,
      min: 31.1,
      max: 31.1,
    });
  });

  test("ignores malformed lines without a semicolon", () => {
    const stats = new Map<string, StationStats>();

    processMeasurementLine("not-a-measurement", stats);

    expect(stats.size).toBe(0);
  });
});

function processMeasurementLine(
  line: string,
  stats: Map<string, StationStats>
) {
  const buffer = Buffer.from(line);
  processLineFromBuffer(buffer, 0, buffer.length, stats);
}
