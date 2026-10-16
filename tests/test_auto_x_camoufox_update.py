"""Exercise isolated browser updates with fake Docker and lifecycle calls."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CONF = Path(os.environ.get(
    "AUTO_X_INSTALLER_CONF", ROOT / "auto-x.conf"
))
SAVED_SERVICES = "xhs-worker,camoufox-worker,monitor-center,monitor-agent"
ENV = """IMAGE_TAG=sha-other-services
CAMOUFOX_WORKER_IMAGE=ghcr.nju.edu.cn/stanxu-symple/auto-x-camoufox-worker
CAMOUFOX_WORKER_IMAGE_TAG=sha-browser-old
BACKEND_IMAGE=registry.example/backend
XHS_WORKER_IMAGE=registry.example/xhs
FRONTEND_IMAGE=registry.example/frontend
FRONTEND_IMAGE_TAG=sha-frontend-old
NACOS_SERVER_ADDR=http://nacos.example:8848
"""


def function(name: str) -> str:
    if not CONF.is_file():
        pytest.skip("Set AUTO_X_INSTALLER_CONF to the apps/auto-x.conf checkout")
    match = re.search(
        rf"^{name}\(\) \{{\n.*?^\}}", CONF.read_text(), re.MULTILINE | re.DOTALL
    )
    assert match, name
    return match.group()


HARNESS = r"""
set -u
auto_x_install_dir="$TEST_DIR"
auto_x_services_file="$TEST_DIR/.auto-x-services"
auto_x_image_registry=ghcr.io
KJ_AUTO_X_IMAGE_REGISTRY=ghcr.io
KJ_AUTO_X_UPDATE_CAMOUFOX_ONLY="${CAM_ONLY:-1}"
KJ_AUTO_X_UPDATE_FRONTEND_ONLY="${FRONT_ONLY:-0}"
KJ_AUTO_X_IMAGE_TAG="${TARGET_TAG-sha-browser-new}"
auto_x_get_env() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2"
}
auto_x_set_env() {
    awk -F= -v key="$1" -v value="$2" '
        BEGIN {seen=0}
        $1 == key {print key "=" value; seen=1; next}
        {print}
        END {if (!seen) print key "=" value}
    ' "$3" > "$3.tmp"
    mv "$3.tmp" "$3"
}
record() { printf '%s\n' "$*" >> "$TEST_DIR/calls"; }
auto_x_sync_source() { record sync; return "${FAIL_SYNC:-0}"; }
auto_x_build_from_source_enabled() { return "${BUILD_STATUS:-1}"; }
auto_x_skip_pull_enabled() { return "${SKIP_STATUS:-1}"; }
auto_x_compose_pull() {
    record "pull $* tag=${CAMOUFOX_WORKER_IMAGE_TAG:-} services=${AUTO_X_SERVICES:-}"
    if [ "${PULL_FALLBACK:-0}" = 1 ]; then
        auto_x_set_env CAMOUFOX_WORKER_IMAGE ghcr.io/fallback/browser "$TEST_DIR/.env"
    fi
    return "${FAIL_PULL:-0}"
}
up_calls=0
auto_x_compose() {
    record "compose $* tag=${CAMOUFOX_WORKER_IMAGE_TAG:-} services=${AUTO_X_SERVICES:-} saved=$(auto_x_get_env CAMOUFOX_WORKER_IMAGE_TAG "$TEST_DIR/.env") image=$(auto_x_get_env CAMOUFOX_WORKER_IMAGE "$TEST_DIR/.env")"
    if [ "$1" = config ]; then return "${FAIL_CONFIG:-0}"; fi
    if [ "$1" = up ]; then
        up_calls=$((up_calls + 1))
        if [ "${FAIL_UP:-0}" = 1 ] && [ "$up_calls" = 1 ]; then return 1; fi
    fi
}
docker() { record "docker $*"; return "${FAIL_IMAGE:-0}"; }
auto_x_update_frontend_only() { record frontend-only; }
for forbidden in auto_x_select_services auto_x_prepare_env auto_x_prepare_control_plane_bootstrap \
    auto_x_sync_nacos_config auto_x_report_data_topology auto_x_prepare_compose_override \
    auto_x_selected_args auto_x_build_from_source auto_x_pull_selected_images; do
    eval "$forbidden() { record FORBIDDEN-$forbidden; return 79; }"
