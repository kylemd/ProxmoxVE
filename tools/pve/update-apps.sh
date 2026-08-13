#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: BvdBerg01 | Co-Author: remz1337
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# =============================================================================
# CONFIGURATION VARIABLES
# Set these variables to skip interactive prompts (Whiptail dialogs)
# =============================================================================
# var_backup: Enable/disable backup before update
#   Options: "yes" | "no" | "" (empty = interactive prompt)
var_backup="${var_backup:-}"

# var_backup_storage: Storage location for backups (only used if var_backup=yes)
#   Options: Storage name from /etc/pve/storage.cfg (e.g., "local", "nas-backup")
#   Leave empty for interactive selection
var_backup_storage="${var_backup_storage:-}"

# var_container: Which containers to update
#   Options:
#     - "all"         : All containers with community-scripts tags
#     - "all_running" : Only running containers with community-scripts tags
#     - "all_stopped" : Only stopped containers with community-scripts tags
#     - "101,102,109" : Comma-separated list of specific container IDs
#     - ""            : Interactive selection via Whiptail
var_container="${var_container:-}"

# var_unattended: Run updates without user interaction inside containers
#   Options: "yes" | "no" | "" (empty = interactive prompt)
var_unattended="${var_unattended:-}"

# var_skip_confirm: Skip initial confirmation dialog
#   Options: "yes" | "no" (default: no)
var_skip_confirm="${var_skip_confirm:-no}"

# var_auto_reboot: Automatically reboot containers that require it after update
#   Options: "yes" | "no" | "" (empty = interactive prompt)
var_auto_reboot="${var_auto_reboot:-}"

# var_continue_on_error: Continue updating remaining containers if one update fails
#   Options: "yes" | "no" (default: no = stop on first error)
#   Note: a failed stateful update is quarantined; this tool never restores it automatically.
var_continue_on_error="${var_continue_on_error:-no}"

# var_report_only: Read already-verified local artifacts and report update availability.
#   Options: "yes" | "no" (default: no)
#   Requires PHS_ARTIFACT_DIR and PHS_ARTIFACT_MANIFEST. It never persistently
#   mutates guests or the Proxmox host, and stopped guests are reported SKIPPED
#   without starting. Read-only guest inspection may use a temporary host file.
var_report_only="${var_report_only:-no}"

# var_dry_run: Legacy compatibility alias for var_report_only.
#   Options: "yes" | "no" (default: no)
var_dry_run="${var_dry_run:-no}"

# var_tags: Optionally override the tags used for auto-detection
#   Options: "community-script|proxmox-helper-scripts" (default)
var_tags="${var_tags:-community-script|proxmox-helper-scripts}"

# PHS_ARTIFACT_DIR: Local trust root used only by var_report_only=yes.
# PHS_ARTIFACT_MANIFEST: Manifest inside that root. Each non-empty line is:
#   <64 lowercase-or-uppercase SHA256 hex characters><whitespace><relative path>
# Required entries are misc/core.func, misc/api.func, and ct/<service>.sh. The
# manifest and every referenced file must resolve under PHS_ARTIFACT_DIR.
PHS_ARTIFACT_DIR="${PHS_ARTIFACT_DIR:-}"
PHS_ARTIFACT_MANIFEST="${PHS_ARTIFACT_MANIFEST:-}"

# Legacy dry-run is intentionally upgraded to the stricter report-only contract.
if [[ "$var_dry_run" == "yes" ]]; then
  var_report_only="yes"
fi

if [[ "$var_report_only" != "yes" && "$var_report_only" != "no" ]]; then
  printf '%s\n' "ERROR: var_report_only must be yes or no" >&2
  exit 64
fi

function artifact_fail() {
  printf '%s\n' "ERROR: report-only artifact verification failed: $*" >&2
  exit 65
}

