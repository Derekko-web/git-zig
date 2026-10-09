# Git implementation in Zig

Maintained by **Derek Ko**.

A compact implementation of Git repository storage and selected commands,
written in Zig.

## Features

- Repository initialization and loose-object storage
- Blob hashing and inspection
- Tree creation and listing
- Commit object creation
- HTTP reference discovery and cloning
- Pack-file decoding, delta reconstruction, and working-tree checkout

## Build and run

Requires Zig 0.15.1 or 0.15.2.

```sh
./your_program.sh init
./your_program.sh hash-object -w README.md
./your_program.sh write-tree
./your_program.sh clone https://github.com/Derekko-web/git-zig.git ../git-zig-demo
```

Direct builds use `zig build`; the executable is `zig-out/bin/main`.
Source code is in `src/main.zig`.

This implements selected Git commands and protocol behavior. It is an
experimental implementation, rather than a complete replacement for Git.
