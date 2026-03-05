---
name: profile-native
description: Profile native code to understand its performance
license: Apache-2.0
compatibility: Requires samply and atos (macOS)
---

To profile native code, first make sure samply is installed.

## Workflow

1. Record a profile with samply:

```
$ samply record -s -o profile.json -- slow_program
```

2. Symbolicate the profile (resolves hex addresses to function names using `atos`):

```
$ ruby symbolicate.rb profile.json
```

This overwrites the profile in place. You can optionally specify a separate output path:

```
$ ruby symbolicate.rb profile.json symbolicated.json
```

3. Convert the symbolicated profile to AI-friendly markdown:

```
$ ruby ff2md.rb profile.json > profile.md
```

## Scripts

All scripts live in the `scripts/` directory.

- **`symbolicate.rb`** — Reads a samply profile JSON, finds all unsymbolized hex-address function names, groups them by library, batch-resolves them via `atos`, and writes the updated profile. Supports gzipped input.
- **`ff2md.rb`** — Converts a Firefox-format profile JSON (as produced by samply) into a markdown report with top functions, category breakdown, and a call tree.
