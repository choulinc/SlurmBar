from __future__ import annotations

import pytest

from slurmbar_agent.states import is_terminal, normalize_state


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("RUNNING", "RUNNING"),
        ("PENDING", "PENDING"),
        ("COMPLETING", "COMPLETING"),
        ("COMPLETED", "COMPLETED"),
        ("FAILED", "FAILED"),
        ("TIMEOUT", "TIMEOUT"),
        ("OUT_OF_MEMORY", "OUT_OF_MEMORY"),
        ("NODE_FAIL", "NODE_FAIL"),
        ("PREEMPTED", "PREEMPTED"),
        ("BOOT_FAIL", "BOOT_FAIL"),
        ("DEADLINE", "DEADLINE"),
        ("SUSPENDED", "SUSPENDED"),
        ("CONFIGURING", "PENDING"),
        ("RESIZING", "RUNNING"),
    ],
)
def test_long_state_names(raw, expected):
    assert normalize_state(raw) == (expected, raw)


@pytest.mark.parametrize(
    "code,expected",
    [("R", "RUNNING"), ("PD", "PENDING"), ("CG", "COMPLETING"), ("CD", "COMPLETED"),
     ("F", "FAILED"), ("CA", "CANCELLED"), ("TO", "TIMEOUT"), ("OOM", "OUT_OF_MEMORY"),
     ("NF", "NODE_FAIL"), ("PR", "PREEMPTED")],
)
def test_short_state_codes(code, expected):
    assert normalize_state(code)[0] == expected


def test_cancelled_by_user_keeps_raw_text():
    state, raw = normalize_state("CANCELLED by 100234")
    assert state == "CANCELLED"
    assert raw == "CANCELLED by 100234"


def test_truncated_state_from_squeue_column_width():
    assert normalize_state("OUT_OF_ME+")[0] == "OUT_OF_MEMORY"


def test_json_state_list_from_slurm_2311():
    assert normalize_state(["RUNNING"]) == ("RUNNING", "RUNNING")


def test_json_state_list_prefers_the_terminal_failure_flag():
    state, raw = normalize_state(["CANCELLED", "OUT_OF_MEMORY"])
    assert state == "OUT_OF_MEMORY"
    assert raw == "CANCELLED+OUT_OF_MEMORY"


def test_unknown_state_is_not_guessed_and_keeps_raw():
    state, raw = normalize_state("SOME_FUTURE_STATE")
    assert state == "UNKNOWN"
    assert raw == "SOME_FUTURE_STATE"


def test_none_and_empty():
    assert normalize_state(None) == ("UNKNOWN", None)
    assert normalize_state("   ") == ("UNKNOWN", None)
    assert normalize_state([]) == ("UNKNOWN", None)


def test_is_terminal():
    assert not is_terminal("RUNNING")
    assert not is_terminal("PENDING")
    assert not is_terminal("COMPLETING")
    assert is_terminal("COMPLETED")
    assert is_terminal("OUT_OF_MEMORY")
