# AGENTS.md

## Cursor Cloud specific instructions

This is a single-purpose **Bun + TypeScript CLI** for the 1 Billion Row Challenge (1BRC). It is a one-shot batch program — there are **no servers, services, ports, or databases** to run. You invoke it against an input file and it prints aggregated min/mean/max per weather station, then exits.

### Runtime / environment
- Cloud Agent `install` installs Bun with `https://bun.sh/install` and symlinks `bun` and `bunx` to `/usr/local/bin`, which is on the default `PATH`. The installer also prepends `~/.bun/bin` in `~/.bashrc`.
- If `bun` is missing (for example a default-image boot that skipped `install`), run `curl -fsSL https://bun.sh/install | bash`, then `sudo ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun` and the same for `bunx`.
- `.cursorrules` says to prefer Bun commands. Node also works as an alternate runtime.

### Common commands (see `package.json` scripts and `README.md`)
- Run (Bun, preferred): `bun run main.ts test.txt`
- Run (Node alternate): `npm run node test.txt`
- Typecheck: `bunx tsc --noEmit`
- Build: `bun run build` (emits to `dist/`, which is gitignored)
- There is **no lint or automated test framework** configured.

### Gotchas
- `test.txt` (~1000 rows) is the quick end-to-end input. The real `measurements.txt` (~13.8 GB) is **not** in the repo; generating it needs JDK 21 + the upstream `gunnarmorling/1brc` repo (see `README.md`) and is not required for normal development.
- `correct_answer.txt` is the expected output for the **full** `measurements.txt` and uses a different format (`station=min/mean/max`). Do **not** diff it against `test.txt` runs — the program's own output format is `station:min/mean/max`.
