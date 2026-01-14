# Gitignore Implementation Research

Research findings on how fd, ripgrep, and fzf handle .gitignore parsing, with focus on nested file scoping.

## Executive Summary

The current sniff bug: patterns from nested `.gitignore` files are applied globally instead of being scoped to their directory. For example, `src/` in `third_party/bidimapper/.gitignore` incorrectly skips ALL `src` directories everywhere.

**Key insight from research**: The correct approach is to store each `.gitignore`'s **root directory** with its patterns and strip that prefix when matching. Ripgrep/fd use a hierarchical matcher chain where each matcher is scoped to its directory.

## Tool Comparison

| Tool | Gitignore Implementation | Approach |
|------|-------------------------|----------|
| ripgrep | `ignore` crate (Rust) | Hierarchical matcher chain, each with its own root |
| fd | Uses ripgrep's `ignore` crate | Delegates entirely to the crate |
| fzf | None | Delegates to external tools (fd, rg) or uses simple skip list |

## Ripgrep's `ignore` Crate (The Gold Standard)

### 1. Hierarchical Matcher Structure

Each directory with a `.gitignore` gets its own matcher linked to parent matchers:

```rust
struct IgnoreInner {
    dir: PathBuf,                    // THE KEY: directory containing this .gitignore
    git_ignore_matcher: Gitignore,   // Patterns from this specific file
    parent: Option<Ignore>,          // Link to parent directory's matcher
}

pub struct Gitignore {
    set: GlobSet,        // Compiled glob patterns
    root: PathBuf,       // Directory where patterns are anchored
    globs: Vec<Glob>,    // Pattern metadata
}
```

### 2. Matching Algorithm

When checking if a path should be ignored:

1. **Start with innermost matcher** (closest to the file)
2. **Strip the matcher's root** from the path before matching
3. **Walk up the parent chain** checking each matcher
4. **First match wins** (innermost takes precedence)

Example: Checking `third_party/bidimapper/src/main.rs`:

```
Matcher3 (root=third_party/bidimapper/):
  - Strip root → "src/main.rs"
  - Pattern "src/" matches → IGNORED
  
If no match, check Matcher2 (root=src/):
  - Path doesn't start with "src/" → no match

If no match, check Matcher1 (root=repo_root/):
  - Strip root → "third_party/bidimapper/src/main.rs"
  - No matching patterns
```

### 3. Anchored vs Global Patterns

| Pattern | Transformation | Matches |
|---------|---------------|---------|
| `/src/` (leading slash) | `src/` (anchored to gitignore dir) | Only `{gitignore_dir}/src/` |
| `src/` (no leading slash) | `**/src/` (recursive) | `{gitignore_dir}/**/src/` at any depth |
| `*.o` (no slashes) | `**/*.o` | Any `.o` file under gitignore dir |

The `**/` prefix is added for patterns without slashes, but **matching is still relative to the gitignore's directory**.

### 4. Performance Optimizations

- **GlobSet**: Multiple patterns compiled into single regex automaton
- **Match strategy selection**: Fast paths for common patterns:
  - `Literal`: Exact string comparison
  - `Extension`: Hash table lookup
  - `Prefix`/`Suffix`: Simple string operations
  - `Regex`: Full regex (fallback only)
- **Directory caching**: Compiled matchers cached per directory
- **Thread-local buffers**: Reusable allocations for match results

## What Sniff Got Wrong (FIXED)

The original sniff implementation had these issues:

1. **Global hashsets for nested gitignore patterns**: Patterns from nested `.gitignore` files were added to global hashsets without scoping
2. **Anchored patterns treated as global**: `/MODULE.bazel` in root gitignore was added to global `literal_files`, matching everywhere
3. **Extension patterns always global**: `*.html` from nested gitignores ignored ALL .html files
4. **Complex patterns unscoped**: `*` pattern from `tools/clang/crashreports/.gitignore` matched everything

These issues caused sniff to index only 18K files in Chromium instead of 469K.

**IMPLEMENTED FIX**: All pattern types now include scope information:
- Literal patterns from nested gitignores → prefix patterns with full path
- Anchored patterns from root gitignore → prefix patterns (not global hashsets)
- Extension patterns from nested gitignores → `ScopedExtension` with scope check
- Complex patterns → `ComplexPattern.scope` field for path-relative matching

## Correct Implementation Strategy

### Option 1: Hierarchical Matchers (What ripgrep does)

Create a tree of matchers, each scoped to its directory:

```zig
const ScopedMatcher = struct {
    root: []const u8,           // e.g., "third_party/bidimapper/"
    literal_dirs: HashSet,       // Only patterns from this .gitignore
    extensions: HashSet,
    // ... other pattern types
    parent: ?*ScopedMatcher,
};
```

Matching:
1. Walk matcher chain from innermost to root
2. For each matcher, strip `root` from path before checking

### Option 2: Store Full Paths (Simpler)

Instead of storing `"src"`, store `"third_party/bidimapper/src/"`:

```zig
// When parsing third_party/bidimapper/.gitignore:
// Pattern "src/" becomes prefix pattern "third_party/bidimapper/src/"

pub fn shouldSkipDirPath(self: *const FastGitIgnore, rel_path: []const u8) bool {
    // Check if rel_path matches any stored full-path pattern
    for (self.prefix_patterns.items) |prefix| {
        if (std.mem.eql(u8, prefix, rel_path)) return true;
    }
    return false;
}
```

### Option 3: Pattern + Scope Pairs

Store each pattern with its scope information:

```zig
const ScopedPattern = struct {
    pattern: []const u8,     // "src" or "*.o"
    scope: []const u8,       // "third_party/bidimapper/" or ""
    is_anchored: bool,       // Leading slash in original pattern
};
```

## Recommended Fix for Sniff

Given sniff's architecture, **Option 2 (Store Full Paths)** is likely simplest:

1. **For literal patterns from nested .gitignore files**: Convert to prefix patterns with full path
   - `src/` in `third_party/bidimapper/.gitignore` → prefix pattern `third_party/bidimapper/src/`

2. **Keep global hashsets only for root .gitignore**: These genuinely apply everywhere

3. **Check full path, not just basename**: `shouldSkipDirPath(rel_path)` instead of `shouldSkipDir(basename)`

4. **For extension patterns**: These should remain global since `*.o` means "any .o file in this subtree"
   - But the subtree is relative to the gitignore's location!
   - May need `ScopedExtension { ext: "o", scope: "third_party/bidimapper/" }`

## Key Semantic Rules from gitignore Spec

1. **Patterns are relative to the .gitignore location**
2. **Leading `/` anchors to the gitignore's directory** (not repo root)
3. **No leading `/` and no slashes in pattern** → prepend `**/` (matches at any depth)
4. **Trailing `/` means directory-only**
5. **Negation `!` can un-ignore previously ignored files**
6. **Later patterns override earlier ones** (within same file)
7. **Nested .gitignore takes precedence** over parent

## Performance Considerations

- **Early directory pruning is critical** for large repos like Chromium
- Hash lookups are O(1) but only work for exact matches
- Prefix patterns require O(n) iteration
- Consider a trie for prefix matching if many prefix patterns exist
- Extension patterns should remain O(1) hash lookups

## References

- [gitignore specification](https://git-scm.com/docs/gitignore)
- [ripgrep ignore crate](https://github.com/BurntSushi/ripgrep/tree/master/crates/ignore)
- [fd source](https://github.com/sharkdp/fd)
- [fzf source](https://github.com/junegunn/fzf)
