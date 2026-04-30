# compliance-ops-bedrock — Lambda/AgentCore container image
#
# Uses the AWS-provided Lambda Python 3.12 base image for arm64.
# The arm64 architecture is required by Bedrock AgentCore Runtime and also
# provides Lambda Graviton2 cost/performance benefits.
#
# Entry points:
#   - Lambda: app.handler.handler  (POST /report)
#   - AgentCore: app.agentcore_app  (POST /invocations via BedrockAgentCoreApp)
#
# Build context: repository root (docker build --platform linux/arm64 -f app/Dockerfile .)
# so that the app/ package is available at /var/task/app/.

FROM public.ecr.aws/lambda/python:3.12-arm64

# Install runtime dependencies.
# compliance-trestle and other heavy dev deps are NOT included here.
COPY app/requirements-lambda.txt ./
RUN pip install --no-cache-dir -r requirements-lambda.txt

# Copy the application package and report-generation scripts.
# Use explicit absolute paths rather than ${LAMBDA_TASK_ROOT} to avoid
# any shell/BuildKit variable-expansion ambiguity.
COPY app/ /var/task/app/
COPY scripts/ /var/task/scripts/
COPY compliance/ /var/task/compliance/
COPY attestations/ /var/task/attestations/
COPY evidence/ /var/task/evidence/

# Lambda handler: module path = app.handler, function = handler
CMD ["app.handler.handler"]
