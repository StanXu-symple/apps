#!/bin/bash
set -euo pipefail

app_conf="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/auto-x.conf"

extract_function() {
    local name="$1"
    awk -v signature="${name}() {" '
        $0 == signature { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$app_conf"
}

eval "$(extract_function auto_x_compose_pull_with_retries)"
eval "$(extract_function auto_x_replace_default_proxy_image)"
eval "$(extract_function auto_x_fallback_to_official_images)"
eval "$(extract_function auto_x_compose_pull)"

auto_x_get_env() {
    local key="$1" env_file="$2" line
    line="$(grep -m1 -E "^${key}=" "$env_file" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

auto_x_set_env() {
    local key="$1" value="$2" env_file="$3" temporary="${env_file}.tmp"
    awk -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        index($0, key "=") == 1 { print key "=" value; found=1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$env_file" > "$temporary"
    mv "$temporary" "$env_file"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
auto_x_install_dir="$test_dir"
auto_x_default_image_registry="ghcr.dockerproxy.net"
auto_x_image_registry="$auto_x_default_image_registry"
auto_x_pull_retries=2

cat > "$test_dir/.env" <<'EOF'
BACKEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-backend
XHS_WORKER_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-xhs-worker
FRONTEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend
EOF

pull_attempts=0
auto_x_compose() {
    pull_attempts=$((pull_attempts + 1))
    [ "$pull_attempts" -eq 3 ]
}

auto_x_compose_pull backend frontend xhs-worker >/dev/null
test "$pull_attempts" -eq 3
test "$(auto_x_get_env BACKEND_IMAGE "$test_dir/.env")" = "ghcr.io/stanxu-symple/auto-x-backend"
test "$(auto_x_get_env XHS_WORKER_IMAGE "$test_dir/.env")" = "ghcr.io/stanxu-symple/auto-x-xhs-worker"
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = "ghcr.io/stanxu-symple/auto-x-frontend"

cat > "$test_dir/.env" <<'EOF'
BACKEND_IMAGE=registry.example/custom/backend
XHS_WORKER_IMAGE=registry.example/custom/xhs-worker
FRONTEND_IMAGE=registry.example/custom/frontend
EOF

pull_attempts=0
auto_x_compose() {
    pull_attempts=$((pull_attempts + 1))
    return 1
}

if auto_x_compose_pull backend frontend xhs-worker >/dev/null; then
    echo "custom images must not trigger the official GHCR fallback" >&2
    exit 1
fi
test "$pull_attempts" -eq "$auto_x_pull_retries"
test "$(auto_x_get_env BACKEND_IMAGE "$test_dir/.env")" = "registry.example/custom/backend"
test "$(auto_x_get_env XHS_WORKER_IMAGE "$test_dir/.env")" = "registry.example/custom/xhs-worker"
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = "registry.example/custom/frontend"

cat > "$test_dir/.env" <<'EOF'
BACKEND_IMAGE=registry.example/custom/backend
XHS_WORKER_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-xhs-worker
FRONTEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend
EOF

pull_attempts=0
if auto_x_compose_pull monitor-agent >/dev/null; then
    echo "unselected default images must not trigger the official GHCR fallback" >&2
    exit 1
fi
test "$pull_attempts" -eq "$auto_x_pull_retries"
test "$(auto_x_get_env BACKEND_IMAGE "$test_dir/.env")" = "registry.example/custom/backend"
test "$(auto_x_get_env XHS_WORKER_IMAGE "$test_dir/.env")" = "ghcr.dockerproxy.net/stanxu-symple/auto-x-xhs-worker"
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = "ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend"

cat > "$test_dir/.env" <<'EOF'
BACKEND_IMAGE=registry.example/custom/backend
XHS_WORKER_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-xhs-worker
FRONTEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend
EOF

pull_attempts=0
auto_x_compose() {
    pull_attempts=$((pull_attempts + 1))
    [ "$pull_attempts" -eq 3 ]
}

auto_x_compose_pull backend frontend xhs-worker >/dev/null
test "$(auto_x_get_env BACKEND_IMAGE "$test_dir/.env")" = "registry.example/custom/backend"
test "$(auto_x_get_env XHS_WORKER_IMAGE "$test_dir/.env")" = "ghcr.io/stanxu-symple/auto-x-xhs-worker"
test "$(auto_x_get_env FRONTEND_IMAGE "$test_dir/.env")" = "ghcr.io/stanxu-symple/auto-x-frontend"

echo "auto_x_image_fallback=pass"
