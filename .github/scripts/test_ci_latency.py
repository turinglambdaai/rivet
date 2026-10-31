#!/usr/bin/env python3
"""Offline tests for the GitHub Actions latency reporter."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

script = Path(__file__).with_name("ci-latency.py")
spec = spec_from_file_location("ci_latency", script)
module = module_from_spec(spec)
spec.loader.exec_module(module)


class LatencyTests(unittest.TestCase):
    def test_queue_and_wall_from_job_timestamps(self):
        run = {
            "name": "CI", "status": "completed", "conclusion": "success",
            "created_at": "2026-10-30T00:00:00Z",
        }
        jobs = [{
            "name": "test (macos-latest)", "labels": ["macos-latest"],
            "started_at": "2026-10-30T02:00:00Z",
            "completed_at": "2026-10-30T02:05:00Z",
        }]
        report = module.summarize([(run, jobs)])["CI"]
        self.assertEqual(report["queue_p50_seconds"], 7200)
        self.assertEqual(report["wall_p95_seconds"], 7500)
        self.assertEqual(report["runner_p50_seconds"], 300)
        self.assertEqual(report["macos_start_delay_p95_seconds"], 7200)

    def test_cancelled_not_counted_as_fast_run(self):
        run = {
            "name": "CI", "status": "completed", "conclusion": "cancelled",
            "created_at": "2026-10-30T00:00:00Z",
        }
        report = module.summarize([(run, [])])["CI"]
        self.assertEqual(report["cancelled"], 1)
        self.assertEqual(report["completed_samples"], 0)
        self.assertIsNone(report["wall_p50_seconds"])

    def test_percentile_uses_nearest_rank(self):
        self.assertEqual(module.percentile([1, 2, 3, 4, 5], 95), 5)
        self.assertEqual(module.percentile([], 50), None)

    def test_pending_runs_are_separate(self):
        report = module.summarize([({
            "name": "CI", "status": "queued", "conclusion": None,
            "created_at": "2026-10-30T00:00:00Z",
        }, [])])["CI"]
        self.assertEqual(report["pending"], 1)
        self.assertEqual(report["completed_samples"], 0)


if __name__ == "__main__":
    unittest.main()
