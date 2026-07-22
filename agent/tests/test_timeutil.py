from __future__ import annotations

from datetime import datetime, timezone

import pytest

from slurmbar_agent.timeutil import (
    MemoryValue,
    clamp_percent,
    elapsed_between,
    iso_utc,
    parse_duration_seconds,
    parse_exit_code,
    parse_memory,
    parse_minutes_to_seconds,
    parse_slurm_time,
    parse_slurm_time_iso,
)


class TestParseSlurmTime:
    def test_iso_text_is_read_as_login_node_local_time(self):
        # conftest pins TZ=UTC, so local == UTC here.
        assert parse_slurm_time_iso("2026-07-22T00:10:00") == "2026-07-22T00:10:00Z"

    def test_unix_epoch_integer(self):
        assert parse_slurm_time_iso(1784679000) == "2026-07-22T00:10:00Z"

    def test_slurm_2311_wrapper(self):
        assert parse_slurm_time_iso({"set": True, "infinite": False, "number": 1784679000}) == (
            "2026-07-22T00:10:00Z"
        )

    def test_unset_wrapper_is_none(self):
        assert parse_slurm_time({"set": False, "infinite": False, "number": 0}) is None

    def test_infinite_wrapper_is_none(self):
        assert parse_slurm_time({"set": True, "infinite": True, "number": 0}) is None

    @pytest.mark.parametrize("value", ["", "N/A", "Unknown", "None", "(null)", None, 0, -1])
    def test_sentinels_are_none(self, value):
        assert parse_slurm_time(value) is None

    def test_garbage_is_none_not_an_exception(self):
        assert parse_slurm_time("not a date") is None

    def test_iso_utc_normalizes_to_z_suffix(self):
        moment = datetime(2026, 7, 22, 2, 30, 0, 123456, tzinfo=timezone.utc)
        assert iso_utc(moment) == "2026-07-22T02:30:00Z"


class TestParseDuration:
    @pytest.mark.parametrize(
        "text,expected",
        [
            ("1-00:00:00", 86400),
            ("2-03:04:05", 183845),
            ("10:00:00", 36000),
            ("2:20:00", 8400),
            ("05:30", 330),
            ("0:00", 0),
            ("5-12", 475200),
            ("3600", 3600),
        ],
    )
    def test_known_forms(self, text, expected):
        assert parse_duration_seconds(text) == expected

    @pytest.mark.parametrize("text", ["UNLIMITED", "INVALID", "N/A", "", None])
    def test_unlimited_and_unknown_are_none_not_zero(self, text):
        assert parse_duration_seconds(text) is None

    def test_minutes_conversion(self):
        assert parse_minutes_to_seconds(1440) == 86400
        assert parse_minutes_to_seconds({"set": True, "infinite": False, "number": 240}) == 14400
        assert parse_minutes_to_seconds({"set": False, "infinite": True, "number": 0}) is None


class TestParseMemory:
    @pytest.mark.parametrize(
        "text,expected_bytes,expected_per",
        [
            ("256G", 256 * 1024**3, None),
            ("4Gc", 4 * 1024**3, "c"),
            ("64Gn", 64 * 1024**3, "n"),
            ("118111600K", 118111600 * 1024, None),
            ("1.5G", int(1.5 * 1024**3), None),
            ("16GB", 16 * 1024**3, None),
            ("0", 0, None),
        ],
    )
    def test_forms(self, text, expected_bytes, expected_per):
        assert parse_memory(text) == MemoryValue(expected_bytes, expected_per)

    def test_default_unit_applies_to_bare_numbers(self):
        assert parse_memory("512", default_unit="M").bytes == 512 * 1024**2
        assert parse_memory("512", default_unit="K").bytes == 512 * 1024

    @pytest.mark.parametrize("text", ["", "N/A", None, "abc", "Unknown"])
    def test_unavailable_stays_none(self, text):
        assert parse_memory(text).bytes is None


class TestExitCode:
    @pytest.mark.parametrize(
        "value,expected",
        [
            ("0:0", (0, 0)),
            ("1:0", (1, 0)),
            ("0:125", (0, 125)),
            ("", (None, None)),
            ("N/A", (None, None)),
        ],
    )
    def test_text_forms(self, value, expected):
        assert parse_exit_code(value) == expected

    def test_slurm_2311_object(self):
        payload = {
            "status": ["SUCCESS"],
            "return_code": {"set": True, "infinite": False, "number": 0},
        }
        assert parse_exit_code(payload) == (0, None)


def test_elapsed_between_uses_now_when_end_is_open():
    start = datetime(2026, 7, 22, 0, 0, 0, tzinfo=timezone.utc)
    end = datetime(2026, 7, 22, 2, 20, 0, tzinfo=timezone.utc)
    assert elapsed_between(start, end) == 8400
    assert elapsed_between(None, end) is None


def test_clamp_percent_rejects_nonsense():
    assert clamp_percent(37.5) == 37.5
    assert clamp_percent(-5) == 0.0
    assert clamp_percent(150) == 100.0
    assert clamp_percent(float("nan")) is None
    assert clamp_percent(None) is None
