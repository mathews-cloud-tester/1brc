# AGENTS.md

## Project overview

Bun/TypeScript implementation of the [1 Billion Row Challenge](https://github.com/gunnarmorling/1brc). Parses weather station CSV data in parallel using `worker_threads`.

## Cursor Cloud specific instructions

- **Bun**: This project expects Bun (see `.cursorrules`). If `bun` is not on `PATH`, install once per VM with `npm install -g bun --prefix ~/.local` and ensure `~/.local/bin` is on `PATH`.
- **Quick validation**: `bun run main.ts test.txt` (or `npm run node test.txt` via Node + ts-node).
- **Build**: `npm run build` runs `tsc`.
- **Full benchmark**: Requires a separately generated `measurements.txt` (~13.8 GB); only `test.txt` ships in-repo.
- **No servers**: CLI-only; no Docker or databases.
