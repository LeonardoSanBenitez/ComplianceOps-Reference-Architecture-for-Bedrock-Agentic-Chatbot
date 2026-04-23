# compliance-ops-bedrock — Lambda container image for the chat endpoint
#
# Uses the AWS-provided Lambda Python 3.11 base image.
# The handler entry point is app.handler.handler (module.file.function).
#
# Build context: repository root (docker build -t <tag> -f app/Dockerfile .)
# so that the app/ package is available at /var/task/app/.

FROM public.ecr.aws/lambda/python:3.11

# Install runtime dependencies.
# compliance-trestle and other heavy dev deps are NOT included here.
COPY app/requirements-lambda.txt ./
RUN pip install --no-cache-dir -r requirements-lambda.txt

# Copy the application package.
COPY app/ ${LAMBDA_TASK_ROOT}/app/

# Lambda handler: module path = app.handler, function = handler
CMD ["app.handler.handler"]