done
docker_app_update
"""


def run_update(tmp_path: Path, *, env: str = ENV, services: str | None = SAVED_SERVICES,
               **options: str) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
    (tmp_path / ".env").write_text(env)
    if services is not None:
        (tmp_path / ".auto-x-services").write_text(services + "\n")
    (tmp_path / "calls").write_text("")
    definitions = "\n".join(function(name) for name in (
        "auto_x_migrate_default_images", "auto_x_update_camoufox_only", "docker_app_update"
    ))
    process_env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("KJ_AUTO_X_", "AUTO_X_", "CAMOUFOX_WORKER_"))}
    result = subprocess.run(
        ["bash", "-c", definitions + "\n" + HARNESS], text=True, capture_output=True,
        env={**process_env, "TEST_DIR": str(tmp_path), **options}, check=False,
    )
    calls = (tmp_path / "calls").read_text().splitlines()
    assert not any("FORBIDDEN" in line for line in calls), calls
    if services is not None:
        assert (tmp_path / ".auto-x-services").read_text() == services + "\n"
    return result, calls, (tmp_path / ".env").read_text()


def dotenv(value: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in value.splitlines())


def test_camoufox_only_update_changes_only_its_image_and_tag(tmp_path):
    result, calls, value = run_update(tmp_path)
    assert result.returncode == 0, result.stderr
    assert calls[0] == "sync"
    assert calls[1].startswith("compose config --quiet tag=sha-browser-new services=camoufox-worker")
    assert calls[2] == "pull camoufox-worker tag=sha-browser-new services=camoufox-worker"
    assert calls[3].startswith(
        "compose up -d --no-build --no-deps --wait camoufox-worker tag=sha-browser-new "
        "services=camoufox-worker"
    )
    assert len(calls) == 4
    assert "saved=sha-browser-old" in calls[1]
    assert "saved=sha-browser-old" in calls[3]
    before, after = dotenv(ENV), dotenv(value)
    assert after.pop("CAMOUFOX_WORKER_IMAGE_TAG") == "sha-browser-new"
    assert after.pop("CAMOUFOX_WORKER_IMAGE") == (
        "ghcr.io/stanxu-symple/auto-x-camoufox-worker"
    )
    before.pop("CAMOUFOX_WORKER_IMAGE_TAG")
    before.pop("CAMOUFOX_WORKER_IMAGE")
    assert after == before


@pytest.mark.parametrize("options", [
    {"FAIL_CONFIG": "1"}, {"FAIL_PULL": "1", "PULL_FALLBACK": "1"},
    {"SKIP_STATUS": "0", "FAIL_IMAGE": "1"}, {"SKIP_STATUS": "2"},
])
def test_failed_preflight_preserves_old_config_and_running_service(tmp_path, options):
    result, calls, value = run_update(tmp_path, **options)
    assert result.returncode != 0
    assert value == ENV
    assert not any(line.startswith("compose up") for line in calls)


@pytest.mark.parametrize("independent_tag,rollback_tag", [
    (True, "sha-browser-old"), (False, "sha-other-services"),
])
def test_failed_start_restores_previous_image_and_effective_tag(
    tmp_path, independent_tag, rollback_tag
):
    env = ENV if independent_tag else ENV.replace("CAMOUFOX_WORKER_IMAGE_TAG=sha-browser-old\n", "")
    result, calls, value = run_update(tmp_path, env=env, FAIL_UP="1", PULL_FALLBACK="1")
    assert result.returncode != 0
    assert value == env
    starts = [line for line in calls if line.startswith("compose up")]
    assert len(starts) == 2
    assert f"tag={rollback_tag} services=camoufox-worker" in starts[-1]
    assert starts[-1].endswith("image=" + dotenv(env)["CAMOUFOX_WORKER_IMAGE"])
    assert all("--no-deps" in line and "--no-build" in line for line in starts)


def test_offline_update_checks_only_target_browser_image(tmp_path):
    result, calls, value = run_update(tmp_path, SKIP_STATUS="0", AUTO_X_SERVICES="camoufox-worker")
    assert result.returncode == 0, result.stderr
    assert "docker image inspect ghcr.io/stanxu-symple/auto-x-camoufox-worker:sha-browser-new" in calls
    assert not any(line.startswith("pull ") for line in calls)
    assert dotenv(value)["CAMOUFOX_WORKER_IMAGE_TAG"] == "sha-browser-new"


def test_custom_image_is_preserved(tmp_path):
    custom = ENV.replace(
        "ghcr.nju.edu.cn/stanxu-symple/auto-x-camoufox-worker", "custom.example/team/browser"
    )
    result, _, value = run_update(tmp_path, env=custom)
    assert result.returncode == 0, result.stderr
    assert dotenv(value)["CAMOUFOX_WORKER_IMAGE"] == "custom.example/team/browser"


def test_failed_source_sync_does_not_change_config_or_run_compose(tmp_path):
    result, calls, value = run_update(tmp_path, FAIL_SYNC="1")
    assert result.returncode != 0
    assert calls == ["sync"]
    assert value == ENV


@pytest.mark.parametrize("services,options", [
    (None, {}), ("xhs-worker,monitor-agent", {}),
    (SAVED_SERVICES, {"AUTO_X_SERVICES": "xhs-worker,camoufox-worker"}),
    (SAVED_SERVICES, {"TARGET_TAG": ""}), (SAVED_SERVICES, {"TARGET_TAG": "../bad"}),
    (SAVED_SERVICES, {"BUILD_STATUS": "0"}), (SAVED_SERVICES, {"BUILD_STATUS": "2"}),
    (SAVED_SERVICES, {"FRONT_ONLY": "1"}), (SAVED_SERVICES, {"CAM_ONLY": "wrong"}),
    (SAVED_SERVICES, {"FRONT_ONLY": "wrong"}),
])
def test_invalid_request_stops_before_source_or_runtime_changes(tmp_path, services, options):
    result, calls, value = run_update(tmp_path, services=services, **options)
    assert result.returncode != 0
    assert calls == []
    assert value == ENV


def test_frontend_only_dispatch_is_preserved(tmp_path):
    result, calls, value = run_update(tmp_path, CAM_ONLY="0", FRONT_ONLY="1")
    assert result.returncode == 0
    assert calls == ["frontend-only"]
    assert value == ENV


def test_zero_flags_keep_full_update_dispatch(tmp_path):
    (tmp_path / ".env").write_text(ENV)
    script = function("docker_app_update") + r'''
auto_x_install_dir="$TEST_DIR"
KJ_AUTO_X_UPDATE_CAMOUFOX_ONLY=0
KJ_AUTO_X_UPDATE_FRONTEND_ONLY=0
auto_x_sync_source() { printf 'sync\n'; }
auto_x_select_services() { printf 'full-select\n'; return 73; }
auto_x_update_camoufox_only() { printf 'unexpected-browser\n'; }
auto_x_update_frontend_only() { printf 'unexpected-frontend\n'; }
docker_app_update
'''
    result = subprocess.run(
        ["bash", "-c", script], text=True, capture_output=True,
        env={**os.environ, "TEST_DIR": str(tmp_path)}, check=False,
    )
    assert result.returncode == 1
    assert result.stdout.splitlines() == ["sync", "full-select"]
    assert (tmp_path / ".env").read_text() == ENV


def test_full_update_offline_verification_uses_browser_override(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(ENV)
    script = "\n".join(function(name) for name in (
        "auto_x_get_env", "auto_x_verify_local_images"
    )) + r'''
auto_x_install_dir="$TEST_DIR"
AUTO_X_SERVICES=camoufox-worker
auto_x_uses_external_data() { return 0; }
docker() { printf '%s\n' "$*" >> "$TEST_DIR/calls"; }
auto_x_verify_local_images
'''
    result = subprocess.run(
        ["bash", "-c", script], text=True, capture_output=True,
        env={**os.environ, "TEST_DIR": str(tmp_path)}, check=False,
    )
    assert result.returncode == 0, result.stderr
    calls = (tmp_path / "calls").read_text().splitlines()
    assert "image inspect ghcr.nju.edu.cn/stanxu-symple/auto-x-camoufox-worker:sha-browser-old" in calls
    assert not any("auto-x-camoufox-worker:sha-other-services" in line for line in calls)


@pytest.mark.parametrize("has_override", [True, False])
def test_full_explicit_release_advances_existing_browser_override(tmp_path, has_override):
    env = ENV if has_override else ENV.replace("CAMOUFOX_WORKER_IMAGE_TAG=sha-browser-old\n", "")
    env += "SERVICE_AUTH_KEY_ENCRYPTION_KEY=separate-key-at-least-32-characters-long\n"
    (tmp_path / ".env").write_text(env)
    functions = "\n".join(function(name) for name in (
        "auto_x_get_env", "auto_x_set_env_if_default", "auto_x_set_env_if_missing",
        "auto_x_prepare_env",
    ))
    # Env preparation is run, with external setup disabled. The portable dotenv
    # setter keeps this behavioral check usable with macOS's non-GNU sed.
    setup = HARNESS.split('record()')[0]
    script = functions + "\n" + setup + r'''
auto_x_backend_image=registry.example/backend
auto_x_xhs_worker_image=registry.example/xhs
auto_x_camoufox_worker_image=registry.example/browser
auto_x_frontend_image=registry.example/frontend
auto_x_nacos_config_data_id=x-sentinel-config.json
KJ_AUTO_X_NACOS_ADVERTISE_IP=192.0.2.1
auto_x_migrate_default_images() { return 0; }
auto_x_validate_manage_data() { return 0; }
auto_x_configure_nacos() { return 0; }
auto_x_service_selected() { return 1; }
auto_x_prepare_env
'''
    result = subprocess.run(
        ["bash", "-c", script], text=True, capture_output=True,
        env={**os.environ, "TEST_DIR": str(tmp_path)}, check=False,
    )
    assert result.returncode == 0, result.stderr
    values = dotenv((tmp_path / ".env").read_text())
    assert values["IMAGE_TAG"] == "sha-browser-new"
    if has_override:
        assert values["CAMOUFOX_WORKER_IMAGE_TAG"] == "sha-browser-new"
    else:
        assert "CAMOUFOX_WORKER_IMAGE_TAG" not in values
