# shellcheck shell=bash
# shellcheck disable=SC2329
# The monitor's timers, sourced by setup.sh: the health sync (HL-FR-13, ST247) and the outside heartbeat
# (HL-FR-09, ST257). The units run as the checkout's user, so the checkout gets no root-owned files. That
# user joins the docker group (restarts Gatus) and the monitor's group, and the monitor folders become
# group-writable with setgid (config.yaml, the marker). The heartbeat reads compose/monitor/.env, which
# only that user can read, so it runs as the same user.
HEALTH_SYNC_UNITS="${HEALTH_SYNC_UNITS:-/etc/systemd/system}"
HS_SRC="$REPO_DIR/compose/monitor"
HS_UNITS=(health-sync.service health-sync.timer heartbeat.service heartbeat.timer)
HS_TIMERS=(health-sync.timer heartbeat.timer)

# The unit text to install: for a service, ExecStart (the checkout's script of the same name) and User= filled in.
hs_unit_text() {
	if [ "${1##*.}" != service ]; then
		cat "$HS_SRC/$1"
		return 0
	fi
	sed -e "s|^ExecStart=.*|ExecStart=$HS_SRC/${1%.service}.sh|" \
		-e "s|^Type=oneshot|Type=oneshot\nUser=$RUN_USER|" "$HS_SRC/$1"
}

# Read only: every unit matches what would be installed.
hs_units_ok() {
	local unit
	for unit in "${HS_UNITS[@]}"; do
		cmp -s <(hs_unit_text "$unit") "$HEALTH_SYNC_UNITS/$unit" 2>/dev/null || return 1
	done
}

# Read only: every timer is enabled and running.
hs_timers_running() {
	local timer
	for timer in "${HS_TIMERS[@]}"; do
		systemctl is-enabled --quiet "$timer" 2>/dev/null && systemctl is-active --quiet "$timer" 2>/dev/null || return 1
	done
}

hs_install_unit() {
	local tmp
	tmp="$(mktemp)"
	hs_unit_text "$1" > "$tmp"
	sudo install -D -m 0644 "$tmp" "$HEALTH_SYNC_UNITS/$1"
	rm -f "$tmp"
}

# Read only: the checkout's user is in docker and the monitor's group, and both folders are group-writable.
hs_perms_ready() {
	local dir mode groups
	groups=" $(id -nG "$RUN_USER" 2>/dev/null) "
	[[ $groups == *" docker "* && $groups == *" $(id -gn "$MONITOR_USER" 2>/dev/null) "* ]] || return 1
	for dir in "$MONITOR_DIR" "$GATUS_DIR"; do
		mode="$(stat -c %A "$dir" 2>/dev/null)" || return 1
		[ "${mode:5:1}" = w ] || return 1
	done
}

hs_grant() {
	sudo usermod -aG docker "$RUN_USER"
	sudo usermod -aG "$(id -gn "$MONITOR_USER")" "$RUN_USER"
	sudo chmod 2775 "$MONITOR_DIR" "$GATUS_DIR"
}

# Installs the units that differ, then enables and starts each timer: one change per file, one for the
# reload, one per timer. A rerun counts none.
hs_units() {
	local unit timer units_changed=0
	step "monitor timers: units, then health-sync and heartbeat enabled"
	for unit in "${HS_UNITS[@]}"; do
		if ! cmp -s <(hs_unit_text "$unit") "$HEALTH_SYNC_UNITS/$unit" 2>/dev/null; then
			change "install $HEALTH_SYNC_UNITS/$unit (ExecStart and User= for this checkout) (sudo)" hs_install_unit "$unit"
			units_changed=1
		fi
	done
	if [ "$units_changed" -eq 1 ]; then change "systemctl daemon-reload (sudo)" sudo systemctl daemon-reload; fi
	for timer in "${HS_TIMERS[@]}"; do
		if systemctl is-enabled --quiet "$timer" 2>/dev/null && systemctl is-active --quiet "$timer" 2>/dev/null; then
			step "$timer is enabled and running"
		else
			change "systemctl enable --now $timer (sudo)" sudo systemctl enable --now "$timer"
		fi
	done
}

# Without systemd nothing changes and the command is printed. The group grants apply at the next start.
hs_run() {
	if ! systemd_present; then
		echo "monitor timers (health-sync, heartbeat): no systemd here, so they are not installed or enabled. On a systemd host ./setup.sh does them; by hand: sudo systemctl enable --now health-sync.timer heartbeat.timer"
		return 0
	fi
	hs_units
	if hs_perms_ready; then
		step "$RUN_USER is in docker and the monitor's group; the monitor folders are group-writable"
	else
		change "add $RUN_USER to the docker and the monitor's groups; make $MONITOR_DIR and $GATUS_DIR group-writable (sudo)" hs_grant
	fi
}

# --check: read only.
hs_check() {
	if hs_perms_ready; then
		report ok "health-sync user $RUN_USER" "in docker and the monitor group; folders group-writable"
	else
		report missing "health-sync user $RUN_USER" "not in docker and the monitor group, or folders not group-writable"
	fi
	if ! systemd_present; then
		echo "monitor timers (health-sync, heartbeat): not applicable (no systemd)"
	elif hs_units_ok && hs_timers_running; then
		report ok "monitor timers (health-sync, heartbeat)" "units current, enabled and running"
	else
		report missing "monitor timers (health-sync, heartbeat)" "units not installed or current, or a timer is not enabled and running"
	fi
}
