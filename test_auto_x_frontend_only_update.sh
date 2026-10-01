#!/bin/bash
set -euo pipefail

app_conf="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/auto-x.conf"
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$app_conf"
}
eval "$(extract_function auto_x_update_frontend_only)"
eval "$(extract_function docker_app_update)"
eval "$(extract_function auto_x_migrate_default_images)"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
auto_x_install_dir="$test_dir"
auto_x_services_file="$test_dir/.auto-x-services"
auto_x_image_registry=ghcr.io
printf '%s\n' 'backend,worker,ai-worker,qq-worker,auth-center,monitor-agent,frontend' > "$auto_x_services_file"
printf '%s\n' 'IMAGE_TAG=sha-old' 'FRONTEND_IMAGE=registry.example/frontend' > "$test_dir/.env"

auto_x_get_env() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2"
}
auto_x_set_env() {
    local key="$1" value="$2" file="$3"
    awk -F= -v key="$key" -v value="$value" '
        BEGIN { seen=0 }
        $1 == key {print key "=" value; seen=1; next}
        {print}
        END {if (!seen) print key "=" value}
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}
auto_x_sync_source() { printf '%s\n' sync >> "$test_dir/calls"; }
auto_x_build_from_source_enabled() { return 1; }
auto_x_skip_pull_enabled() { return 1; }
auto_x_compose_pull() { printf 'pull %s\n' "$*" >> "$test_dir/calls"; }
auto_x_compose() {
    printf 'compose %s tag=%s services=%s\n' "$*" "${FRONTEND_IMAGE_TAG:-}" "${AUTO_X_SERVICES:-}" >> "$test_dir/calls"
}

KJ_AUTO_X_UPDATE_FRONTEND_ONLY=1
KJ_AUTO_X_IMAGE_TAG=sha-new
unset AUTO_X_SERVICES
docker_app_update > "$test_dir/output"
grep -q '^sync$' "$test_dir/calls"
grep -q '^pull frontend$' "$test_dir/calls"
grep -q '^compose up -d --no-build --no-deps --wait frontend tag=sha-new services=frontend$' "$test_dir/calls"
test "$(auto_x_get_env IMAGE_TAG "$test_dir/.env")" = sha-old
test "$(auto_x_get_env FRONTEND_IMAGE_TAG "$test_dir/.env")" = sha-new
test "$(cat "$auto_x_services_file")" = 'backend,worker,ai-worker,qq-worker,auth-center,monitor-agent,frontend'

: > "$test_dir/calls"
KJ_AUTO_X_IMAGE_TAG=sha-next
auto_x_compose_pull() {
    auto_x_set_env FRONTEND_IMAGE registry.example/fallback "$test_dir/.env"
    return 1
}
if docker_app_update > "$test_dir/output" 2>&1; then
    echo 'failed pull must stop the frontend-only update' >&2
    exit 1
fi
test "$(auto_x_get_env FRONTEND_IMAGE_TAG "$test_dir/.env")" = sha-new
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = registry.example/frontend
if grep -q '^compose up ' "$test_dir/calls"; then
    echo 'failed pull must not recreate frontend' >&2
    exit 1
fi

KJ_AUTO_X_IMAGE_REGISTRY=ghcr.io
KJ_AUTO_X_IMAGE_TAG=sha-registry
printf '%s\n' 'IMAGE_TAG=sha-old' \
    'BACKEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-backend' \
    'FRONTEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend' > "$test_dir/.env"
auto_x_skip_pull_enabled() { return 0; }
docker() { test "$*" = 'image inspect ghcr.io/stanxu-symple/auto-x-frontend:sha-registry'; }
docker_app_update > "$test_dir/output"
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = ghcr.io/stanxu-symple/auto-x-frontend
test "$(auto_x_get_env BACKEND_IMAGE "$test_dir/.env")" = ghcr.dockerproxy.net/stanxu-symple/auto-x-backend
test "$(auto_x_get_env IMAGE_TAG "$test_dir/.env")" = sha-old

# A missing local image must restore the previous registry as well as the tag.
auto_x_set_env FRONTEND_IMAGE ghcr.nju.edu.cn/stanxu-symple/auto-x-frontend "$test_dir/.env"
docker() { return 1; }
if docker_app_update > "$test_dir/output" 2>&1; then
    echo 'missing cached frontend must fail' >&2
    exit 1
fi
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = ghcr.nju.edu.cn/stanxu-symple/auto-x-frontend
test "$(auto_x_get_env FRONTEND_IMAGE_TAG "$test_dir/.env")" = sha-registry

auto_x_compose() { return 1; }
if docker_app_update > "$test_dir/output" 2>&1; then
    echo 'invalid Compose must fail' >&2
    exit 1
fi
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = ghcr.nju.edu.cn/stanxu-symple/auto-x-frontend
echo 'auto_x_frontend_only_update=pass'
