"""Check the installer's actual service selection and AI publisher fragment."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CONF = Path(os.environ.get("AUTO_X_INSTALLER_CONF", ROOT / "auto-x.conf"))
AUTO_X = Path(os.environ.get("AUTO_X_SOURCE_DIR", ROOT.parent.parent / "auto-X"))


def function(name: str) -> str:
    match = re.search(
        rf"^{name}\(\) \{{\n.*?^\}}", CONF.read_text(), re.MULTILINE | re.DOTALL
    )
    assert match, name
    return match.group()


@pytest.mark.parametrize("selected,fragments", [
    ("ai-worker", ["docker-compose.ai-worker.yml"]),
    ("ai-worker,monitor-agent", ["docker-compose.ai-worker.yml", "docker-compose.monitor-agent.yml"]),
    ("backend,ai-worker,frontend", ["docker-compose.backend.yml", "docker-compose.ai-worker.yml"]),
    ("frontend", ["docker-compose.backend.yml"]),
    ("camoufox-worker", ["docker-compose.camoufox-worker.yml"]),
    ("worker,qq-worker", []),
])
def test_selected_services_use_only_their_component_fragments(tmp_path, selected, fragments):
    saved = "backend,frontend,worker,ai-worker,qq-worker,auth-center,monitor-agent\n"
    services_file = tmp_path / ".auto-x-services"
    services_file.write_text(saved)
    script = "\n".join(function(name) for name in (
        "auto_x_load_selected_services", "auto_x_compose"
    )) + r'''
set -eu
auto_x_install_dir="$SOURCE_DIR"
auto_x_services_file="$SERVICES_FILE"
auto_x_compose_override=docker-compose.kejilion.yml
auto_x_data_routing_override=does-not-exist.yml
auto_x_uses_external_data() { return 0; }
docker() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
auto_x_compose config --format json
'''
    result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                            env={**os.environ, "SOURCE_DIR": str(AUTO_X),
                                 "SERVICES_FILE": str(services_file), "AUTO_X_SERVICES": selected},
                            check=False)
    assert result.returncode == 0, result.stderr
    args = json.loads(result.stdout)
    actual = [Path(args[index + 1]).name for index, arg in enumerate(args) if arg == "-f"]
    assert actual == ["docker-compose.yml", "docker-compose.kejilion.yml", *fragments,
                      "docker-compose.external.yml"]
    assert args[-3:] == ["config", "--format", "json"]
    assert services_file.read_text() == saved

    if "ai-worker" in selected.split(","):
        component_path = AUTO_X / "docker-compose.ai-worker.yml"
        assert component_path.is_file(), "The published source must include the AI worker fragment"
        component = yaml.safe_load(component_path.read_text())
        assert set(component["services"]) == {"ai-worker"}
        extends = component["services"]["ai-worker"]["extends"]
        assert extends == {"file": "docker-compose.microservices.yml", "service": "ai-worker"}
        inherited = yaml.safe_load((AUTO_X / extends["file"]).read_text())["services"][extends["service"]]
        assert inherited["environment"]["XHS_TRANSPORT"] == "http"
        assert inherited["environment"]["SERVICE_CLIENT_SECRET_FILE"] == "/run/xsentinel/ai-worker.secret"
        assert inherited["environment"]["NACOS_CONFIG_REQUIRED"] == "true"
        assert "${CONTROL_PLANE_DIR:-./data/control-plane}/ai-worker.secret:/run/xsentinel/ai-worker.secret:ro" in inherited["volumes"]
        assert set(inherited["networks"]) <= component["networks"].keys()


@pytest.mark.parametrize("selected,groups", [
    ("ai-worker", "x-sentinel-control,x-sentinel_app,x-sentinel_data,x-sentinel_monitoring"),
    ("ai-worker", "operator-control,operator-app,operator-data,operator-monitoring"),
    ("worker,qq-worker", None),
])
def test_ai_worker_only_prepares_control_networks_without_changing_selection(tmp_path, selected, groups):
    (tmp_path / "data/control-plane").mkdir(parents=True)
    (tmp_path / "data/control-plane/services.json").write_text("{}")
    (tmp_path / "infra/scripts").mkdir(parents=True)
    (tmp_path / "infra/scripts/network-groups.sh").write_text(
        'printf "%s\\n" "$NETWORK_GROUPS" > "$TEST_DIR/networks"\n'
    )
    custom = groups is not None and groups.startswith("operator-")
    (tmp_path / ".env").write_text(
        "CONTROL_NETWORK_NAME=operator-control\nAPP_NETWORK_NAME=operator-app\n"
        "DATA_NETWORK_NAME=operator-data\nMONITORING_NETWORK_NAME=operator-monitoring\n"
        if custom else ""
    )
    script = function("auto_x_prepare_compose_override") + r'''
set -eu
auto_x_install_dir="$TEST_DIR"
auto_x_compose_override=docker-compose.kejilion.yml
auto_x_get_env() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2"; }
auto_x_build_from_source_enabled() { return 1; }
auto_x_prepare_data_routing_override() { return 0; }
chown() { :; }
auto_x_prepare_compose_override
printf '%s\n' "$AUTO_X_SERVICES"
'''
    result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                            env={**os.environ, "TEST_DIR": str(tmp_path), "AUTO_X_SERVICES": selected},
                            check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == selected
    if groups is None:
        assert not (tmp_path / "networks").exists()
    else:
        assert (tmp_path / "networks").read_text().strip() == groups
