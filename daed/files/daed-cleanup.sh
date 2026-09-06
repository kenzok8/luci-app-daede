#!/bin/sh
# daed-cleanup.sh — reaper for stale daed kernel state.
#
# Removes:
#   1. Processes inside the `daens` netns (SIGTERM, then SIGKILL after 1s)
#   2. The `daens` network namespace itself (ip netns del, with
#      umount+rm as fallback for zombie nsfs mounts)
#   3. The `dae0` veth pair in the host netns
#   4. Pinned eBPF programs and maps under /sys/fs/bpf/daed
#   5. The /sys/fs/bpf/daed directory itself
#
# Idempotent: re-running on a clean system is a no-op. Safe to call
# while daed is running — every potentially-destructive step is
# guarded by a `pgrep -f /usr/bin/daed` check.
#
# Companion to daed-guard: that wrapper calls daed_cleanup_runtime
# before exec'ing the daemon (so any stale state from a previous
# crashed run is reaped) and again after the daemon exits (so a
# OOM-kill or kernel panic also leaves the dataplane clean).
#
# This script is a kenzok8/openwrt-daede-specific evolution of the
# file originally shipped in daeuniverse/daed's `install/linux/`.
# It must remain a single function (`daed_cleanup_runtime`) so the
# `procd init.d/daed` and the `daed-guard` wrapper can both
# source it.

_daed_is_running() {
	pgrep -f "^/usr/bin/daed " >/dev/null 2>&1
}

_bpftool_available() {
	command -v bpftool >/dev/null 2>&1
}

daed_cleanup_runtime() {
	local pid p rc=0

	# If daed userspace is currently running, do not touch the
	# netns, the veth, or the eBPF dataplane. They are in active
	# use; removing them would make every connection through dae
	# hang. The wrapper calls us from a child wait context where
	# the child is already gone, but procd init.d/daed can call us
	# while the daemon is still alive (e.g. from `restart`), so
	# the check is necessary.
	if _daed_is_running; then
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

	# 4. Detach and remove pinned eBPF programs. Required because
	#    daed 0.x closes its own eBPF objects only on a successful
	#    non-reload Close; on unexpected exits (OOM-kill, kernel
	#    panic, SIGHUP) the pinned programs stay attached to
	#    br-lan ingress and keep hijacking traffic. See
	#    https://github.com/daeuniverse/dae/issues/1092 for context.
	if [ -d /sys/fs/bpf/daed ]; then
		if _bpftool_available; then
			# Best-effort detach each pinned program. The
			# `bpftool prog detach pinned <path>` form (no
			# ATTACH_TYPE) is supported by iproute2's bpftool
			# 5.x+ and is enough for the cleanup we need; it
			# detaches from every attach point. The output is
			# intentionally ignored (it is too verbose to be
			# useful here).
			for p in /sys/fs/bpf/daed/*/; do
				[ -d "$p" ] || continue
				if ! bpftool prog detach pinned "${p%/}" >/dev/null 2>&1; then
					logger -t daed-init "cleanup: bpftool prog detach failed for ${p}; tc filter may still be attached to br-lan"
					rc=1
				fi
			done
		else
			# bpftool not installed. We cannot guarantee the
			# pinned programs are detached, so we MUST NOT rm
			# the bpffs directory either — that would silently
			# leave a leaked eBPF program hijacking traffic.
			# Bail out non-zero so the operator knows they
			# need to install bpftool-full or reboot.
			#
			# This is the path kenzok8 2026.08.21-r1 / 2026.08.28-r4
			# take by default on stock OpenWrt, and is the
			# reason the eBPF leak we hit on 2026-09-06 09:37
			# persisted until the next reboot — see Codex
			# review on kenzok8/openwrt-daede#70 (P1).
			logger -t daed-init "cleanup: bpftool not found; cannot detach pinned eBPF programs. Install bpftool-full and re-run, or reboot. Skipping bpffs removal."
			rc=1
		fi

		# 5. Remove the bpffs directory itself. Only safe when
		#    every program above detached cleanly (or there were
		#    none). If detach failed, the pinned programs are
		#    still attached to br-lan; rm'ing the bpffs does
		#    NOT un-attach them, and a final-verification check
		#    that only looks at the filesystem would falsely
		#    report success.
		if [ "$rc" -eq 0 ]; then
			if ! rm -rf /sys/fs/bpf/daed 2>/dev/null; then
				logger -t daed-init "cleanup: failed to remove /sys/fs/bpf/daed"
				rc=1
			fi
		fi
	fi

	# Final verification. If any of these four still exist the
	# caller will see a non-zero exit and can decide to reboot.
	[ ! -e /run/netns/daens ] || return 1
	! ip netns list 2>/dev/null | awk '$1 == "daens" { found=1 } END { exit !found }' || return 1
	! ip link show dae0 >/dev/null 2>&1 || return 1
	[ ! -e /sys/fs/bpf/daed ] || return 1

	return $rc
}
