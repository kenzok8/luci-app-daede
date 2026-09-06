#!/bin/sh
# daed-cleanup.sh — reaper for stale daed kernel state.
#
# Removes:
#   1. Processes inside the `daens` netns (SIGTERM, then SIGKILL after 1s)
#   2. The `daens` network namespace itself (ip netns del, with
#      umount+rm as fallback for zombie nsfs mounts)
#   3. The `dae0` veth pair in the host netns
#
# What this script intentionally does NOT do:
#
#   It does NOT try to detach the eBPF tc clsact filter that daed
#   pins on br-lan / dae0 ingress. The detach path lives inside
#   the daed userspace process itself (`ControlPlane.DetachBpfHooks`
#   → `netlink.FilterDel` / `tc qdisc del dev <iface> clsact`,
#   control/control_plane_core.go:228, control/bpf_purge.go:30-41).
#   `bpftool prog detach` is the wrong tool: it only handles the
#   attach types the kernel exposes through bpf_iter / bpf_link
#   (sk_msg_verdict, sk_skb_verdict, sk_skb_stream_verdict,
#   sk_skb_stream_parser, flow_dissector), and daed's hooks are
#   attached via `netlink.FilterAdd` as TC clsact filters, which
#   are not on that list. kenzok8 confirmed this on PR
#   kenzok8/openwrt-daede#70 (review, 2026-09-06 12:37Z).
#
#   The honest summary of what an opkg-side wrapper can and cannot
#   do for the eBPF-leak problem (daeuniverse/dae#1092):
#
#     CAN do:                                        CANNOT do:
#     reap daens netns                                detach pinned tc clsact filters
#     reap dae0 veth pair                             delete /sys/fs/bpf/daed cleanly
#     refuse to start a second daed (see
#     daed-guard's pgrep check)
#
#   The pinned-tc-clsact fix has to land in daed's own graceful
#   shutdown path (which is already the case — see
#   dae/cmd/run.go:1035), or in a separate kernel-level cleanup
#   helper. The opkg wrapper's job is to make sure the netns/veth
#   state is clean and to make a stale eBPF situation visible in
#   logread so an operator knows a reboot is required.
#
# Idempotent: re-running on a clean system is a no-op. Safe to call
# while daed is running — every potentially-destructive step is
# guarded by a `pgrep -f /usr/bin/daed` check.
#
# Companion to daed-guard: that wrapper calls daed_cleanup_runtime
# before exec'ing the daemon (so any stale state from a previous
# crashed run is reaped) and again after the daemon exits (so a
# OOM-kill or kernel panic also leaves the netns/veth clean).
#
# This script is a kenzok8/openwrt-daede-specific evolution of the
# file originally shipped in daeuniverse/daed's `install/linux/`.
# It must remain a single function (`daed_cleanup_runtime`) so the
# `procd init.d/daed` and the `daed-guard` wrapper can both
# source it.

daed_cleanup_runtime() {
	local pid rc=0

	# If daed userspace is currently running, do not touch the
	# netns, the veth, or the eBPF dataplane. They are in active
	# use; removing them would make every connection through dae
	# hang.
	if pgrep -f "^/usr/bin/daed " >/dev/null 2>&1; then
		# Stale-child guard (P1-#6 in the Codex review on
		# kenzok8/openwrt-daede#70): if we get here from
		# daed-guard's pre-start cleanup, that means a previous
		# wrapper run was killed and its /usr/bin/daed child
		# outlived it. Returning 0 would let daed-guard
		# proceed to start a SECOND daed against the same
		# eBPF dataplane, which corrupts the kernel state.
		# Returning 1 makes the wrapper refuse to start.
		#
		# daed-guard distinguishes the two contexts by
		# checking whether $DAED_GUARD_CLEANUP is "start" or
		# "post-exit". In the "post-exit" context the child
		# is gone and this branch is unreachable.
		[ "${DAED_GUARD_CLEANUP:-start}" = "start" ] && return 1
		return 0
	fi

	# 1. Kill processes inside daens.
	for pid in $(ip netns pids daens 2>/dev/null); do
		kill "$pid" 2>/dev/null
	done

	if [ -n "$(ip netns pids daens 2>/dev/null)" ]; then
		sleep 1
		for pid in $(ip netns pids daens 2>/dev/null); do
			kill -9 "$pid" 2>/dev/null
		done
	fi

	# 2. Remove the daens netns. ip netns del can fail if a
	#    process still references it via /proc/<pid>/ns/net or
	#    because the umount has already happened. Try the
	#    umount/rm fallback.
	if ! ip netns del daens 2>/dev/null; then
		umount -l /run/netns/daens 2>/dev/null
		if [ -e /run/netns/daens ] && ! rm -f /run/netns/daens 2>/dev/null; then
			logger -t daed-init "cleanup: failed to remove /run/netns/daens (resource busy); a reboot may be required"
			rc=1
		fi
	fi

	# 3. Remove the dae0 veth pair.
	if ip link show dae0 >/dev/null 2>&1; then
		if ! ip link del dae0 2>/dev/null; then
			logger -t daed-init "cleanup: failed to remove dae0 veth pair"
			rc=1
		fi
	fi

	# 4. /sys/fs/bpf/daed bpffs. The eBPF programs inside are
	#    owned by the daed userspace process; if daed is not
	#    running (we already checked above) the pinned
	#    programs are no longer attached, but the bpffs
	#    directory may still exist. Removing the directory
	#    here only unlinks the bpffs inode; it does NOT
	#    detach a TC clsact filter (see the file header for
	#    the full explanation). If the eBPF leak we hit on
	#    2026-09-06 09:37 has happened, the tc clsact filter
	#    is still attached to br-lan ingress even after this
	#    rm, and a reboot is the only safe recovery. We do
	#    best-effort cleanup so an operator's manual `rm
	#    /sys/fs/bpf/daed` is not required.
	if [ -d /sys/fs/bpf/daed ]; then
		if ! rm -rf /sys/fs/bpf/daed 2>/dev/null; then
			logger -t daed-init "cleanup: /sys/fs/bpf/daed still present after rm; this is harmless but indicates the eBPF leak path. Reboot if traffic is hijacked."
		fi
	fi

	# Final verification. If any of these three still exist the
	# caller will see a non-zero exit and can decide to reboot.
	# (We do NOT check /sys/fs/bpf/daed here — see file header.)
	[ ! -e /run/netns/daens ] || return 1
	! ip netns list 2>/dev/null | awk '$1 == "daens" { found=1 } END { exit !found }' || return 1
	! ip link show dae0 >/dev/null 2>&1 || return 1

	return $rc
}
