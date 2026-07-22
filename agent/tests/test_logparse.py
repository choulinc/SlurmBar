from __future__ import annotations

from pathlib import Path

import pytest

from conftest import FIXTURES
from slurmbar_agent import logtail
from slurmbar_agent.logparse import parse_log_lines


def tail_of(name: str, **kwargs):
    return logtail.read_tail(str(FIXTURES / "logs" / name), **kwargs)


# ---------------------------------------------------------------------------------------------
# Bounded tail reading
# ---------------------------------------------------------------------------------------------


class TestReadTail:
    def test_small_file_reads_fully(self):
        result = tail_of("training-epochs.log")
        assert result.ok
        assert not result.truncated
        assert result.lines[0].startswith("Loading dataset")

    def test_line_limit_is_applied(self):
        result = tail_of("training-epochs.log", max_lines=3)
        assert len(result.lines) == 3
        assert result.truncated

    def test_large_file_reads_only_the_window(self, tmp_path: Path):
        big = tmp_path / "big.log"
        with big.open("w") as handle:
            for i in range(200_000):
                handle.write(f"line {i} " + "x" * 60 + "\n")
            handle.write("Epoch 88/100 loss=0.4211\n")
        size = big.stat().st_size
        assert size > 10 * 1024 * 1024

        result = logtail.read_tail(str(big), max_lines=50, window_bytes=32 * 1024)
        assert result.ok
        assert result.bytes_read is not None and result.bytes_read <= 32 * 1024
        assert result.file_size_bytes == size
        assert result.truncated
        assert result.lines[-1] == "Epoch 88/100 loss=0.4211"

    def test_partial_first_line_is_discarded(self, tmp_path: Path):
        path = tmp_path / "cut.log"
        path.write_text("AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n")
        result = logtail.read_tail(str(path), window_bytes=1024)
        assert result.lines == ["AAAAAAAAAA", "BBBBBBBBBB", "CCCCCCCCCC"]
        cut = logtail.read_tail(str(path), window_bytes=1500)
        assert cut.ok

    def test_missing_file_is_reported_not_raised(self, tmp_path: Path):
        result = logtail.read_tail(str(tmp_path / "nope.log"))
        assert not result.ok
        assert result.error_kind == "missing"

    def test_none_path(self):
        result = logtail.read_tail(None)
        assert not result.ok
        assert result.error_kind == "missing"

    def test_directory_is_rejected(self, tmp_path: Path):
        result = logtail.read_tail(str(tmp_path))
        assert not result.ok

    def test_permission_denied_is_categorized(self, tmp_path: Path):
        import os

        path = tmp_path / "secret.log"
        path.write_text("hidden\n")
        os.chmod(path, 0o000)
        try:
            result = logtail.read_tail(str(path))
            if result.ok:  # running as root
                pytest.skip("cannot test permission denial as this user")
            assert result.error_kind == "permission"
        finally:
            os.chmod(path, 0o600)

    def test_control_characters_and_ansi_are_stripped(self, tmp_path: Path):
        path = tmp_path / "ansi.log"
        path.write_text("\x1b[31mred\x1b[0m text\x00with\x07control\n")
        result = logtail.read_tail(str(path))
        assert result.lines == ["red text withcontrol"] or result.lines == ["red textwithcontrol"]
        assert "\x1b" not in result.lines[0]
        assert "\x00" not in result.lines[0]

    def test_very_long_line_is_bounded(self, tmp_path: Path):
        path = tmp_path / "long.log"
        path.write_text("y" * 50_000 + "\n")
        result = logtail.read_tail(str(path))
        assert len(result.lines[0]) < logtail.MAX_LINE_CHARS + 100


class TestSplitLines:
    def test_carriage_returns_become_separate_lines(self):
        assert logtail.split_lines("a\rb\rc") == ["a", "b", "c"]

    def test_crlf_is_one_break(self):
        assert logtail.split_lines("a\r\nb") == ["a", "b"]


