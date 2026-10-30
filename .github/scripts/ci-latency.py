#!/usr/bin/env python3
"""Summarize GitHub Actions queue delay vs execution time across repositories.

No third-party dependencies. GH_TOKEN or GITHUB_TOKEN enables private-repo access.
This script only reads the GitHub API and never changes a run or repository.
"""
import argparse
from datetime import datetime
import json
import math
import os
import statistics
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def seconds_between(first, last):
    if not first or not last:
        return None
    a = datetime.fromisoformat(first.replace("Z", "+00:00"))
    b = datetime.fromisoformat(last.replace("Z", "+00:00"))
    return max(0.0, (b - a).total_seconds())


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(len(ordered) * percent / 100) - 1)], 1)


def summarize(samples):
    """Each sample contains a workflow run and its complete GitHub jobs list."""
    grouped = {}
    for run, jobs in samples:
        key = run.get("name") or "(unnamed workflow)"
        group = grouped.setdefault(key, {
            "runs": 0, "cancelled": 0, "pending": 0,
            "queue": [], "elapsed": [], "runner_seconds": [], "macos_delay": [],
        })
        group["runs"] += 1
        if run.get("conclusion") == "cancelled":
            group["cancelled"] += 1
            continue
        if run.get("status") != "completed":
            group["pending"] += 1
            continue
        created = run.get("created_at")
        started = [j.get("started_at") for j in jobs if j.get("started_at")]
        finished = [j.get("completed_at") for j in jobs if j.get("completed_at")]
        if not started or not finished:
            continue
        first_start, last_end = min(started), max(finished)
        queue = seconds_between(created, first_start)
        elapsed = seconds_between(created, last_end)
        if queue is not None:
            group["queue"].append(queue)
        if elapsed is not None:
            group["elapsed"].append(elapsed)
        run_seconds = [
            seconds_between(j.get("started_at"), j.get("completed_at"))
            for j in jobs if j.get("started_at") and j.get("completed_at")
        ]
        group["runner_seconds"].append(sum(s for s in run_seconds if s is not None))
        macos = [
            j["started_at"] for j in jobs
            if j.get("started_at") and
            "macos" in (" ".join(
                [j.get("name") or "", j.get("runner_name") or ""]
                + (j.get("labels") or [])
            )).lower()
        ]
        if macos:
            group["macos_delay"].append(seconds_between(created, min(macos)))
    result = {}
    for workflow, g in sorted(grouped.items()):
        result[workflow] = {
            "runs": g["runs"], "completed_samples": len(g["elapsed"]),
            "cancelled": g["cancelled"], "pending": g["pending"],
            "queue_p50_seconds": percentile(g["queue"], 50),
            "queue_p95_seconds": percentile(g["queue"], 95),
            "wall_p50_seconds": percentile(g["elapsed"], 50),
            "wall_p95_seconds": percentile(g["elapsed"], 95),
            "runner_p50_seconds": percentile(g["runner_seconds"], 50),
            "macos_start_delay_p95_seconds": percentile(g["macos_delay"], 95),
        }
    return result


class GitHub:
    def __init__(self, token=None):
        self.token = token

    def get(self, path):
        request = Request(
            "https://api.github.com" + path,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "rivet-ci-latency/1",
                "X-GitHub-Api-Version": "2022-11-28",
                **({"Authorization": "Bearer " + self.token} if self.token else {}),
            },
        )
        try:
            with urlopen(request, timeout=25) as response:
                return json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"GitHub API HTTP {error.code} for {path}") from None
        except URLError as error:
            raise RuntimeError(f"GitHub API unavailable for {path}: {error.reason}") from None

    def jobs(self, repo, run_id):
        jobs = []
        page = 1
        while True:
            data = self.get(
                f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100&page={page}"
            )
            chunk = data.get("jobs", [])
            jobs.extend(chunk)
            if len(chunk) < 100:
                return jobs
            page += 1

    def samples(self, repo, limit, workflow=None):
        data = self.get(f"/repos/{repo}/actions/runs?per_page={limit}")
        for run in data.get("workflow_runs", []):
            if workflow and run.get("name") != workflow:
                continue
            if run.get("status") != "completed" or run.get("conclusion") == "cancelled":
                yield run, []
            else:
                yield run, self.jobs(repo, run["id"])


def duration(value):
    if value is None:
        return "—"
    return f"{value / 60:.1f}m"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", required=True,
                        help="owner/repo; repeat to analyze multiple repositories")
    parser.add_argument("--runs", type=int, default=20,
                        help="latest runs to request per repository (1..100)")
    parser.add_argument("--workflow", help="exact workflow name, e.g. CI")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of Markdown")
    args = parser.parse_args(argv)
    if not 1 <= args.runs <= 100:
        parser.error("--runs must be between 1 and 100")
    api = GitHub(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    report = {}
    for repo in args.repo:
        if repo.count("/") != 1 or not all(repo.split("/")):
            parser.error(f"invalid owner/repo: {repo}")
        report[repo] = summarize(api.samples(quote(repo, safe="/"), args.runs, args.workflow))
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    print("| Repository | Workflow | Samples | Cancelled | Pending | Queue P50 / P95 | Wall P50 / P95 | macOS start P95 |")
    print("|---|---|---:|---:|---:|---|---|---|")
    for repo, workflows in report.items():
        for name, s in workflows.items():
            print(f"| {repo} | {name} | {s['completed_samples']} | {s['cancelled']} | {s['pending']} | "
                  f"{duration(s['queue_p50_seconds'])} / {duration(s['queue_p95_seconds'])} | "
                  f"{duration(s['wall_p50_seconds'])} / {duration(s['wall_p95_seconds'])} | "
                  f"{duration(s['macos_start_delay_p95_seconds'])} |")
    print("\nQueue = first job start minus workflow creation; wall = last job finish "
          "minus creation. macOS start includes dependency wait. "
          "Cancelled runs are excluded from latency percentiles.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
