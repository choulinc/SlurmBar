"""The version appears in five files across three languages; this fails when they drift.

`scripts/set-version.sh` writes all of them from `VERSION`. This test is what makes forgetting
to run it a build failure rather than a wrong number in a bug report six months later.
"""

from __future__ import annotations

import plistlib
import re

import pytest

from conftest import REPO_ROOT

VERSION_FILE = REPO_ROOT / "VERSION"


@pytest.fixture(scope="module")
def version() -> str:
    assert VERSION_FILE.exists(), "VERSION is the single source of truth and must exist"
    value = VERSION_FILE.read_text().strip()
    assert re.fullmatch(r"\d+\.\d+\.\d+", value), f"VERSION must be semver, got {value!r}"
    return value


def _grep(path, pattern: str) -> str:
    match = re.search(pattern, (REPO_ROOT / path).read_text(), re.MULTILINE)
    assert match, f"{path} does not contain {pattern!r}"
    return match.group(1)


def test_agent_module_version(version):
    assert _grep("agent/slurmbar_agent/protocol.py", r'^AGENT_VERSION = "([^"]+)"') == version


def test_agent_package_version(version):
    assert _grep("agent/pyproject.toml", r'^version = "([^"]+)"') == version


def test_progress_module_version(version):
    assert _grep("progress/slurmbar_progress/__init__.py", r'^__version__ = "([^"]+)"') == version


def test_progress_writer_tag(version):
    # This string is written into every status.json, so a stale value misreports which SDK
    # produced a file when diagnosing a problem on a cluster.
    assert _grep(
        "progress/slurmbar_progress/reporter.py", r'^WRITER = "slurmbar_progress/([^"]+)"'
    ) == version


def test_progress_package_version(version):
    assert _grep("progress/pyproject.toml", r'^version = "([^"]+)"') == version


def test_app_bundle_version(version):
    plist = plistlib.loads((REPO_ROOT / "app/Resources/Info.plist").read_bytes())
    assert plist["CFBundleShortVersionString"] == version


def test_agent_reports_the_version_at_runtime(version):
    from slurmbar_agent.protocol import AGENT_VERSION

    assert AGENT_VERSION == version


def test_progress_reports_the_version_at_runtime(version):
    import slurmbar_progress

    assert slurmbar_progress.__version__ == version


def test_changelog_documents_the_current_version(version):
    changelog = (REPO_ROOT / "CHANGELOG.md").read_text()
    assert f"## {version}" in changelog, f"CHANGELOG.md has no section for {version}"
