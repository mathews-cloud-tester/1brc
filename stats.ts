const ASCII_0 = "0".charCodeAt(0);
const ASCII_9 = "9".charCodeAt(0);
const ASCII_DECIMAL = ".".charCodeAt(0);
const ASCII_MINUS = "-".charCodeAt(0);
const ASCII_SEMICOLON = ";".charCodeAt(0);

export interface StationStats {
  sum: number;
  cnt: number;
  min: number;
  max: number;
}

export function processLineFromBuffer(
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

  const station = buffer.toString("utf8", stationStart, stationEnd);

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
