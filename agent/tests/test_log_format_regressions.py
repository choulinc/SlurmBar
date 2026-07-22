"""Log-parser regression tests against a synthetic interleaved training log.

The observed format interleaves two shapes:

    ... - Epoch 35 [20/50] Loss: 0.50 Duration: 2.0s Mem: 8GB
    ... - Epoch 35/100 avg_loss: 0.40 lr: 1e-04 duration: 100s

The per-epoch line carries the authoritative epoch counter; the per-batch line carries
sub-epoch position in brackets with no "batch" keyword anywhere.
"""

from __future__ import annotations

from conftest import FIXTURES
from slurmbar_agent import logtail
from slurmbar_agent.logparse import parse_log_lines

LOG = "epoch-bracket-batch.log"


def tail():
    return logtail.read_tail(str(FIXTURES / "logs" / LOG)).lines


class TestEpochBracketBatchFormat:
    def test_epoch_counter_comes_from_the_summary_line(self):
        parsed = parse_log_lines(tail())
        assert parsed is not None
        # The last summary line is "Epoch 35/100"; the newer per-batch lines must not win.
        assert (parsed.current, parsed.total) == (35.0, 100.0)
        assert parsed.unit == "epoch"

    def test_percentage_derived_from_epochs(self):
        parsed = parse_log_lines(tail())
        assert parsed.percent == 35.0

    def test_confidence_is_never_high_for_parsed_logs(self):
        parsed = parse_log_lines(tail())
        assert parsed.confidence == "medium"
        assert parsed.to_progress_json(None)["source"] == "log_parser"

    def test_bracketed_batch_position_is_extracted(self):
        # "Epoch 35 [20/50]" carries batch progress but never uses the word "batch", so a
        # keyword-only pattern missed it entirely.
        parsed = parse_log_lines(tail())
        assert parsed.metrics.get("batch_current") == 1.0
        assert parsed.metrics.get("batch_total") == 50.0

    def test_avg_loss_is_captured(self):
        # "avg_loss:" has no word boundary before "loss", so \bloss\b never matched it.
        parsed = parse_log_lines(tail())
        assert parsed.metrics.get("avg_loss") == 0.4

    def test_per_batch_loss_is_also_captured(self):
        parsed = parse_log_lines(tail())
        assert parsed.metrics.get("loss") == 0.6

    def test_learning_rate_in_scientific_notation(self):
        parsed = parse_log_lines(tail())
        assert parsed.metrics.get("learning_rate") == 1e-04

    def test_duration_is_not_mistaken_for_progress(self):
        # Duration fields must not become counters.
        parsed = parse_log_lines(tail())
        assert parsed.total == 100.0


class TestNoOverfitting:
    """The added patterns must stay generic, not keyed to one experiment."""

    def test_bracket_batch_works_without_the_word_epoch(self):
        parsed = parse_log_lines(["Step 12 [45/100] loss: 0.5"])
        assert parsed is not None
        assert parsed.metrics.get("batch_current") == 45.0

    def test_avg_loss_variants(self):
        for line, expected in [
            ("avg_loss: 0.25", 0.25),
            ("avg_loss=0.25", 0.25),
            ("mean_loss: 0.25", 0.25),
        ]:
            parsed = parse_log_lines(["Epoch 1/10", line])
            assert parsed.metrics.get("avg_loss") == expected, line

    def test_a_plain_epoch_log_still_works(self):
        parsed = parse_log_lines(["Epoch 5/50 loss=0.1"])
        assert (parsed.current, parsed.total) == (5.0, 50.0)
        assert parsed.metrics.get("loss") == 0.1

    def test_unrelated_bracket_numbers_do_not_become_batches(self):
        # A timestamp like [2026-07-22 14:25:08,134] must not be read as a counter.
        parsed = parse_log_lines(["[2026-07-22 14:25:08,134][main][INFO] - starting"])
        assert parsed is None

    def test_log_with_only_batches_falls_back_honestly(self):
        parsed = parse_log_lines(["Epoch 7 [30/94] Loss: 0.4"])
        assert parsed is not None
        # No epoch total is known, so the epoch counter must not be invented.
        assert parsed.total is None or parsed.unit != "epoch"
