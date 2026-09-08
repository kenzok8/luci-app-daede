# Performance fork maintenance — quic-go / outbound

The aggressive build replaces dae's QUIC and outbound dependencies with the
olicesx performance forks. Pins live in `ci/pins.env`; assemble workflows fetch
them from the `kenzok8/*` mirrors so a disappearing upstream branch cannot break
an old release.

## Pinned performance pair

`ci/pins.env` is the only source of truth for the current outbound and quic-go
commits. Do not copy current commit IDs into this document; the weekly perf lane
may move them.

`OUTBOUND_COMMIT`, `QUICGO_BASE_COMMIT` and `QUICGO_PERF_TIP` form one pinned
set. Both quic-go values must use the full commit required by outbound's
`go.mod`, so all three pins move together.

`olicesx/quic-go` is not a GitHub fork of `quic-go/quic-go`; its module name and
history differ. Do not rebase it onto an official quic-go tag. A refresh means
using the exact commit required by outbound, or backporting a specific official
fix onto this lineage.

## Self-owned patches that must survive every sync

The repository currently carries 18 patch files:

- `dae/patches`: 1 regular dae patch.
- `dae/patches_arm`: 2 ARM32 compatibility patches.
- `daed/patches`: 11 daed reliability and update patches.
- `daed/patches_arm`: 2 ARM32 compatibility patches for the embedded dae core.
- `ci/patches/outbound`: 2 patches (SSR buffered-reader fix + temporary REALITY
  client-version bump for Xray-core 26.7.x, see `ci/patches/outbound/README.md`).
- `ci/patches/quic-go`: currently empty; retained for future backports.

On 2026-08-28 every patch then present was checked against the pinned upstream
source. None was equivalently absorbed, and all of them remain required. In
particular, outbound still lacks the SSR `unwrapConn` fix and a native REALITY
version-byte strategy.

The `patch-absorbed` job in `auto-bump.yml` checks every regular, ARM, outbound
and quic-go patch in package order. It reports a patch when reverse apply starts
passing, applies every still-required patch forward, and fails instead of
silently skipping a source it cannot fetch or patch. Confirm the behavior in
upstream before deleting a reported local patch.

## Refresh procedure

1. Sync `olicesx/outbound:perf/complete-optimizations` to the matching
   `perf/complete-optimizations` branch in `kenzok8/outbound`.
2. Read `go.mod` at the selected outbound commit, extract the 12-character
   quic-go suffix from its pseudo-version, and resolve it to a full 40-character
   commit in `olicesx/quic-go`.
3. Fetch that exact quic-go commit and push it to the immutable
   `kenzok8/quic-go:daede-pinned-<40sha>` ref. The movable `daede-pinned` alias
   may point to the same commit, but it cannot replace the immutable ref.
4. Audit every local patch against the proposed bases:
   - reverse apply succeeds: upstream may have absorbed it; inspect the source
     before deleting it;
   - forward apply succeeds: keep it;
   - neither succeeds: port it and verify the original behavior still exists.
5. After the mirror and patch audit succeed, update `OUTBOUND_COMMIT`,
   `QUICGO_BASE_COMMIT` and `QUICGO_PERF_TIP` together in `ci/pins.env`.
6. For outbound, apply `ci/patches/outbound/*.patch` and run
   `go test ./protocol/shadowsocks_stream/ ./transport/tls/`.
7. For quic-go, apply any `ci/patches/quic-go/*.patch` and run `go build ./...`.
8. On a staging branch, run both assemble workflows and all four gate build
   combinations (2 SDK versions × 2 architectures). Promote to `main` only
   after every package exists.

## Automatic safeguards

- The core lane runs every 6 hours and updates only daed, dae-wing and the
  official dae core pin, leaving the performance pair unchanged.
- The perf lane runs every Monday at 03:30 Beijing time and atomically updates
  outbound plus both quic-go pins to the exact commit required by outbound.
- Each lane assembles on a unique staging branch; any source, patch or SDK build
  failure stops at the gate before the tested SHA can reach `main`.
- `patch-absorbed` checks all local patch locations so an upstream sync cannot
  silently discard an ARM, daed, SSR or future quic-go fix.

The exact build path is intentionally pinned. Tracking official quic-go releases
directly is not useful here because dae-core depends on the older, incompatible
olicesx API lineage.
