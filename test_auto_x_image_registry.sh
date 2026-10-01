#!/usr/bin/env bash
set -euo pipefail

app_conf="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/auto-x.conf"
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$app_conf"
}
eval "$(extract_function auto_x_get_env)"
eval "$(extract_function auto_x_migrate_default_images)"

# The real setter uses GNU sed; use a portable writer on macOS as well.
auto_x_set_env() {
    local key="$1" value="$2" file="$3"
    awk -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        index($0, key "=") == 1 { print key "=" value; found=1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
env_file="$test_dir/.env"
keys=(BACKEND_IMAGE XHS_WORKER_IMAGE CAMOUFOX_WORKER_IMAGE FRONTEND_IMAGE)
images=(auto-x-backend auto-x-xhs-worker auto-x-camoufox-worker auto-x-frontend)

# Cover all historical defaults, official/CN/custom target registries and tags.
for target in ghcr.io ghcr.nju.edu.cn registry.example:5000/proxy; do
    KJ_AUTO_X_IMAGE_REGISTRY="$target"
    auto_x_image_registry="$target"
    for old in ghcr.io ghcr.dockerproxy.net ghcr.nju.edu.cn; do
        : > "$env_file"
        for index in 0 1 2 3; do
            printf '%s="%s/stanxu-symple/%s"\n' \
                "${keys[$index]}" "$old" "${images[$index]}" >> "$env_file"
        done
        printf '%s\n' 'IMAGE_TAG=sha-pinned' 'FRONTEND_IMAGE_TAG=sha-frontend' >> "$env_file"
        auto_x_migrate_default_images "$env_file"
        for index in 0 1 2 3; do
            test "$(auto_x_get_env "${keys[$index]}" "$env_file")" \
                = "$target/stanxu-symple/${images[$index]}"
        done
        test "$(auto_x_get_env IMAGE_TAG "$env_file")" = sha-pinned
        test "$(auto_x_get_env FRONTEND_IMAGE_TAG "$env_file")" = sha-frontend
        cp "$env_file" "$test_dir/once"
        auto_x_migrate_default_images "$env_file"
        cmp "$env_file" "$test_dir/once"
    done
done

cat > "$env_file" <<'EOF'
BACKEND_IMAGE=registry.example/custom/backend
XHS_WORKER_IMAGE=ghcr.io/other-owner/auto-x-xhs-worker
CAMOUFOX_WORKER_IMAGE=ghcr.nju.edu.cn/stanxu-symple/custom-browser
FRONTEND_IMAGE=ghcr.dockerproxy.net/custom/frontend
EOF
cp "$env_file" "$test_dir/custom"
KJ_AUTO_X_IMAGE_REGISTRY=ghcr.io
auto_x_image_registry=ghcr.io
auto_x_migrate_default_images "$env_file"
cmp "$env_file" "$test_dir/custom"

# Without an explicit choice, default mode must keep the saved source.
unset KJ_AUTO_X_IMAGE_REGISTRY
auto_x_image_registry=ghcr.dockerproxy.net
printf '%s\n' 'BACKEND_IMAGE=ghcr.nju.edu.cn/stanxu-symple/auto-x-backend' > "$env_file"
cp "$env_file" "$test_dir/implicit"
auto_x_migrate_default_images "$env_file"
cmp "$env_file" "$test_dir/implicit"

# Interactive CN and frontend-only updates retain their narrower contracts.
auto_x_image_registry=ghcr.nju.edu.cn
printf '%s\n' 'BACKEND_IMAGE=ghcr.dockerproxy.net/stanxu-symple/auto-x-backend' > "$env_file"
auto_x_migrate_default_images "$env_file"
test "$(auto_x_get_env BACKEND_IMAGE "$env_file")" = ghcr.nju.edu.cn/stanxu-symple/auto-x-backend
KJ_AUTO_X_IMAGE_REGISTRY=ghcr.io
auto_x_image_registry=ghcr.io
auto_x_migrate_default_images "$env_file" FRONTEND_IMAGE
test "$(auto_x_get_env FRONTEND_IMAGE "$env_file")" = ghcr.io/stanxu-symple/auto-x-frontend
test "$(auto_x_get_env BACKEND_IMAGE "$env_file")" = ghcr.nju.edu.cn/stanxu-symple/auto-x-backend

echo 'auto_x_image_registry=pass'
