#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf="$root_dir/auto-x.conf"
bash -n "$conf"
functions="$(awk '
/^auto_x_normalize_services\(\)/ || /^auto_x_add_required_service\(\)/ || /^auto_x_add_service_dependencies\(\)/ { capture=1 }
capture { print }
capture && /^}$/ { capture=0 }
' "$conf")"
eval "$functions"
test "$(auto_x_normalize_services camoufox-worker)" = camoufox-worker
AUTO_X_SERVICES=xhs-worker
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = xhs-worker,camoufox-worker,monitor-agent
AUTO_X_SERVICES=xhs-worker
KJ_AUTO_X_CAMOUFOX_REMOTE=1
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = xhs-worker,monitor-agent
unset KJ_AUTO_X_CAMOUFOX_REMOTE
AUTO_X_SERVICES=worker
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = worker,camoufox-worker,monitor-agent
AUTO_X_SERVICES=worker
KJ_AUTO_X_CAMOUFOX_REMOTE=1
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = worker,monitor-agent
unset KJ_AUTO_X_CAMOUFOX_REMOTE
AUTO_X_SERVICES=worker
KJ_AUTO_X_TWEET_SCREENSHOT_ENABLED=false
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = worker,monitor-agent
unset KJ_AUTO_X_TWEET_SCREENSHOT_ENABLED
AUTO_X_SERVICES=camoufox-worker
auto_x_add_service_dependencies
test "$AUTO_X_SERVICES" = camoufox-worker,monitor-agent
case ",$(auto_x_normalize_services all)," in
    *,camoufox-worker,*) ;;
    *) exit 1 ;;
esac
for expected in CAMOUFOX_WORKER_IMAGE docker-compose.camoufox-worker.yml 'target: camoufox-worker' 'camoufox-worker) build_services+='; do
    grep -F "$expected" "$conf" >/dev/null
done

# A previous non-interactive update may have seeded the browser image with
# the default mirror. Explicit CN registry selection must repair that value.
image_functions="$(awk '
/^auto_x_set_env_if_default\(\)/ || /^auto_x_migrate_default_images\(\)/ { capture=1 }
capture { print }
capture && /^}$/ { capture=0 }
' "$conf")"
eval "$image_functions"
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
image_env="$(mktemp)"
trap 'rm -f "$image_env"' EXIT
cat > "$image_env" <<'EOF'
BACKEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-backend
XHS_WORKER_IMAGE=registry.example/custom-xhs
CAMOUFOX_WORKER_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-camoufox-worker
FRONTEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-frontend
EOF
auto_x_image_registry=ghcr.nju.edu.cn
auto_x_backend_image=ghcr.nju.edu.cn/stanxu-symple/auto-x-backend
auto_x_xhs_worker_image=ghcr.nju.edu.cn/stanxu-symple/auto-x-xhs-worker
auto_x_camoufox_worker_image=ghcr.nju.edu.cn/stanxu-symple/auto-x-camoufox-worker
auto_x_frontend_image=ghcr.nju.edu.cn/stanxu-symple/auto-x-frontend
auto_x_migrate_default_images "$image_env"
test "$(auto_x_get_env CAMOUFOX_WORKER_IMAGE "$image_env")" = "$auto_x_camoufox_worker_image"
test "$(auto_x_get_env XHS_WORKER_IMAGE "$image_env")" = registry.example/custom-xhs
test "$(auto_x_get_env BACKEND_IMAGE "$image_env")" = "$auto_x_backend_image"
test "$(auto_x_get_env FRONTEND_IMAGE "$image_env")" = "$auto_x_frontend_image"
echo 'auto_x_camoufox=pass'
