# compliance-ops-bedrock — dev/CI container
# Used for: evidence collection, report generation, OSCAL tooling
# Python 3.11 for compatibility with compliance-trestle

FROM python:3.11-slim

WORKDIR /app

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
  && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 (lightweight)
RUN pip install --no-cache-dir awscli

# Python deps
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy scripts and compliance artifacts (not the whole repo in prod)
COPY scripts/ ./scripts/
COPY compliance/ ./compliance/
COPY attestations/ ./attestations/
COPY report/ ./report/

CMD ["python", "scripts/collect_evidence.py", "--help"]
