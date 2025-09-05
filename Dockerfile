FROM node:20-alpine

# Instalar dependencias del sistema
RUN apk add --no-cache python3 make g++

# Instalar n8n y todas las dependencias de tracing
RUN npm install -g n8n xlsx langfuse langfuse-langchain \
    opentelemetry-instrumentation-anthropic \
    openinference-instrumentation-vertexai \
    openinference-instrumentation-google-genai

# Después de instalar n8n, instalar dependencias en el task-runner específico
RUN cd /usr/local/lib/node_modules/n8n && \
    find . -path "*/task-runner*/node_modules" -type d | head -1 | xargs -I {} sh -c 'cd "{}" && npm install xlsx langfuse langfuse-langchain opentelemetry-instrumentation-anthropic openinference-instrumentation-vertexai openinference-instrumentation-google-genai' || \
    echo "Task runner path not found, continuing..."

# Copiar todas las dependencias al directorio del task-runner
RUN mkdir -p "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules" && \
    cp -r /usr/local/lib/node_modules/xlsx "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" && \
    cp -r /usr/local/lib/node_modules/langfuse* "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" && \
    cp -r /usr/local/lib/node_modules/opentelemetry* "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" && \
    cp -r /usr/local/lib/node_modules/openinference* "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" || \
    echo "Specific path copy failed, continuing..."

# Variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx,langfuse,langfuse-langchain,opentelemetry-instrumentation-anthropic,openinference-instrumentation-vertexai,openinference-instrumentation-google-genai
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

# Variables de Langfuse
ENV LANGFUSE_SECRET_KEY=""
ENV LANGFUSE_PUBLIC_KEY=""
ENV LANGFUSE_BASEURL="https://cloud.langfuse.com"

# Variables de OpenTelemetry (críticas para funcionamiento nativo)
ENV OTEL_EXPORTER_OTLP_ENDPOINT="https://cloud.langfuse.com"
ENV OTEL_EXPORTER_OTLP_HEADERS=""
ENV OTEL_SERVICE_NAME="n8n-universal-tracing"
ENV OTEL_RESOURCE_ATTRIBUTES="service.name=n8n-universal-tracing,service.version=1.0.0"

USER node
WORKDIR /home/node
EXPOSE 5678
CMD ["n8n", "start"]
