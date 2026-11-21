# shellcheck shell=bash
# shellcheck disable=SC2329
# The health sync's timer (HL-FR-13, ST247), sourced by setup.sh. The units run as the checkout's user,
# so the checkout gets no root-owned files. That user joins the docker group (restarts Gatus) and the
# monitor's group, and the monitor folders become group-writable with setgid (config.yaml, the marker).
HEALTH_SYNC_UNITS="${HEALTH_SYNC_UNITS:-/etc/systemd/system}"
HS_SRC="$REPO_DIR/compose/monitor"

# The unit text to install: ExecStart and User= filled in for this checkout.
hs_unit_text() {
	if [ "$1" != health-sync.service ]; then
		cat "$HS_SRC/$1"
		return 0
	fi
	sed -e "s|^ExecStart=.*|ExecStart=$HS_SRC/health-sync.sh|" \
		-e "s|^Type=oneshot|Type=oneshot\nUser=$RUN_USER|" "$HS_SRC/$1"
}

# Read only: both units match what would be installed.
hs_units_ok() {
	local unit
	for unit in health-sync.service health-sync.timer; do
		cmp -s <(hs_unit_text "$unit") "$HEALTH_SYNC_UNITS/$unit" 2>/dev/null || return 1
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

# Installs the units that differ, then enables and starts the timer: one change per file, one for the
# reload, one for the timer. A rerun counts none.
hs_units() {
	local unit units_changed=0
	step "health-sync: units and the timer"
	for unit in health-sync.service health-sync.timer; do
		if ! cmp -s <(hs_unit_text "$unit") "$HEALTH_SYNC_UNITS/$unit" 2>/dev/null; then
			change "install $HEALTH_SYNC_UNITS/$unit (ExecStart and User= for this checkout) (sudo)" hs_install_unit "$unit"
			units_changed=1
		fi
	done
	if [ "$units_changed" -eq 1 ]; then change "systemctl daemon-reload (sudo)" sudo systemctl daemon-reload; fi
	if systemctl is-enabled --quiet health-sync.timer 2>/dev/null && systemctl is-active --quiet health-sync.timer; then
		step "health-sync.timer is enabled and running"
	else
		change "systemctl enable --now health-sync.timer (sudo)" sudo systemctl enable --now health-sync.timer
	fi
}

# Without systemd nothing changes and the command is printed. The group grants apply at the next start.
hs_run() {
	if ! systemd_present; then
		echo "health-sync timer: no systemd here, so it is not installed or enabled. On a systemd host ./setup.sh does both; by hand: sudo systemctl enable --now health-sync.timer"
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
		echo "health-sync timer: not applicable (no systemd)"
	elif hs_units_ok && systemctl is-enabled --quiet health-sync.timer 2>/dev/null && systemctl is-active --quiet health-sync.timer; then
		report ok "health-sync timer" "units current, enabled and running"
	else
		report missing "health-sync timer" "units not installed or current, or the timer is not enabled and running"
	fi
}
