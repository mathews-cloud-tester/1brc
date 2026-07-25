#!/usr/bin/env node
// Debug-mode log sink: accepts POSTed JSON payloads and appends them as NDJSON lines
// to a log file, mirroring the endpoint that Cursor's built-in Debug mode provisions.
//
// Usage: node debug-log-server.mjs --log <path> [--port 7654] [--host 127.0.0.1]

import { createServer } from "node:http";
import { appendFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

function parseArgs(argv) {
  const args = { port: 7654, host: "127.0.0.1" };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === "--log" || flag === "--port" || flag === "--host") {
      if (value === undefined) {
        throw new Error(`Missing value for ${flag}`);
      }
      args[flag.slice(2)] = flag === "--port" ? Number(value) : value;
      i += 1;
    }
  }
  if (!args.log) {
    throw new Error("Missing required --log <path>");
  }
  if (!Number.isInteger(args.port) || args.port < 1 || args.port > 65535) {
    throw new Error(`Invalid --port: ${args.port}`);
  }
  return args;
}

async function readBody(req, limitBytes = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limitBytes) {
      throw new Error("Payload too large");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

let args;
try {
  args = parseArgs(process.argv.slice(2));
} catch (error) {
  console.error(`[debug-log-server] ${error.message}`);
  console.error("Usage: debug-log-server.mjs --log <path> [--port 7654] [--host 127.0.0.1]");
  process.exit(1);
}

const logPath = resolve(args.log);
await mkdir(dirname(logPath), { recursive: true });

const server = createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Debug-Session-Id");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");

  if (req.method === "OPTIONS") {
    res.writeHead(204).end();
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405).end();
    return;
  }

  try {
    const raw = await readBody(req);
    const payload = JSON.parse(raw);
    const sessionId = payload.sessionId ?? req.headers["x-debug-session-id"];
    const entry = {
      ...(sessionId ? { sessionId } : {}),
      id: payload.id ?? `log_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
      timestamp: payload.timestamp ?? Date.now(),
      ...payload,
    };
    await appendFile(logPath, `${JSON.stringify(entry)}\n`);
    res.writeHead(204).end();
  } catch (error) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: String(error?.message ?? error) }));
  }
});

server.on("error", (error) => {
  console.error(`[debug-log-server] failed to start: ${error.message}`);
  process.exit(1);
});

server.listen(args.port, args.host, () => {
  console.log(`[debug-log-server] endpoint: http://${args.host}:${args.port}/log`);
  console.log(`[debug-log-server] log path: ${logPath}`);
});
