#!/usr/bin/env bash
# n8n-upgrade.sh — Upgrade n8n (Docker Compose) with minimal downtime
# Usage: ./n8n-upgrade.sh [VERSION]
# Example: ./n8n-upgrade.sh 1.109.0   (defaults to "latest" if omitted)

set -euo pipefail

### Config / Defaults
DESIRED_TAG="${1:-latest}"                      # e.g., "1.109.0" or "latest"
COMPOSE_FILE=""                                 # will be detected
COMPOSE_CMD=""                                  # "docker compose" or "docker-compose"
SERVICE_NAME=""                                 # will be detected
IMAGE_REGEX='(n8nio/n8n|ghcr\.io/n8n-io/n8n)'   # supported image registries
BACKUP_SUFFIX=".bak-$(date +%Y%m%d%H%M%S)"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || err "Command not found: $1"; }

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available."
  fi
}

detect_compose_file() {
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$f" ]]; then COMPOSE_FILE="$f"; break; fi
  done
  [[ -n "$COMPOSE_FILE" ]] || err "No docker-compose.yml (or compose.yml) found in current directory."
  log "Using compose file: $COMPOSE_FILE"
}

detect_service() {
  # Try to find the service that uses an n8n image
  # naive YAML scan (works for simple files)
  local svc=""
  # 1) explicit "image: <repo>/<name>:tag"
  svc=$(awk '
    $1=="services:"{in_services=1; next}
    in_services && /^[[:space:]]+[A-Za-z0-9._-]+:$/{
      svc=$1; gsub(":","",svc); current=svc
    }
    in_services && $1=="image:"{
      img=$2
      if (img ~ /(n8nio\/n8n|ghcr\.io\/n8n-io\/n8n)/) { print current; exit }
    }
  ' "$COMPOSE_FILE" || true)

  if [[ -z "$svc" ]]; then
    # 2) fallback: look for a service actually named "n8n"
    if grep -Eq '^[[:space:]]+n8n:' "$COMPOSE_FILE"; then
      svc="n8n"
    fi
  fi

  [[ -n "$svc" ]] || err "Could not detect the n8n service in $COMPOSE_FILE."
  SERVICE_NAME="$svc"
  log "Detected n8n service: $SERVICE_NAME"
}

current_container_id() {
  # Returns container ID if running, else empty
  $COMPOSE_CMD ps -q "$SERVICE_NAME"
}

n8n_version_in_container() {
  local cid="$1"
  if [[ -z "$cid" ]]; then
    echo "not running"
    return 0
  fi
  # Try to run the CLI inside the container to get version
  if docker exec -i "$cid" n8n --version >/dev/null 2>&1; then
    docker exec -i "$cid" n8n --version 2>/dev/null | tr -d '\r'
  else
    # Fallback to Node package.json lookup (best effort)
    docker exec -i "$cid" node -e "try{console.log(require('/usr/local/lib/node_modules/n8n/package.json').version)}catch(e){process.exit(1)}" 2>/dev/null \
      || echo "unknown"
  fi
}

extract_image_line() {
  # Return the image line for the n8n service (e.g., "image: n8nio/n8n:latest")
  awk -v svc="$SERVICE_NAME" '
    $1=="services:"{in_services=1; next}
    in_services && ("^\\s*"svc":" ~ $0){in_service=1; next}
    in_services && in_service && /^[[:space:]]+[A-Za-z0-9._-]+:$/ { in_service=0 } # next service
    in_service && $1=="image:" { print $0; exit }
  ' "$COMPOSE_FILE"
}

update_image_tag_in_compose() {
  local desired="$1"
  local img_line
  img_line=$(extract_image_line || true)

  if [[ -z "$img_line" ]]; then
    warn "No explicit image line found for service '$SERVICE_NAME'."
    warn "This script expects an 'image: $IMAGE_REGEX:<tag>' entry. Skipping tag update."
    return 0
  fi

  # Extract current repo
  local current_repo
  current_repo=$(sed -E "s/.*image:[[:space:]]+($IMAGE_REGEX):.*/\1/" <<<"$img_line")

  if [[ -z "$current_repo" ]]; then
    warn "Could not parse current image repo from: $img_line"
    return 0
  fi

  # Backup compose file then replace the tag
  cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}${BACKUP_SUFFIX}"
  sed -E -i "s|(image:[[:space:]]+$IMAGE_REGEX:)[^[:space:]]+|\1$desired|g" "$COMPOSE_FILE"
  log "Updated image tag to: ${current_repo}:$desired (backup: ${COMPOSE_FILE}${BACKUP_SUFFIX})"
}

pull_image() {
  local desired="$1"
  # Prefer pulling explicitly to prefetch, minimizing downtime
  local repo="n8nio/n8n"
  if grep -Eq 'image:[[:space:]]+ghcr\.io/n8n-io/n8n' "$COMPOSE_FILE"; then
    repo="ghcr.io/n8n-io/n8n"
  fi
  log "Pulling image: $repo:$desired"
  docker pull "$repo:$desired" >/dev/null
  log "Image pulled."
}

upgrade_service() {
  # Recreate only the n8n service, no deps, wait for healthy
  log "Recreating service '$SERVICE_NAME' with minimal downtime…"
  $COMPOSE_CMD up -d --no-deps "$SERVICE_NAME"
  # If compose supports --wait, use it (docker-compose doesn’t)
  if $COMPOSE_CMD up -d --help 2>/dev/null | grep -q -- '--wait'; then
    $COMPOSE_CMD up -d --no-deps --wait "$SERVICE_NAME"
  fi
  log "Service recreation requested."
}

show_result_step() {
  printf '\n=== %s ===\n' "$1"
}

main() {
  need_cmd docker
  detect_compose_cmd
  detect_compose_file
  detect_service

  show_result_step "Pre-flight"
  log "Desired n8n version tag: $DESIRED_TAG"
  log "Compose command: $COMPOSE_CMD"
  log "Compose file: $COMPOSE_FILE"

  local before_cid before_ver
  before_cid="$(current_container_id || true)"
  before_ver="$(n8n_version_in_container "$before_cid")"

  show_result_step "Current Version"
  log "Container: ${before_cid:-not running}"
  log "n8n version (before): $before_ver"

  show_result_step "Prepare Image"
  update_image_tag_in_compose "$DESIRED_TAG"
  pull_image "$DESIRED_TAG"

  show_result_step "Apply Upgrade"
  upgrade_service

  # Give it a short grace period for restart if --wait wasn’t supported
  sleep 3

  local after_cid after_ver
  after_cid="$(current_container_id || true)"
  after_ver="$(n8n_version_in_container "$after_cid")"

  show_result_step "Post-Upgrade"
  log "Container: ${after_cid:-not running}"
  log "n8n version (after):  $after_ver"

  show_result_step "Done"
  if [[ "$before_ver" == "$after_ver" ]]; then
    warn "Version appears unchanged. Verify your compose image tag and logs: $COMPOSE_CMD logs -n 100 $SERVICE_NAME"
  else
    log "Upgrade complete."
  fi
}

main "$@"
