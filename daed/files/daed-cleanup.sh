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
			for p in /sys/fs/bpf/daed/*/; do
				[ -d "$p" ] || continue
				bpftool prog detach pinned "${p%/}" 2>/dev/null || true
			done
		else
			logger -t daed-init "cleanup: bpftool not found; cannot detach pinned eBPF programs. Install bpftool-full and re-run, or reboot."
		fi

		# 5. Remove the bpffs directory itself. Even if bpftool
		#    detach failed, the kernel will let us rm a directory
		#    that contains only detached programs.
		if ! rm -rf /sys/fs/bpf/daed 2>/dev/null; then
			logger -t daed-init "cleanup: failed to remove /sys/fs/bpf/daed"
			rc=1
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