# ---------------------------------------------------------------------------------------------
# Progress inference
# ---------------------------------------------------------------------------------------------


class TestParseLogLines:
    def test_labelled_epochs(self):
        parsed = parse_log_lines(tail_of("training-epochs.log").lines)
        assert parsed is not None
        assert (parsed.current, parsed.total) == (375.0, 1000.0)
        assert parsed.unit == "epoch"
        assert parsed.percent == 37.5
        assert parsed.confidence == "medium"

    def test_metrics_are_collected_from_the_newest_lines(self):
        parsed = parse_log_lines(tail_of("training-epochs.log").lines)
        assert parsed.metrics["loss"] == 0.059045
        assert parsed.metrics["learning_rate"] == 3.4e-05
        assert parsed.metrics["batch_current"] == 36.0
        assert parsed.metrics["batch_total"] == 94.0

    def test_tqdm_carriage_return_output(self):
        lines = tail_of("tqdm-progress.log").lines
        assert len(lines) > 2  # \r split the single physical line into states
        parsed = parse_log_lines(lines)
        assert parsed is not None
        assert parsed.current == 380.0 and parsed.total == 1000.0

    def test_bare_ratio_is_accepted_only_at_low_confidence(self):
        parsed = parse_log_lines(tail_of("bare-ratio.log").lines)
        assert parsed is not None
        assert parsed.confidence == "low"
        assert (parsed.current, parsed.total) == (250.0, 800.0)

    def test_no_progress_returns_none_rather_than_guessing(self):
        assert parse_log_lines(tail_of("no-progress.log").lines) is None

    def test_empty_input(self):
        assert parse_log_lines([]) is None
        assert parse_log_lines(["", "   "]) is None

    def test_timestep_workloads(self):
        parsed = parse_log_lines(tail_of("simulation-nan.log").lines)
        assert parsed is not None
        assert parsed.unit == "timestep"
        assert (parsed.current, parsed.total) == (4300.0, 10000.0)

    def test_nan_loss_survives_as_a_string(self):
        parsed = parse_log_lines(tail_of("simulation-nan.log").lines)
        assert parsed.metrics["loss"] == "nan"

    def test_labelled_pattern_outranks_a_later_bare_ratio(self):
        lines = ["Epoch 5/50 starting", "reading chunk 900/1000"]
        parsed = parse_log_lines(lines)
        assert parsed.unit == "epoch"
        assert (parsed.current, parsed.total) == (5.0, 50.0)

    @pytest.mark.parametrize(
        "line,expected",
        [
            ("Epoch 375/1000", (375.0, 1000.0)),
            ("Epoch: 375 / 1000", (375.0, 1000.0)),
            ("epoch [375/1000]", (375.0, 1000.0)),
            ("Epoch 375 of 1000", (375.0, 1000.0)),
            ("EPOCH=375/1000", (375.0, 1000.0)),
        ],
    )
    def test_epoch_spelling_variants(self, line, expected):
        parsed = parse_log_lines([line])
        assert (parsed.current, parsed.total) == expected

    def test_impossible_ratio_is_rejected(self):
        assert parse_log_lines(["progress 5000/10"]) is None

    def test_zero_total_is_rejected(self):
        assert parse_log_lines(["step 0/0"]) is None

    def test_tqdm_percent_without_a_ratio(self):
        parsed = parse_log_lines(["  47%|#####     | elapsed 00:12"])
        assert parsed is not None
        assert parsed.percent == 47.0
        assert parsed.current is None and parsed.total is None
        assert parsed.confidence == "medium"

    def test_progress_json_is_always_labelled_as_parsed(self):
        parsed = parse_log_lines(["Epoch 3/10"])
        payload = parsed.to_progress_json("2026-07-22T02:30:00Z")
        assert payload["source"] == "log_parser"
        assert payload["confidence"] == "medium"
        # A parser must never invent an ETA from log text alone.
        assert payload["eta_seconds"] is None