function artifact_safe_relative_path() {
  local relative_path="$1"
  [[ "$relative_path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  [[ "/$relative_path/" != *"/../"* && "$relative_path" != *"//"* ]] || return 1
  return 0
}

function artifact_path_within_root() {
  local candidate="$1"
  local resolved
  resolved=$(readlink -f -- "$candidate") || return 1
  [[ -f "$resolved" && "$resolved" == "$PHS_ARTIFACT_ROOT/"* ]] || return 1
  printf '%s\n' "$resolved"
}

function bootstrap_report_only_artifacts() {
  [[ -n "$PHS_ARTIFACT_DIR" ]] || artifact_fail "PHS_ARTIFACT_DIR is required"
  [[ -n "$PHS_ARTIFACT_MANIFEST" ]] || artifact_fail "PHS_ARTIFACT_MANIFEST is required"
  PHS_ARTIFACT_ROOT=$(readlink -f -- "$PHS_ARTIFACT_DIR") || artifact_fail "artifact directory is not resolvable"
  [[ -d "$PHS_ARTIFACT_ROOT" ]] || artifact_fail "artifact directory is not a directory"

  local manifest_candidate
  if [[ "$PHS_ARTIFACT_MANIFEST" == /* ]]; then
    manifest_candidate="$PHS_ARTIFACT_MANIFEST"
  else
    manifest_candidate="$PHS_ARTIFACT_ROOT/$PHS_ARTIFACT_MANIFEST"
  fi
  PHS_ARTIFACT_MANIFEST_PATH=$(artifact_path_within_root "$manifest_candidate") || artifact_fail "manifest is missing or outside artifact directory"

  verify_report_only_artifact "misc/core.func"
  PHS_ARTIFACT_CORE="$PHS_VERIFIED_ARTIFACT"
  verify_report_only_artifact "misc/api.func"
  PHS_ARTIFACT_API="$PHS_VERIFIED_ARTIFACT"
}

function verify_report_only_artifact() {
  local requested_path="$1" manifest_line expected_hash manifest_path actual_hash match_count=0
  artifact_safe_relative_path "$requested_path" || artifact_fail "unsafe relative path '$requested_path'"

  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ -z "$manifest_line" ]] && continue
    if [[ ! "$manifest_line" =~ ^([[:xdigit:]]{64})[[:space:]]+([A-Za-z0-9][A-Za-z0-9._/-]*)$ ]]; then
      artifact_fail "manifest line has invalid schema"
    fi
    expected_hash="${BASH_REMATCH[1],,}"
    manifest_path="${BASH_REMATCH[2]}"
    artifact_safe_relative_path "$manifest_path" || artifact_fail "manifest contains unsafe path '$manifest_path'"
    if [[ "$manifest_path" == "$requested_path" ]]; then
      ((match_count += 1))
      [[ "$match_count" -eq 1 ]] || artifact_fail "manifest repeats '$requested_path'"
      PHS_VERIFIED_ARTIFACT=$(artifact_path_within_root "$PHS_ARTIFACT_ROOT/$manifest_path") || artifact_fail "required '$requested_path' is missing or escapes artifact directory"
      actual_hash=$(sha256sum -- "$PHS_VERIFIED_ARTIFACT" | awk '{print tolower($1)}') || artifact_fail "cannot hash '$requested_path'"
      [[ "$actual_hash" == "$expected_hash" ]] || artifact_fail "digest mismatch for '$requested_path'"
    fi
  done <"$PHS_ARTIFACT_MANIFEST_PATH"

  [[ "$match_count" -eq 1 ]] || artifact_fail "manifest has no digest for '$requested_path'"
}

# =============================================================================
# JSON CONFIG EXPORT
# Run with --export-config to output current configuration as JSON
# =============================================================================

function export_config_json() {
  cat <<EOF
{
  "var_backup": "${var_backup}",
  "var_backup_storage": "${var_backup_storage}",
  "var_container": "${var_container}",
  "var_unattended": "${var_unattended}",
  "var_skip_confirm": "${var_skip_confirm}",
  "var_auto_reboot": "${var_auto_reboot}",
  "var_continue_on_error": "${var_continue_on_error}",
  "var_report_only": "${var_report_only}",
  "var_dry_run": "${var_dry_run}",
  "var_tags": "${var_tags}"
}
EOF
}

function print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Update LXC containers created with community-scripts.

Options:
  --help              Show this help message
  --export-config     Export current configuration as JSON

Environment Variables:
  var_backup          Enable backup before update (yes/no)
  var_backup_storage  Storage location for backups
  var_container       Container selection (all/all_running/all_stopped/101,102,...)
  var_unattended         Run updates unattended (yes/no; currently fail-closed)
  var_skip_confirm       Skip initial confirmation (yes/no)
  var_auto_reboot        Auto-reboot containers if required (yes/no)
  var_continue_on_error  Continue to next container on update failure (yes/no)
  var_report_only        Zero-mutation report using verified local artifacts (yes/no)
  var_dry_run            Legacy alias for var_report_only=yes
  var_tags               Optionally override auto-detection tags ("prod|smb|community-script")
  PHS_ARTIFACT_DIR       Local report-only trust root
  PHS_ARTIFACT_MANIFEST  SHA256 manifest path, relative to the trust root or absolute within it

Examples:
  # Run interactively
  $(basename "$0")

  # Report-only: use an already verified local artifact bundle; no guest or host mutation
  PHS_ARTIFACT_DIR=/srv/phs-artifacts PHS_ARTIFACT_MANIFEST=manifest.sha256 \
    var_container=all_running var_skip_confirm=yes var_report_only=yes $(basename "$0")

  # Legacy compatibility: var_dry_run enforces the same report-only trust-root contract
  PHS_ARTIFACT_DIR=/srv/phs-artifacts PHS_ARTIFACT_MANIFEST=manifest.sha256 \
    var_container=all_running var_skip_confirm=yes var_dry_run=yes $(basename "$0")

  # Export current configuration
  $(basename "$0") --export-config
EOF
}

# Handle command line arguments
case "${1:-}" in
--help | -h)
  print_usage
  exit 0
  ;;
--export-config)
  export_config_json
  exit 0
  ;;
esac

# Report-only sources only verified local artifacts. Unattended live execution is
# deliberately disabled until its disposable-LXC and verified guest-execution path exists.
if [[ "$var_report_only" == "yes" ]]; then
  bootstrap_report_only_artifacts
  source "$PHS_ARTIFACT_CORE"
  source "$PHS_ARTIFACT_API"
elif [[ "$var_unattended" == "yes" ]]; then
  printf '%s\n' "ERROR: unattended live updates are disabled: disposable-LXC validation and the verified guest execution path are not yet enabled." >&2
  exit 65
else
  source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/core.func)
  source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
fi
if [[ "$var_report_only" != "yes" ]]; then
  declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "update-apps" "pve"
fi

# =============================================================================

function header_info {
  clear
  cat <<"EOF"
    __   _  ________   __  __          __      __
   / /  | |/ / ____/  / / / /___  ____/ /___ _/ /____
  / /   |   / /      / / / / __ \/ __  / __ `/ __/ _ \
 / /___/   / /___   / /_/ / /_/ / /_/ / /_/ / /_/  __/
/_____/_/|_\____/   \____/ .___/\__,_/\__,_/\__/\___/
                        /_/
EOF
}

function sanitize_service_name() {
  local name="${1//$'\r'/}"
  name="${name//$'\n'/}"
  [[ -z "$name" ]] && return 1
  [[ "$name" == *'#!'* ]] && return 1
  [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]] && return 1
  return 0
}

function validate_service_script() {
  local name="$1"
  sanitize_service_name "$name" || return 1
  if [[ "$var_report_only" == "yes" ]]; then
    verify_report_only_artifact "ct/${name}.sh"
    return 0
  fi
  curl -fsSL --max-time 10 -o /dev/null \
    "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/${name}.sh" 2>/dev/null
}

function detect_service() {
  local container="$1"
  local tmpdir update_file
  service=""
  tmpdir=$(mktemp -d)
  update_file="$tmpdir/update"
  pct pull "$container" /usr/bin/update "$update_file" 2>/dev/null || true
  if [[ ! -s "$update_file" ]]; then
    rm -rf "$tmpdir"
    return 1
  fi
  service=$(grep -oE '/ct/[a-zA-Z0-9._-]+\.sh' "$update_file" 2>/dev/null | head -n1 | sed 's|.*/ct/||; s|\.sh$||')
  rm -rf "$tmpdir"
}

function dry_run_container() {
  local container="$1"
  local service="$2"
  local mode_label="REPORT-ONLY"

  # Extract app name and source repo directly from check_for_gh_release call in the ct script
  # Pattern: check_for_gh_release "appname" "owner/repo"
  local check_line app_name app_lc source_repo
  check_line=$(echo "$script" | grep -m1 'check_for_gh_release')

  if [[ -z "$check_line" ]]; then
    echo -e "${YW}[${mode_label}]${CL} Container $container ($service): no check_for_gh_release found — skipping"
    DRY_RUN_RESULT="no check_for_gh_release found — skipping"
    return
  fi

  app_name=$(echo "$check_line" | cut -d'"' -f2)
  source_repo=$(echo "$check_line" | cut -d'"' -f4)
  app_lc=$(echo "${app_name,,}" | tr -d ' ')

  if [[ -z "$source_repo" || "$source_repo" != *"/"* ]]; then
    echo -e "${YW}[${mode_label}]${CL} Container $container ($service): cannot parse source repo — skipping"
    DRY_RUN_RESULT="cannot parse source repo — skipping"
    return
  fi

  # Read installed version from container (stored by check_for_gh_release as ~/.<appname>)
  local current_version
  current_version=$(pct exec "$container" -- bash -c "cat \$HOME/.${app_lc} 2>/dev/null" 2>/dev/null || true)
  current_version="${current_version#v}"

  # Query latest release from GitHub API
  local latest_version
  latest_version=$(curl -sSL --max-time 10 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${source_repo}/releases/latest" 2>/dev/null |
    grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')

  if [[ -z "$latest_version" ]]; then
    echo -e "${YW}[${mode_label}]${CL} Container $container ($service): cannot fetch latest version from $source_repo"
    DRY_RUN_RESULT="cannot fetch latest version from $source_repo"
    return
  fi

  if [[ -z "$current_version" ]]; then
    echo -e "${BL}[${mode_label}]${CL} Container $container ($service): installed version unknown, latest: ${latest_version} (${source_repo})"
    DRY_RUN_RESULT="version unknown — latest: ${latest_version}"
  elif [[ "$current_version" == "$latest_version" ]]; then
    echo -e "${GN}[${mode_label}]${CL} Container $container ($service): up to date (${current_version})"
    DRY_RUN_RESULT="up to date (${current_version})"
  else
    echo -e "${YW}[${mode_label}]${CL} Container $container ($service): update available ${current_version} → ${latest_version}"
    DRY_RUN_RESULT="update available ${current_version} → ${latest_version}"
  fi
}

function backup_container() {
  msg_info "Creating backup for container $1"
  vzdump $1 --compress zstd --storage $STORAGE_CHOICE -notes-template "{{guestname}} - community-scripts backup updater" >/dev/null 2>&1
  status=$?

  if [ $status -eq 0 ]; then
    msg_ok "Backup created"
  else
    msg_error "Backup failed for container $1"
    exit 235
  fi
}

function get_backup_storages() {
  STORAGES=$(awk '
/^[a-z]+:/ {
    if (name != "") {
        if (has_backup || (!has_content && type == "dir")) print name
    }
    split($0, a, ":")
    type = a[1]
    name = a[2]
    gsub(/^[ \t]+|[ \t]+$/, "", name)
    has_content = 0
    has_backup = 0
}
/^[ \t]*content/ {
    has_content = 1
    if ($0 ~ /backup/) has_backup = 1
}
END {
    if (name != "") {
        if (has_backup || (!has_content && type == "dir")) print name
    }
}
' /etc/pve/storage.cfg)
}

# Structured result tracking for the final summary report
# Each entry: "CTID|service|STATUS|details"
declare -a UPDATE_RESULTS=()
function log_result() {
  # log_result <ctid> <service> <STATUS> <details>
  UPDATE_RESULTS+=("${1}|${2}|${3}|${4}")
}

function print_summary() {
  [[ "${#UPDATE_RESULTS[@]}" -gt 0 ]] || return 0

  local entry _ctid _svc _status _details _color
  SEPARATOR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  HEADER=$(printf "  %-8s  %-22s  %-14s  %s" "CTID" "Service" "Status" "Details")
  echo ""
  echo "$SEPARATOR"
  echo "$HEADER"
  echo "$SEPARATOR"
  for entry in "${UPDATE_RESULTS[@]}"; do
    IFS='|' read -r _ctid _svc _status _details <<<"$entry"
    case "$_status" in
    OK) _color="${GN}" ;;
    FAILED | QUARANTINED | FAILED/QUARANTINED) _color="${RD}" ;;
    *) _color="${YW}" ;;
    esac
    printf "  %-8s  %-22s  ${_color}%-14s${CL}  %s\n" "$_ctid" "$_svc" "$_status" "$_details"
  done
  echo "$SEPARATOR"
  echo ""

  # Report-only deliberately has no persistent log. Live interactive mode retains
  # the historic log only after its separate, mutation-capable path is selected.
  if [[ "$var_report_only" != "yes" ]]; then
    echo "Full log: $LOG_FILE"
    echo ""
    {
      echo ""
      echo "Update finished: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "$SEPARATOR"
      echo "$HEADER"
      echo "$SEPARATOR"
      for entry in "${UPDATE_RESULTS[@]}"; do
        IFS='|' read -r _ctid _svc _status _details <<<"$entry"
        printf "  %-8s  %-22s  %-14s  %s\n" "$_ctid" "$_svc" "$_status" "$_details"
      done
      echo "$SEPARATOR"
    } >>"$LOG_FILE"
  fi
}

function report_only_container() {
  local container="$1" status

  status=$(pct status "$container" 2>/dev/null || true)
  if [[ "$status" != "status: running" ]]; then
    echo -e "${YW}[REPORT-ONLY]${CL} Container $container: SKIPPED (not running; it will not be started)"
    log_result "$container" "(not inspected)" "SKIPPED" "Not running; report-only never starts guests"
    return 0
  fi

  if ! detect_service "$container" || [[ -z "$service" ]]; then
    echo -e "${RD}[REPORT-ONLY]${CL} Container $container: FAILED (cannot read a service from /usr/bin/update)"
    log_result "$container" "(unknown)" "FAILED" "Cannot read a service from /usr/bin/update"
    return 65
  fi
  if ! sanitize_service_name "$service"; then
    echo -e "${RD}[REPORT-ONLY]${CL} Container $container: FAILED (unsafe service filename)"
    log_result "$container" "(unknown)" "FAILED" "Unsafe service filename from /usr/bin/update"
    return 65
  fi

  # This verifies the manifest digest and containment before the CT script is read.
  validate_service_script "$service"
  script=$(<"$PHS_VERIFIED_ARTIFACT")
  dry_run_container "$container" "$service"
  log_result "$container" "$service" "REPORT-ONLY" "${DRY_RUN_RESULT:-version check only}"
  return 0
}

function run_report_only() {
  local container report_status=0
  for container in $CHOICE; do
    if ! report_only_container "$container"; then
      report_status=65
      # A trust/metadata failure is fail-closed even when continuation was requested.
      return "$report_status"
    fi
  done
  return "$report_status"
}

header_info

# =============================================================================
# LOGGING SETUP
# Live interactive mode writes key events to a timestamped log. Report-only
# mode leaves LOG_FILE empty and its logger is a no-op: it must create nothing.
# =============================================================================
LOG_DIR="/usr/local/community-scripts/update_apps"
LOG_FILE=""
if [[ "$var_report_only" == "yes" ]]; then
  function log_write() { :; }
else
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/$(date '+%Y%m%d_%H%M%S').log"
  echo "Update started: $(date '+%Y-%m-%d %H:%M:%S')" >"$LOG_FILE"
  function log_write() {
    echo "[$(date '+%H:%M:%S')] $*" >>"$LOG_FILE"
  }
fi

# Skip confirmation if var_skip_confirm is set to yes
if [[ "$var_skip_confirm" != "yes" ]]; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "LXC App Update" --yesno "This will update apps in LXCs installed by Helper-Scripts. Proceed?" 10 58 || exit
fi

tags_formatted="${var_tags//|/, }"
msg_info "Loading all possible LXC containers from Proxmox VE with tags: ${tags_formatted}. This may take a few seconds..."
NODE=$(hostname)
containers=$(pct list | tail -n +2 | awk '{print $0 " " $4}')

if [ -z "$containers" ]; then
  whiptail --title "LXC Container Update" --msgbox "No LXC containers available!" 10 60
  exit 234
fi

menu_items=()
FORMAT="%-10s %-15s %-10s"
TAGS="${var_tags:-community-script|proxmox-helper-scripts}"

while read -r container; do
  container_id=$(echo $container | awk '{print $1}')
  container_name=$(echo $container | awk '{print $2}')
  container_status=$(echo $container | awk '{print $3}')
  formatted_line=$(printf "$FORMAT" "$container_name" "$container_status")
  if pct config "$container_id" | grep -qE "[^-][; ](${TAGS}).*"; then
    menu_items+=("$container_id" "$formatted_line" "OFF")
  fi
done <<<"$containers"
msg_ok "Loaded $((${#menu_items[@]} / 3)) containers"

# Determine container selection based on var_container
if [[ -n "$var_container" ]]; then
  case "$var_container" in
  all)
    # Select all containers with matching tags
    CHOICE=""
    for ((i = 0; i < ${#menu_items[@]}; i += 3)); do
      CHOICE="$CHOICE ${menu_items[$i]}"
    done
    CHOICE=$(echo "$CHOICE" | xargs)
    ;;
  all_running)
    # Select only running containers with matching tags
    CHOICE=""
    for ((i = 0; i < ${#menu_items[@]}; i += 3)); do
      cid="${menu_items[$i]}"
      if pct status "$cid" 2>/dev/null | grep -q "running"; then
        CHOICE="$CHOICE $cid"
      fi
    done
    CHOICE=$(echo "$CHOICE" | xargs)
    ;;
  all_stopped)
    # Select only stopped containers with matching tags
    CHOICE=""
    for ((i = 0; i < ${#menu_items[@]}; i += 3)); do
      cid="${menu_items[$i]}"
      if pct status "$cid" 2>/dev/null | grep -q "stopped"; then
        CHOICE="$CHOICE $cid"
      fi
    done
    CHOICE=$(echo "$CHOICE" | xargs)
    ;;
  *)
    # Assume comma-separated list of container IDs
    CHOICE=$(echo "$var_container" | tr ',' ' ')
    ;;
  esac

  if [[ -z "$CHOICE" ]]; then
    msg_error "No containers matched the selection criteria: $var_container ${var_tags:-community-script|proxmox-helper-scripts}"
    exit 234
  fi
  msg_ok "Selected containers: $CHOICE"
else
  CHOICE=$(whiptail --title "LXC Container Update" \
    --checklist "Select LXC containers to update:" 25 60 13 \
    "${menu_items[@]}" 3>&2 2>&1 1>&3 | tr -d '"')

  if [ -z "$CHOICE" ]; then
    whiptail --title "LXC Container Update" \
      --msgbox "No containers selected!" 10 60
    exit 0
  fi
fi

if [[ "$var_report_only" == "yes" ]]; then
  run_report_only
  report_status=$?
  header_info
  echo -e "${GN}Report-only complete. No containers or host state were modified.${CL}\n"
  print_summary
  exit "$report_status"
fi

header_info

# Determine backup choice based on var_backup
# Interactive legacy path only. Report-only exits above before backup, resource,
# guest execution, shutdown/reboot, or persistent-log code can be reached.
if [[ -n "$var_backup" ]]; then
  BACKUP_CHOICE="$var_backup"
else
  BACKUP_CHOICE="no"
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "LXC Container Update" --yesno "Do you want to backup your containers before update?" 10 58); then
    BACKUP_CHOICE="yes"
  fi
fi

# Silent guest execution is deliberately unavailable in every entry path until
# the disposable-LXC proof and verified guest-execution contract exist. This
# also closes the historical interactive prompt path, not only var_unattended.
UNATTENDED_UPDATE="no"

if [ "$BACKUP_CHOICE" == "yes" ]; then
  get_backup_storages

  if [ -z "$STORAGES" ]; then
    msg_error "No storage with 'backup' support found!"
    exit 119
  fi

  # Determine storage based on var_backup_storage
  if [[ -n "$var_backup_storage" ]]; then
    # Validate that the specified storage exists and supports backups
    if echo "$STORAGES" | grep -qw "$var_backup_storage"; then
      STORAGE_CHOICE="$var_backup_storage"
      msg_ok "Using backup storage: $STORAGE_CHOICE"
    else
      msg_error "Specified backup storage '$var_backup_storage' not found or doesn't support backups!"
      msg_info "Available storages: $(echo $STORAGES | tr '\n' ' ')"
      exit 119
    fi
  else
    MENU_ITEMS=()
    for STORAGE in $STORAGES; do
      MENU_ITEMS+=("$STORAGE" "")
    done

    STORAGE_CHOICE=$(whiptail --title "Select storage device" --menu "Select a storage device (Only storage devices with 'backup' support are listed):" 15 50 5 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)

    if [ -z "$STORAGE_CHOICE" ]; then
      msg_error "No storage selected!"
      exit 0
    fi
  fi
fi

UPDATE_CMD="update;"

containers_needing_reboot=()
for container in $CHOICE; do
  echo -e "${BL}[INFO]${CL} Updating container $container"
  log_write "Container $container: starting"

  if [ "$BACKUP_CHOICE" == "yes" ]; then
    backup_container $container
  fi

  os=$(pct config "$container" | awk '/^ostype/ {print $2}')
  status=$(pct status $container)
  template=$(pct config $container | grep -q "template:" && echo "true" || echo "false")
  if [ "$template" == "false" ] && [ "$status" == "status: stopped" ]; then
    echo -e "${BL}[Info]${GN} Starting${BL} $container ${CL} \n"
    pct start $container
    echo -e "${BL}[Info]${GN} Waiting For${BL} $container${CL}${GN} To Start ${CL} \n"
    sleep 5
  fi

  #1) Detect service using the service name in the update command
  detect_service $container

  #1.1) If update script not detected or service name is invalid, skip
  if [ -z "${service}" ] || ! sanitize_service_name "${service}"; then
    echo -e "${RD}[ERROR]${CL} Could not detect a valid service name for container $container"
    log_result "$container" "(unknown)" "ERROR" "Invalid or missing service name in /usr/bin/update"
    log_write "Container $container: ERROR — invalid or missing service name"
    continue
  fi

  if ! validate_service_script "${service}"; then
    echo -e "${RD}[ERROR]${CL} Service '${service}' does not resolve to ct/${service}.sh"
    log_result "$container" "${service}" "ERROR" "No matching ct/${service}.sh script found"
    log_write "Container $container: ERROR — ct/${service}.sh not found"
    continue
  fi

  echo -e "${BL}[INFO]${CL} Detected service: ${GN}${service}${CL}"
  log_write "Container $container: detected service '${service}'"

  #2) Extract service build/update resource requirements from config/installation file
  script=$(curl -fsSL "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/${service}.sh")

  #2.1) Check if the script downloaded successfully
  if [ $? -ne 0 ] || [ -z "${script}" ]; then
    echo -e "${RD}[ERROR]${CL} Failed to download ct/${service}.sh"
    log_result "$container" "${service}" "ERROR" "Failed to download ct/${service}.sh"
    log_write "Container $container (${service}): ERROR — failed to download install script"
    continue
  fi

  config=$(pct config "$container")
  build_cpu=$(echo "$script" | { grep -m 1 "var_cpu" || test $? = 1; } | sed 's|.*=||g' | sed 's|"||g' | sed 's|.*var_cpu:-||g' | sed 's|}||g')
  build_ram=$(echo "$script" | { grep -m 1 "var_ram" || test $? = 1; } | sed 's|.*=||g' | sed 's|"||g' | sed 's|.*var_ram:-||g' | sed 's|}||g')
  run_cpu=$(echo "$script" | { grep -m 1 "pct set \$CTID -cores" || test $? = 1; } | sed 's|.*cores ||g')
  run_ram=$(echo "$script" | { grep -m 1 "pct set \$CTID -memory" || test $? = 1; } | sed 's|.*memory ||g')
  current_cpu=$(echo "$config" | grep -m 1 "cores:" | sed 's|cores: ||g')
  current_ram=$(echo "$config" | grep -m 1 "memory:" | sed 's|memory: ||g')

  #Test if all values are valid (>0)
  if [ -z "${run_cpu}" ] || [ "$run_cpu" -le 0 ]; then
    #echo "No valid value found for run_cpu. Assuming same as current configuration."
    run_cpu=$current_cpu
  fi

  if [ -z "${run_ram}" ] || [ "$run_ram" -le 0 ]; then
    #echo "No valid value found for run_ram. Assuming same as current configuration."
    run_ram=$current_ram
  fi

  if [ -z "${build_cpu}" ] || [ "$build_cpu" -le 0 ]; then
    #echo "No valid value found for build_cpu. Assuming same as current configuration."
    build_cpu=$current_cpu
  fi

  if [ -z "${build_ram}" ] || [ "$build_ram" -le 0 ]; then
    #echo "No valid value found for build_ram. Assuming same as current configuration."
    build_ram=$current_ram
  fi

  UPDATE_BUILD_RESOURCES=0
  if [ "$build_cpu" -gt "$run_cpu" ] || [ "$build_ram" -gt "$run_ram" ]; then
    UPDATE_BUILD_RESOURCES=1
  fi

  #3) if build resources are different than run resources, then:
  if [ "$UPDATE_BUILD_RESOURCES" -eq "1" ]; then
    pct set "$container" --cores "$build_cpu" --memory "$build_ram"
  fi

  #4) Update service, using the update command
  # Prepend a no-op 'clear' wrapper to PATH so update scripts calling clear
  # don't fail without a TTY — works for all shells incl. ash (no export -f)
  SETUP_CMD="mkdir -p /tmp/.nc; printf '#!/bin/sh\n:\n' > /tmp/.nc/clear; chmod +x /tmp/.nc/clear; export PATH=/tmp/.nc:\$PATH; export TERM=dumb; "
  case "$os" in
  alpine) pct exec "$container" -- ash -c "${SETUP_CMD}${UPDATE_CMD}" ;;
  archlinux) pct exec "$container" -- bash -c "${SETUP_CMD}${UPDATE_CMD}" ;;
  fedora | rocky | centos | alma) pct exec "$container" -- bash -c "${SETUP_CMD}${UPDATE_CMD}" ;;
  ubuntu | debian | devuan) pct exec "$container" -- bash -c "${SETUP_CMD}${UPDATE_CMD}" ;;
  opensuse) pct exec "$container" -- bash -c "${SETUP_CMD}${UPDATE_CMD}" ;;
  esac
  exit_code=$?

  #5) if build resources are different than run resources, then:
  if [ "$UPDATE_BUILD_RESOURCES" -eq "1" ]; then
    pct set "$container" --cores "$run_cpu" --memory "$run_ram"
  fi

  if pct exec "$container" -- [ -e "/var/run/reboot-required" ]; then
    # Get the container's hostname and add it to the list
    container_hostname=$(pct exec "$container" hostname)
    containers_needing_reboot+=("$container ($container_hostname)")
  fi

  if [ "$template" == "false" ] && [ "$status" == "status: stopped" ]; then
    echo -e "${BL}[Info]${GN} Shutting down${BL} $container ${CL} \n"
    pct shutdown $container &>/dev/null &
  fi

  if [ $exit_code -eq 0 ]; then
    msg_ok "Updated container $container"
    log_result "$container" "$service" "OK" "Updated successfully"
    log_write "Container $container ($service): OK"
  elif [ $exit_code -eq 75 ]; then
    echo -e "${YW}[WARN]${CL} Container $container skipped (requires interactive mode)"
    log_result "$container" "$service" "SKIPPED" "Requires interactive mode (exit 75)"
    log_write "Container $container ($service): SKIPPED — requires interactive mode"
  elif [ $exit_code -eq 113 ]; then
    echo -e "${YW}[WARN]${CL} Container $container skipped (under-provisioned: increase CPU/RAM to match template)"
    log_result "$container" "$service" "SKIPPED" "Under-provisioned — increase CPU/RAM to match template"
    log_write "Container $container ($service): SKIPPED — under-provisioned"
  elif [ $exit_code -eq 114 ]; then
    echo -e "${YW}[WARN]${CL} Container $container skipped (storage critically low on /boot)"
    log_result "$container" "$service" "SKIPPED" "Storage critically low on /boot (>80%)"
    log_write "Container $container ($service): SKIPPED — storage critically low on /boot"
  else
    msg_error "Update failed for container $container (exit code: $exit_code) — QUARANTINED; no automatic restore will be attempted"
    log_result "$container" "$service" "FAILED/QUARANTINED" "Exit code $exit_code; inspect before manual recovery"
    log_write "Container $container ($service): QUARANTINED (exit $exit_code); no automatic restore"
    if [[ "$var_continue_on_error" == "yes" ]]; then
      echo -e "${YW}[WARN]${CL} Continuing to next container (var_continue_on_error=yes); failed guest remains quarantined"
      continue
    else
      exit "$exit_code"
    fi
  fi
done

wait
header_info
echo -e "${GN}The process is complete, and the containers have been successfully updated.${CL}\n"
print_summary
if [ "${#containers_needing_reboot[@]}" -gt 0 ]; then
  echo -e "${RD}The following containers require a reboot:${CL}"
  for container_name in "${containers_needing_reboot[@]}"; do
    echo "$container_name"
  done

  # Determine reboot choice based on var_auto_reboot
  REBOOT_CHOICE="no"
  if [[ -n "$var_auto_reboot" ]]; then
    REBOOT_CHOICE="$var_auto_reboot"
  else
    echo -ne "${INFO} Do you wish to reboot these containers? <yes/No>  "
    read -r prompt
    if [[ ${prompt,,} =~ ^(yes)$ ]]; then
      REBOOT_CHOICE="yes"
    fi
  fi

  if [[ "$REBOOT_CHOICE" == "yes" ]]; then
    echo -e "${CROSS}${HOLD} ${YWB}Rebooting containers.${CL}"
    for container_name in "${containers_needing_reboot[@]}"; do
      container=$(echo $container_name | cut -d " " -f 1)
      pct reboot ${container}
    done
  fi
fi
