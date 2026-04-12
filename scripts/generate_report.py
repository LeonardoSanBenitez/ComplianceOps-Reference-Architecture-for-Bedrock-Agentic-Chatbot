#!/usr/bin/env python3
"""
Compliance report generator for compliance-ops-bedrock.

Reads:
  - compliance/catalogs/*.yaml  (OSCAL control catalogs)
  - attestations/*.yaml         (human attestations with justifications)
  - evidence/automated/*.json   (automated evidence artifacts)

Produces:
  - report/index.html           (static HTML compliance report)

Usage:
    python scripts/generate_report.py [--output report/index.html]

Requirements:
    pip install pyyaml jinja2
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Report template
# ---------------------------------------------------------------------------

REPORT_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Compliance Report — compliance-ops-bedrock</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 0; background: #f8f9fa; color: #212529; }
  .container { max-width: 1100px; margin: 0 auto; padding: 2rem; }
  h1 { font-size: 1.8rem; border-bottom: 3px solid #0d6efd; padding-bottom: 0.5rem; }
  h2 { font-size: 1.3rem; color: #495057; margin-top: 2rem; }
  h3 { font-size: 1.1rem; color: #343a40; }
  .meta { color: #6c757d; font-size: 0.9rem; margin-bottom: 2rem; }
  .status-badge { display: inline-block; padding: 0.2em 0.6em; border-radius: 3px; font-size: 0.8rem; font-weight: 600; }
  .status-satisfied { background: #d1e7dd; color: #0a3622; }
  .status-partial { background: #fff3cd; color: #664d03; }
  .status-not-satisfied { background: #f8d7da; color: #58151c; }
  .status-not-applicable { background: #e2e3e5; color: #41464b; }
  .status-exception { background: #f0d5ff; color: #3d0066; }
  .status-no-attestation { background: #f8d7da; color: #58151c; }
  .control-card { background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 1.2rem; margin-bottom: 1rem; }
  .control-header { display: flex; align-items: flex-start; gap: 1rem; }
  .control-id { font-family: monospace; font-size: 0.85rem; color: #6c757d; }
  .control-title { font-weight: 600; flex-grow: 1; }
  .attestation-block { margin-top: 0.8rem; border-top: 1px solid #e9ecef; padding-top: 0.8rem; }
  .decision { font-weight: 500; }
  .justification { font-size: 0.9rem; color: #495057; margin-top: 0.4rem; white-space: pre-wrap; }
  .meta-line { font-size: 0.8rem; color: #6c757d; margin-top: 0.4rem; }
  .evidence-list { font-size: 0.85rem; margin-top: 0.4rem; }
  .evidence-list code { background: #f8f9fa; padding: 0.1em 0.4em; border-radius: 3px; }
  .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 1rem; margin: 1.5rem 0; }
  .summary-cell { background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 1rem; text-align: center; }
  .summary-cell .count { font-size: 2rem; font-weight: 700; }
  .summary-cell .label { font-size: 0.8rem; color: #6c757d; }
  .evidence-section { background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 1.2rem; margin-bottom: 1rem; }
  .warning { background: #fff3cd; border: 1px solid #ffc107; border-radius: 6px; padding: 0.8rem 1rem; margin-bottom: 1rem; font-size: 0.9rem; }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th { background: #f8f9fa; text-align: left; padding: 0.5rem 0.8rem; border-bottom: 2px solid #dee2e6; }
  td { padding: 0.5rem 0.8rem; border-bottom: 1px solid #e9ecef; vertical-align: top; }
</style>
</head>
<body>
<div class="container">

<h1>Compliance Report — compliance-ops-bedrock</h1>
<div class="meta">
  Generated: {{ generated_at }}<br>
  Scope: compliance-ops-bedrock demo application (chatbot on AWS Bedrock)<br>
  Regulations covered: {{ regulations | join(', ') }}<br>
  <strong>Disclaimer: This is a prototype report. It is not authoritative compliance evidence.</strong>
</div>

<div class="warning">
  This report covers the demo system only. It does not assess the broader organisation.
  Controls marked "not-satisfied" are known gaps and must be addressed before processing real personal data.
</div>

<!-- Summary -->
<h2>Coverage Summary</h2>
<div class="summary-grid">
  {% for status, count in summary.items() %}
  <div class="summary-cell">
    <div class="count" style="color: {{ status_colors[status] }}">{{ count }}</div>
    <div class="label">{{ status | replace('-', ' ') }}</div>
  </div>
  {% endfor %}
</div>

<!-- Controls by catalog -->
{% for catalog_title, controls in catalogs.items() %}
<h2>{{ catalog_title }}</h2>
{% for control in controls %}
<div class="control-card">
  <div class="control-header">
    <div class="control-title">{{ control.title }}</div>
    <span class="status-badge status-{{ control.status | replace('_', '-') }}">{{ control.status | replace('-', ' ') }}</span>
  </div>
  <div class="control-id">{{ control.id }} &mdash; {{ control.regulation_reference }}</div>

  {% if control.attestation %}
  <div class="attestation-block">
    <div class="decision">{{ control.attestation.decision }}</div>
    <div class="justification">{{ control.attestation.justification }}</div>
    <div class="meta-line">
      Reviewed by: {{ control.attestation['reviewed-by'] }} &mdash;
      {{ control.attestation['reviewed-at'] }}
    </div>
    {% if control.attestation.get('expires-at') %}
    <div class="meta-line" style="color: #dc3545;">Expires: {{ control.attestation['expires-at'] }}</div>
    {% endif %}
    {% if control.attestation.get('evidence-refs') %}
    <div class="evidence-list">
      Evidence: {% for ref in control.attestation['evidence-refs'] %}<code>{{ ref }}</code> {% endfor %}
    </div>
    {% endif %}
    {% if control.attestation.get('compensating-controls') %}
    <div class="meta-line">Compensating: {{ control.attestation['compensating-controls'] | join(', ') }}</div>
    {% endif %}
  </div>
  {% else %}
  <div class="attestation-block" style="color: #dc3545;">
    No attestation found for this control. This is an open gap.
  </div>
  {% endif %}
</div>
{% endfor %}
{% endfor %}

<!-- Automated Evidence -->
<h2>Automated Evidence Artifacts</h2>
{% for artifact in evidence %}
<div class="evidence-section">
  <h3>{{ artifact.collector_id }}</h3>
  <div class="meta">Collected: {{ artifact.collected_at }} &mdash; Status: <strong>{{ artifact.status }}</strong></div>
  <div>{{ artifact.description }}</div>
  {% if artifact.controls %}
  <div class="meta-line">Controls: {{ artifact.controls | join(', ') }}</div>
  {% endif %}
</div>
{% endfor %}

<!-- Action Items -->
<h2>Action Items (Not Satisfied / Partial)</h2>
<table>
<tr><th>Control</th><th>Status</th><th>Decision</th></tr>
{% for item in action_items %}
<tr>
  <td><code>{{ item.control_id }}</code></td>
  <td><span class="status-badge status-{{ item.status }}">{{ item.status }}</span></td>
  <td>{{ item.decision }}</td>
</tr>
{% endfor %}
{% if not action_items %}
<tr><td colspan="3">No action items.</td></tr>
{% endif %}
</table>

</div>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_catalogs(catalog_dir: Path) -> dict[str, list[dict[str, Any]]]:
    """Load all OSCAL catalog YAML files. Returns {catalog_title: [controls]}."""
    catalogs: dict[str, list[dict[str, Any]]] = {}
    for fpath in sorted(catalog_dir.glob("*.yaml")):
        with fpath.open() as f:
            raw = yaml.safe_load(f)
        catalog = raw.get("catalog", {})
        title = catalog.get("metadata", {}).get("title", fpath.stem)
        controls: list[dict[str, Any]] = []
        for group in catalog.get("groups", []):
            for ctrl in group.get("controls", []):
                reg_ref = ""
                for prop in ctrl.get("props", []):
                    if prop.get("name") == "regulation-reference":
                        reg_ref = prop.get("value", "")
                controls.append({
                    "id": ctrl["id"],
                    "title": ctrl.get("title", ""),
                    "regulation_reference": reg_ref,
                })
        catalogs[title] = controls
    return catalogs


def load_attestations(attestation_dir: Path) -> dict[str, dict[str, Any]]:
    """Load all attestation YAML files. Returns {control-id: attestation}."""
    attestations: dict[str, dict[str, Any]] = {}
    for fpath in sorted(attestation_dir.glob("*.yaml")):
        if fpath.name == "schema.yaml":
            continue
        with fpath.open() as f:
            raw = yaml.safe_load(f)
        for att in raw.get("attestations", []):
            control_id = att.get("control-id", "")
            if control_id:
                attestations[control_id] = att
    return attestations


def load_evidence(evidence_dir: Path) -> list[dict[str, Any]]:
    """Load all automated evidence artifacts."""
    artifacts = []
    for fpath in sorted(evidence_dir.glob("*.json")):
        if fpath.name == "manifest.json":
            continue
        with fpath.open() as f:
            artifacts.append(json.load(f))
    return artifacts


# ---------------------------------------------------------------------------
# Report data assembly
# ---------------------------------------------------------------------------

STATUS_COLORS = {
    "satisfied": "#198754",
    "partial": "#ffc107",
    "not-satisfied": "#dc3545",
    "not-applicable": "#6c757d",
    "exception": "#6f42c1",
    "no-attestation": "#dc3545",
}


def assemble_report(
    catalogs_raw: dict[str, list[dict[str, Any]]],
    attestations: dict[str, dict[str, Any]],
    evidence: list[dict[str, Any]],
) -> dict[str, Any]:
    from collections import Counter
    summary: Counter[str] = Counter()
    catalogs_rendered: dict[str, list[dict[str, Any]]] = {}
    action_items: list[dict[str, Any]] = []
    regulations: list[str] = []

    for catalog_title, controls in catalogs_raw.items():
        rendered_controls = []
        for ctrl in controls:
            att = attestations.get(ctrl["id"])
            if att:
                status = att.get("status", "no-attestation").replace("_", "-")
            else:
                status = "no-attestation"
            summary[status] += 1
            rendered_controls.append({
                **ctrl,
                "status": status,
                "attestation": att,
            })
            if status in ("not-satisfied", "partial", "no-attestation"):
                decision = att.get("decision", "No attestation") if att else "No attestation on record."
                action_items.append({
                    "control_id": ctrl["id"],
                    "status": status,
                    "decision": decision,
                })
        catalogs_rendered[catalog_title] = rendered_controls
        if "GDPR" in catalog_title:
            regulations.append("GDPR")
        elif "AI Act" in catalog_title:
            regulations.append("EU AI Act")

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "regulations": sorted(set(regulations)),
        "catalogs": catalogs_rendered,
        "summary": dict(summary),
        "status_colors": STATUS_COLORS,
        "evidence": evidence,
        "action_items": action_items,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    parser = argparse.ArgumentParser(description="Generate compliance report.")
    parser.add_argument("--output", default="report/index.html", help="Output HTML file path")
    parser.add_argument("--catalog-dir", default="compliance/catalogs", help="OSCAL catalog directory")
    parser.add_argument("--attestation-dir", default="attestations", help="Attestation YAML directory")
    parser.add_argument("--evidence-dir", default="evidence/automated", help="Automated evidence directory")
    args = parser.parse_args(argv)

    try:
        from jinja2 import Environment
    except ImportError:
        logger.error("jinja2 not installed. Run: pip install pyyaml jinja2")
        return 1

    catalog_dir = Path(args.catalog_dir)
    attestation_dir = Path(args.attestation_dir)
    evidence_dir = Path(args.evidence_dir)
    output_path = Path(args.output)

    if not catalog_dir.exists():
        logger.error("Catalog directory not found: %s", catalog_dir)
        return 1

    catalogs_raw = load_catalogs(catalog_dir)
    logger.info("Loaded %d catalog(s), %d total controls",
                len(catalogs_raw), sum(len(c) for c in catalogs_raw.values()))

    attestations = load_attestations(attestation_dir) if attestation_dir.exists() else {}
    logger.info("Loaded %d attestation(s)", len(attestations))

    evidence = load_evidence(evidence_dir) if evidence_dir.exists() else []
    logger.info("Loaded %d evidence artifact(s)", len(evidence))

    report_data = assemble_report(catalogs_raw, attestations, evidence)

    env = Environment(autoescape=True)
    env.filters["replace"] = lambda s, old, new: str(s).replace(old, new)
    template = env.from_string(REPORT_TEMPLATE)
    html = template.render(**report_data)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")
    logger.info("Report written to: %s", output_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
