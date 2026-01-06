---
name: committing
description: Creates well-structured git commits with conventional commit format. Use when committing changes, writing commit messages, or asked to commit.
---

# Committing

Create clear, concise git commits. Always include Amp as co-author.

## Command

```bash
git commit -m "<type>: <description>" --trailer "Co-authored-by: Amp <amp@ampcode.com>"
```

## Types

| Type | Use for |
|------|---------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructuring (no behavior change) |
| `test` | Adding/fixing tests |
| `chore` | Deps, config, CI, build |
| `perf` | Performance improvement |

## Rules

1. **Subject**: Max 50 chars, imperative ("add" not "added"), no period
2. **Body** (optional): Explain *what* and *why*, not *how* — the diff shows how
3. **Keep it short**: Nobody reads walls of text. Link to issues for details.
4. **Scope** (optional): `feat(parser): add array support`

## Examples

```bash
# Simple
git commit -m "feat: add process restart with 'r' key" --trailer "Co-authored-by: Amp <amp@ampcode.com>"

# With context (when needed)
git commit -m "fix: prevent crash on empty command list

Shows usage help instead of panicking." --trailer "Co-authored-by: Amp <amp@ampcode.com>"

# Breaking change
git commit -m "feat!: change config format to TOML

BREAKING CHANGE: JSON configs no longer supported" --trailer "Co-authored-by: Amp <amp@ampcode.com>"

# Reference issue
git commit -m "fix: handle UTF-8 in process names

Fixes #42" --trailer "Co-authored-by: Amp <amp@ampcode.com>"
```

## Philosophy

- **Atomic**: One logical change per commit
- **Don't duplicate the diff**: The code shows *how*, the message explains *why*
- **Link, don't embed**: Reference issues/tickets for detailed context
- **Each commit should build**: Don't break the build mid-history
