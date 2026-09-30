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
echo 'auto_x_camoufox=pass'
