# Webview Server Evaluation

## Context

The current launcher starts a local `python3 -m http.server "$CODEX_LINUX_WEBVIEW_PORT"` process for the extracted webview bundle. It waits for the configured port to become reachable before launching Electron, and exports `ELECTRON_RENDERER_URL` so side-by-side app IDs can use an isolated local origin.

The extracted webview payload is a static bundle under `codex-app/content/webview` and is relatively large: about 35 MB across 693 files. The generated `index.html` references hashed assets through relative paths, so the app still expects a stable local origin.

## Options

### 1. Keep Python and harden lifecycle handling

What changes:

- Keep `python3 -m http.server "$CODEX_LINUX_WEBVIEW_PORT"`
- Keep improving the current process lifecycle and readiness behavior
- Improve port-collision handling and logging

Benefits:

- Lowest implementation risk
- No packaging or runtime-binary changes
- Preserves the existing static-asset serving model

Risks:

- Python remains an external runtime dependency for the launcher path
- Startup reliability still depends on a separate process being spawned correctly
- Performance improvements are limited, because the server is still a generic Python HTTP server

### 2. Ship a tiny Rust static-file server

What changes:

- Replace the Python server with a small Rust binary that serves `content/webview`
- Bundle that binary with the Linux app or package it alongside the launcher
- Add deterministic startup, port selection, and readiness signaling

Benefits:

- Better control over startup behavior, logging, and shutdown
- Fewer runtime dependencies once the Rust binary is packaged
- More room for future optimizations around caching and path handling

Risks:

- Larger implementation and maintenance surface
- Requires packaging updates and a new build artifact
- Could duplicate functionality that the current app may only need in a very narrow way

### 3. Remove the local server entirely

What changes:

- Change the Electron/webview integration so the app can load the static bundle directly
- Eliminate the localhost origin requirement

Benefits:

- Simplest runtime model if it is truly feasible
- Removes a whole local-server process from the launcher path
- Best theoretical startup behavior

Risks:

- Highest product risk
- May require app-bundle changes outside this Linux repo
- Relative asset loading and origin-sensitive behavior could break in subtle ways

## Recommendation

Keep Python for now, but harden the launcher lifecycle and readiness handling.

Why this wins:

- The current problem looks more like process orchestration than raw server throughput.
- The webview payload is static, so the launcher only needs a reliable local origin, not a high-performance application server.
- This path preserves compatibility while leaving the door open for a Rust server later if evidence shows Python is still a bottleneck.

## Integration Points

If we later implement the recommended hardening or a Rust server, the change points are:

- `install.sh` launcher generation
- the local webview startup block around the configured webview port
- packaging if a Rust server binary is added
- launcher logging and cleanup logic around the PID file and `http.server` shutdown

## Risks To Watch

- Port conflicts on the configured webview port
- Stale launcher/server processes after crashes
- Chromium waiting on a server that has not finished binding yet
- Hidden assumptions in the extracted app about a localhost origin

## Acceptance Criteria For A Future Change

- Electron starts reliably when the launcher is invoked once
- A stale server process does not block a new launch
- The webview origin is available before Electron tries to load it
- Launcher logs clearly show server start, bind, and shutdown events
- The app still renders the same webview assets without broken relative paths

## Future Test Plan

- Launcher smoke test for start/stop/restart behavior
- Port-collision test for the configured webview port
- Stale-process cleanup test
- Basic render test that verifies the webview assets are reachable from the expected origin
