from __future__ import annotations

import pytest

from slurmbar_agent.errors import InvalidArgument
from slurmbar_agent.validate import (
    base_job_id,
    is_valid_job_id,
    validate_job_id,
    validate_job_ids,
    validate_job_step_id,
    validate_stream,
    validate_user,
)


@pytest.mark.parametrize("value", ["1", "201551", "201560_7", " 201551 "])
def test_accepts_real_job_ids(value):
    assert validate_job_id(value) == value.strip()


@pytest.mark.parametrize(
    "value",
    [
        "",
        "   ",
        "abc",
        "201551; rm -rf /",
        "201551 && scancel 999",
        "$(whoami)",
        "`id`",
        "201551|cat",
        "../../etc/passwd",
        "201551\n201552",
        "201551 201552",
        "-1",
        "201551_",
        "_7",
        "201551_[1-5]",
        "201551.batch",
        "9" * 40,
    ],
)
def test_rejects_anything_that_is_not_a_plain_job_id(value):
    # Nothing here would be interpreted as a shell metacharacter (the agent never uses a
    # shell), but rejecting them keeps malformed ids away from scancel entirely.
    with pytest.raises(InvalidArgument):
        validate_job_id(value)
    assert not is_valid_job_id(value)


def test_non_string_input_is_rejected():
    with pytest.raises(InvalidArgument):
        validate_job_id(201551)  # type: ignore[arg-type]


def test_step_ids_are_accepted_only_where_meaningful():
    assert validate_job_step_id("201551.batch") == "201551.batch"
    assert validate_job_step_id("201551.0") == "201551.0"
    assert validate_job_step_id("201560_7.extern") == "201560_7.extern"
    with pytest.raises(InvalidArgument):
        validate_job_step_id("201551.evil;")


def test_batch_validation_and_limit():
    assert validate_job_ids(["1", "2"]) == ["1", "2"]
    with pytest.raises(InvalidArgument):
        validate_job_ids([str(i) for i in range(600)])


@pytest.mark.parametrize("value", ["exampleuser", "user.name", "u_1", "a@b.org", None, ""])
def test_valid_users(value):
    validate_user(value)


@pytest.mark.parametrize("value", ["user;rm", "user name", "-flag", "a" * 100, "user$"])
def test_invalid_users(value):
    with pytest.raises(InvalidArgument):
        validate_user(value)


def test_stream_choice():
    assert validate_stream("stdout") == "stdout"
    assert validate_stream("stderr") == "stderr"
    with pytest.raises(InvalidArgument):
        validate_stream("/etc/passwd")


def test_base_job_id():
    assert base_job_id("201551") == "201551"
    assert base_job_id("201560_7") == "201560"
