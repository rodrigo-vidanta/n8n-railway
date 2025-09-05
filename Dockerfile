FROM n8nio/n8n:latest

USER root

# Install required packages
RUN echo "Installing required packages..." && \
    apk add --no-cache \
    curl \
    gettext \
    coreutils \
    openssl \
    ca-certificates \
    musl-dev && \
    echo "Curl installed successfully: $(curl --version | head -n 1)" && \
    echo "Envsubst installed successfully: $(envsubst --version | head -n 1)"

# Switch to n8n's installation directory
WORKDIR /usr/local/lib/node_modules/n8n

# Install OpenTelemetry dependencies + Langfuse specific instrumentations
RUN npm install \
    @opentelemetry/api \
    @opentelemetry/sdk-node \
    @opentelemetry/auto-instrumentations-node \
    @opentelemetry/exporter-trace-otlp-http \
    @opentelemetry/exporter-logs-otlp-http \
    @opentelemetry/resources \
    @opentelemetry/semantic-conventions \
    @opentelemetry/instrumentation \
    @opentelemetry/instrumentation-winston \
    @opentelemetry/winston-transport \
    @opentelemetry/context-async-hooks \
    winston \
    flat \
    xlsx \
    langfuse \
    langfuse-langchain \
    opentelemetry-instrumentation-anthropic \
    openinference-instrumentation-vertexai \
    openinference-instrumentation-google-genai

# Copy instrumentation files to n8n directory
COPY tracing-langfuse.js n8n-otel-instrumentation-langfuse.js docker-entrypoint-langfuse.sh ./
RUN chown node:node ./*.js ./*.sh

# Make entrypoint executable
RUN chmod +x ./docker-entrypoint-langfuse.sh

# Environment variables for n8n external functions
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx,langfuse,langfuse-langchain,opentelemetry-instrumentation-anthropic,openinference-instrumentation-vertexai,openinference-instrumentation-google-genai,@opentelemetry/api,@opentelemetry/sdk-node

# n8n configuration
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

# Langfuse configuration (to be set in Railway)
ENV LANGFUSE_SECRET_KEY=""
ENV LANGFUSE_PUBLIC_KEY=""
ENV LANGFUSE_BASEURL="https://cloud.langfuse.com"

# OpenTelemetry configuration for Langfuse
ENV OTEL_SERVICE_NAME="n8n-langfuse-tracing"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="https://cloud.langfuse.com/api/public/ingestion"
ENV OTEL_LOG_LEVEL="info"
ENV OTEL_RESOURCE_ATTRIBUTES="service.name=n8n-langfuse-tracing,service.version=1.0.0"

USER node

ENTRYPOINT ["tini", "--", "./docker-entrypoint-langfuse.sh"]
