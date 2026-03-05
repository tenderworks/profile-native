---
name: profile-native
description: Profile native code to understand it's performance
license: Apache-2.0
compatibility: Requires samply
---

To profile native code, first make sure samply is installed.

You can run samply like this:

```
$ samply record -s -o profile.json -- slow_program
```

It will profile `slow_program` and output a JSON file with the profile results.

Samply does not symbolize functions by default. On macOS, run `symbolicate.rb` to resolve addresses to function names using `atos`:

```
$ ruby symbolicate.rb profile.json
```

This overwrites the profile in place. You can also specify an output path:

```
$ ruby symbolicate.rb profile.json symbolicated.json
```

Then use `ff2md.rb` to convert the symbolicated JSON file into an AI-friendly markdown format.
