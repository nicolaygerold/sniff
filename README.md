# Sniff 🐕

Fast fuzzy file finder written in Zig. Inspired by VSCode and Zed's file pickers.

## Features

- **Fast**: Searches 500K+ files in <100ms
- **Smart scoring**: Prioritizes filename matches, path separators, camelCase
- **Gitignore support**: Respects `.gitignore` files
- **JSON protocol**: Easy integration with editors and tools
- **TypeScript client**: Ready-to-use npm package

## Installation

### npm (recommended)

```bash
npm install @nicolaygerold/sniff
```

### Homebrew (coming soon)

```bash
brew install nicolaygerold/tap/sniff
```

### From source

```bash
git clone https://github.com/nicolaygerold/sniff
cd sniff
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/sniff ~/.local/bin/
```

## Usage

### CLI

```bash
# One-shot search
sniff /path/to/project "query"

# Interactive mode
sniff /path/to/project

# JSON mode (for tool integration)
sniff --json /path/to/project
```

### TypeScript/JavaScript

```typescript
import Sniff from '@nicolaygerold/sniff';

const sniff = new Sniff();
await sniff.init('/path/to/project');

console.log(`Indexed ${sniff.files} files in ${sniff.indexTime}ms`);

const results = await sniff.search('main');
// [{ path: 'src/main.zig', score: 31, positions: [0,1,2,3] }, ...]

sniff.close();
```

### JSON Protocol

When running in `--json` mode, sniff communicates via newline-delimited JSON:

**Ready message** (sent after indexing):
```json
{"type":"ready","files":12345,"indexTime":150}
```

**Query** (send via stdin):
```
main
```

**Results** (received via stdout):
```json
{"type":"results","query":"main","searchTime":5,"results":[{"path":"src/main.zig","score":31,"positions":[0,1,2,3]}]}
```

## Scoring Algorithm

Sniff uses a VSCode-inspired scoring algorithm:

| Bonus | Points | Example |
|-------|--------|---------|
| Start of string | +8 | `main` matches `main.zig` |
| After separator | +5 | `main` matches `src/main.zig` |
| After dot | +4 | `zig` matches `main.zig` |
| CamelCase | +2 | `FN` matches `FileName` |
| Consecutive | +3-6 | `mai` in `main` |

## Performance

Tested on a 500K file codebase (Chromium):

| Operation | Time |
|-----------|------|
| Indexing | ~10s |
| Search | ~100ms |
| Memory | ~100MB |

## Development

```bash
# Build
zig build

# Run tests
zig build test

# Build release
zig build -Doptimize=ReleaseSafe
```

## License

MIT
