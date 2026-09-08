# outbound patches (self-owned)

Fixes we carry on top of `OUTBOUND_COMMIT` because upstream has not merged them.
The assemble workflows apply every `NNNN-*.patch` here with `git apply` right
after fetching outbound; an empty directory is skipped.

## Current state: two patches

| patch | what | why it is here |
|-------|------|----------------|
| 0001 | SSR obfs reaches its cipher through `BufferedReaderConn` | fixes every SSR handshake; olicesx never merged it into `perf/complete-optimizations` |
| 0002 | REALITY client sends version bytes `[26,7,28]` instead of `[1,8,10]` | Xray-core 26.7.11+ defaults the server's `minClientVer` to `26.3.27`, so our version bytes are rejected; see below |

### 0001 background

The shadowsocks stream layer passes its cipher down to the SSR obfs conn by type
asserting on the underlying conn. A TCP read-buffering change wrapped that conn
in `netproxy.BufferedReaderConn`, so both assertions stopped matching and every
SSR handshake failed with `outer conn did not init cipher of Obfs` (issue #52).
The fix peels transparent wrappers via the existing `IntrinsicConn` accessor.

The fix exists upstream as a side commit (`d5d9708`, later rebased to
`5797872`) that was never merged into the perf branch we track. Pinning
`OUTBOUND_COMMIT` at that side commit does not survive: `auto-bump.yml` runs
`gh repo sync ... --force`, which resets our fork's branch to olicesx's, and the
next bump moves `OUTBOUND_COMMIT` to a perf-branch commit without the fix. That
is exactly how it regressed on 2026-08-13 (`dae/daed 2026.08.13`) — the same
breakage as #52, five days after it was first fixed. Carrying it as a patch here
decouples the fix from both the fork branch and the pin.

The patch ships `ssr_cipher_test.go` with it:
`TestSSRObfsReceivesCipherThroughBufferedReaderConn` fails on an unpatched tree
and passes on a patched one, so a silent regression cannot come back unnoticed.

### 0002 background

The REALITY client writes its own three version bytes into the encrypted
handshake. Xray-core 26.7.11+ (commit `af7eb68`) defaults the server's
`realitySettings.minClientVer` to `26.3.27` when unset, so 26.7.x servers using
that default reject dae/daed REALITY connections into the fallback decoy
(`REALITY: processed invalid connection`). Sending `[26,7,28]` passes any
current default gate. This is a temporary compatibility measure, not a protocol
requirement:

- Xray-core main has already reverted the default gate in commit `47cfe999`,
  but no release carries that change yet, and 26.7.x servers already deployed
  keep it.
- Re-evaluate (and delete) this patch only when outbound itself adopts an
  appropriate version-byte strategy, or when the project's compatibility scope
  explicitly drops 26.7.x servers — not merely because a newer Xray release
  appears. A server operator can still reject us by explicitly configuring a
  lower `maxClientVer`; that is their choice and nothing on our side fixes it.

The REALITY protocol library is identical between Xray-core 26.3.27 and
26.7.28, so patched clients remain fully compatible with older servers.

## Apply by hand

```sh
git checkout -B carry <OUTBOUND_COMMIT>
git apply ci/patches/outbound/*.patch
go test ./protocol/shadowsocks_stream/ ./transport/tls/
```

## When upstream absorbs a patch

`git apply` fails loudly and the assemble build stops. Inspect the failing patch
before deleting it: for 0001, confirm `unwrapConn` is in the new base; for 0002,
follow the re-evaluation conditions above.
