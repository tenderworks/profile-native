# profile-native

A Claude Code skill for profiling native (C/C++/Rust) programs using [samply](https://github.com/mstange/samply) and converting the results into AI-friendly markdown.

## Requirements

- **samply** — `cargo install samply` or `brew install samply`
- **atos** — ships with Xcode Command Line Tools (macOS only)

## Usage

Ask Claude Code to profile a native binary:

> Profile `./build-arm/miniruby -e '1_000_000.times { Object.new.singleton_class }'`

Claude Code will:

1. Record a profile with `samply record`
2. Symbolicate hex addresses to function names with `symbolicate.rb`
3. Convert to markdown with `ff2md.rb`
4. Analyze the results and identify bottlenecks

## Scripts

### `scripts/symbolicate.rb`

Resolves unsymbolized hex addresses in a samply profile to function names using `atos`.

```
ruby scripts/symbolicate.rb profile.json              # overwrites in place
ruby scripts/symbolicate.rb profile.json output.json   # writes to separate file
```

- Groups addresses by library for efficient batch resolution
- Supports gzipped profile input
- Skips system libraries that lack debug symbols

### `scripts/ff2md.rb`

Converts a Firefox-format profile JSON into a markdown report.

```
ruby scripts/ff2md.rb profile.json > report.md
```

The report includes:
- Top functions by self time and total time
- Category breakdown (user/kernel)
- GVL state timeline (for Ruby profiles via Vernier)
- Full call tree with percentages

## Limitations

- Symbolication via `atos` is macOS-only. On Linux, samply typically symbolicates automatically if debug info is available.
- System libraries (dyld, libsystem_*) usually remain unsymbolized since they lack debug symbols.
