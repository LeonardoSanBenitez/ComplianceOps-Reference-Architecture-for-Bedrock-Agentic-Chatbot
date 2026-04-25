"""
Unit tests for scripts/generate_report.py.

These tests run without AWS credentials. They exercise:
  - load_catalogs: YAML parsing and control extraction
  - load_attestations: attestation index building
  - assemble_report: summary counters and action items
  - main: end-to-end report generation against the actual catalogs/attestations

All tests operate on the real compliance/ and attestations/ directories so
that any schema drift between the code and the YAML files is caught in CI.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pytest

# Insert the repo root into sys.path so imports work regardless of how pytest
# is invoked (from the repo root or from within tests/).
REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT))

from scripts.generate_report import (
    assemble_report,
    load_attestations,
    load_catalogs,
    main,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CATALOG_DIR = REPO_ROOT / "compliance" / "catalogs"
ATTESTATION_DIR = REPO_ROOT / "attestations"
EVIDENCE_DIR = REPO_ROOT / "evidence" / "automated"


# ---------------------------------------------------------------------------
# load_catalogs
# ---------------------------------------------------------------------------


class TestLoadCatalogs:
    def test_returns_nonempty_dict(self) -> None:
        catalogs = load_catalogs(CATALOG_DIR)
        assert len(catalogs) > 0, "Expected at least one catalog"

    def test_each_catalog_has_controls(self) -> None:
        catalogs = load_catalogs(CATALOG_DIR)
        for title, controls in catalogs.items():
            assert len(controls) > 0, f"Catalog '{title}' has no controls"

    def test_controls_have_required_fields(self) -> None:
        catalogs = load_catalogs(CATALOG_DIR)
        for title, controls in catalogs.items():
            for ctrl in controls:
                assert "id" in ctrl, f"Control in '{title}' missing 'id'"
                assert "title" in ctrl, f"Control '{ctrl['id']}' in '{title}' missing 'title'"
                assert isinstance(ctrl["id"], str) and ctrl["id"], (
                    f"Control 'id' must be a non-empty string in '{title}'"
                )

    def test_control_ids_are_unique_within_catalog(self) -> None:
        catalogs = load_catalogs(CATALOG_DIR)
        for title, controls in catalogs.items():
            ids = [c["id"] for c in controls]
            assert len(ids) == len(set(ids)), (
                f"Catalog '{title}' has duplicate control IDs: {ids}"
            )

    def test_nonexistent_dir_returns_empty(self) -> None:
        result = load_catalogs(Path("/nonexistent/path/that/does/not/exist"))
        assert result == {}

    def test_empty_dir_returns_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            result = load_catalogs(Path(tmpdir))
            assert result == {}


# ---------------------------------------------------------------------------
# load_attestations
# ---------------------------------------------------------------------------


class TestLoadAttestations:
    def test_returns_nonempty_dict(self) -> None:
        attestations = load_attestations(ATTESTATION_DIR)
        assert len(attestations) > 0, "Expected at least one attestation"

    def test_keys_match_control_ids(self) -> None:
        """Attestation keys should match control-id values (not attestation id)."""
        attestations = load_attestations(ATTESTATION_DIR)
        catalogs = load_catalogs(CATALOG_DIR)
        known_control_ids = {
            ctrl["id"]
            for controls in catalogs.values()
            for ctrl in controls
        }
        for att_key in attestations:
            assert att_key in known_control_ids, (
                f"Attestation key '{att_key}' does not match any catalog control ID. "
                f"Known IDs: {sorted(known_control_ids)}"
            )

    def test_attestations_have_required_fields(self) -> None:
        required = ["id", "control-id", "status", "decision", "justification",
                    "reviewed-by", "reviewed-at"]
        attestations = load_attestations(ATTESTATION_DIR)
        for control_id, att in attestations.items():
            for field in required:
                assert field in att, (
                    f"Attestation for control '{control_id}' is missing field '{field}'"
                )

    def test_statuses_are_valid(self) -> None:
        valid_statuses = {
            "satisfied", "partial", "not-satisfied", "not-applicable", "exception"
        }
        attestations = load_attestations(ATTESTATION_DIR)
        for control_id, att in attestations.items():
            raw_status = att.get("status", "")
            normalised = str(raw_status).replace("_", "-")
            assert normalised in valid_statuses, (
                f"Attestation for '{control_id}' has invalid status: '{raw_status}'. "
                f"Valid values: {valid_statuses}"
            )

    def test_schema_yaml_is_skipped(self) -> None:
        """schema.yaml must not be loaded as an attestation file."""
        attestations = load_attestations(ATTESTATION_DIR)
        # schema.yaml has no 'attestations' key so it would either be skipped
        # or produce no entries. Verify no key looks like a schema keyword.
        for key in attestations:
            assert key != "schema", "schema.yaml was incorrectly parsed as attestation"

    def test_nonexistent_dir_returns_empty(self) -> None:
        result = load_attestations(Path("/nonexistent/path"))
        assert result == {}


# ---------------------------------------------------------------------------
# assemble_report
# ---------------------------------------------------------------------------


class TestAssembleReport:
    def _load(self) -> tuple[
        dict[str, list[dict[str, object]]],
        dict[str, dict[str, object]],
        list[dict[str, object]],
    ]:
        catalogs = load_catalogs(CATALOG_DIR)
        attestations = load_attestations(ATTESTATION_DIR)
        # Evidence directory may not exist in CI without AWS; tolerate absence.
        evidence = []
        if EVIDENCE_DIR.exists():
            from scripts.generate_report import load_evidence
            evidence = load_evidence(EVIDENCE_DIR)
        return catalogs, attestations, evidence  # type: ignore[return-value]

    def test_returns_required_keys(self) -> None:
        catalogs, attestations, evidence = self._load()
        report = assemble_report(catalogs, attestations, evidence)
        required_keys = {
            "generated_at", "regulations", "catalogs",
            "summary", "status_colors", "evidence", "action_items"
        }
        assert required_keys <= set(report.keys()), (
            f"Report missing keys: {required_keys - set(report.keys())}"
        )

    def test_summary_counts_match_total_controls(self) -> None:
        catalogs, attestations, evidence = self._load()
        report = assemble_report(catalogs, attestations, evidence)
        total_controls = sum(len(c) for c in catalogs.values())
        summary_total = sum(report["summary"].values())
        assert summary_total == total_controls, (
            f"Summary counts ({summary_total}) don't match total controls ({total_controls})"
        )

    def test_action_items_are_only_unsatisfied(self) -> None:
        catalogs, attestations, evidence = self._load()
        report = assemble_report(catalogs, attestations, evidence)
        flagged_statuses = {"not-satisfied", "partial", "no-attestation"}
        for item in report["action_items"]:
            assert item["status"] in flagged_statuses, (
                f"Action item '{item['control_id']}' has unexpected status '{item['status']}'"
            )

    def test_regulations_list_nonempty(self) -> None:
        catalogs, attestations, evidence = self._load()
        report = assemble_report(catalogs, attestations, evidence)
        assert len(report["regulations"]) > 0


# ---------------------------------------------------------------------------
# Integration: main() produces a valid HTML report
# ---------------------------------------------------------------------------


class TestMainIntegration:
    def test_main_succeeds_and_produces_html(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "report.html"
            exit_code = main([
                "--output", str(output_path),
                "--catalog-dir", str(CATALOG_DIR),
                "--attestation-dir", str(ATTESTATION_DIR),
                "--evidence-dir", str(EVIDENCE_DIR) if EVIDENCE_DIR.exists() else str(CATALOG_DIR),
            ])
            assert exit_code == 0, "main() returned a non-zero exit code"
            assert output_path.exists(), "Output HTML file was not created"
            content = output_path.read_text(encoding="utf-8")
            assert "compliance-ops-bedrock" in content
            assert "<!DOCTYPE html>" in content

    def test_main_report_contains_all_catalog_titles(self) -> None:
        catalogs = load_catalogs(CATALOG_DIR)
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "report.html"
            main([
                "--output", str(output_path),
                "--catalog-dir", str(CATALOG_DIR),
                "--attestation-dir", str(ATTESTATION_DIR),
                "--evidence-dir", str(EVIDENCE_DIR) if EVIDENCE_DIR.exists() else str(CATALOG_DIR),
            ])
            content = output_path.read_text(encoding="utf-8")
            for title in catalogs:
                assert title in content, (
                    f"Catalog title '{title}' not found in generated report"
                )

    def test_main_with_missing_catalog_dir_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "report.html"
            exit_code = main([
                "--output", str(output_path),
                "--catalog-dir", "/nonexistent/path/that/does/not/exist",
                "--attestation-dir", str(ATTESTATION_DIR),
                "--evidence-dir", str(EVIDENCE_DIR) if EVIDENCE_DIR.exists() else str(CATALOG_DIR),
            ])
            assert exit_code != 0, "main() should fail when catalog dir is missing"
