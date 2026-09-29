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

eval "$(extract_function auto_x_show_install_info)"
eval "$(extract_function docker_app_install)"

auto_x_install_dir="/home/docker/auto-x"
docker_port=8080
AUTO_X_INITIAL_ADMIN_PASSWORD=""
hostname() { printf '%s\n' "127.0.0.1"; }
auto_x_service_selected() { [[ ",${AUTO_X_SERVICES}," == *",$1,"* ]]; }

AUTO_X_SERVICES="xhs-worker,monitor-center,monitor-agent"
worker_output="$(auto_x_show_install_info)"
[[ "$worker_output" == *"此节点未部署 frontend"* ]]
[[ "$worker_output" != *"管理面板:"* ]]

AUTO_X_SERVICES="backend,frontend,auth-center,monitor-agent"
frontend_output="$(auto_x_show_install_info)"
[[ "$frontend_output" == *"管理面板:"* ]]
[[ "$frontend_output" == *"管理员账号: admin"* ]]

for function_name in auto_x_sync_source auto_x_select_services auto_x_prepare_env \
    auto_x_prepare_control_plane_bootstrap auto_x_sync_nacos_config \
    auto_x_report_data_topology auto_x_prepare_compose_override \
    auto_x_compose auto_x_pull_selected_images; do
    eval "$function_name() { return 0; }"
done
auto_x_selected_args() { AUTO_X_SERVICE_ARGS=(monitor-agent); }
auto_x_build_from_source() { return 0; }
auto_x_build_from_source_enabled() { return 1; }
check_docker_app_ip() { printf '%s\n' "checked-panel"; }

AUTO_X_SERVICES="xhs-worker,monitor-center,monitor-agent"
worker_install_output="$(docker_app_install)"
[[ "$worker_install_output" != *"checked-panel"* ]]

AUTO_X_SERVICES="backend,frontend,auth-center,monitor-agent"
frontend_install_output="$(docker_app_install)"
[[ "$frontend_install_output" == *"checked-panel"* ]]

echo "auto_x_install_info=pass"
