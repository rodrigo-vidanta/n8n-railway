FROM node:20-alpine

# Instalar dependencias del sistema
RUN apk add --no-cache python3 make g++

# Copiar package.json e instalar dependencias
COPY package.json /tmp/package.json
RUN cd /tmp && npm install

# Instalar n8n globalmente
RUN npm install -g n8n

# Copiar dependencias al directorio de n8n y task-runner
RUN cp -r /tmp/node_modules/* /usr/local/lib/node_modules/ && \
    cd /usr/local/lib/node_modules/n8n && \
    find . -path "*/task-runner*/node_modules" -type d | head -1 | xargs -I {} sh -c 'cd "{}" && cp -r /tmp/node_modules/* ./' || \
    echo "Task runner path not found, continuing..."

# También copiar al path específico del task-runner si existe
RUN mkdir -p "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules" && \
    cp -r /tmp/node_modules/* "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" || \
    echo "Specific path copy failed, continuing..."

# Variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx,langfuse,langfuse-langchain,opentelemetry-instrumentation-anthropic,openinference-instrumentation-vertexai,openinference-instrumentation-google-genai
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

# Variables de Langfuse (configurar en Railway)
ENV LANGFUSE_SECRET_KEY=""
ENV LANGFUSE_PUBLIC_KEY=""
ENV LANGFUSE_BASEURL="https://cloud.langfuse.com"

USER node
WORKDIR /home/node
EXPOSE 5678
CMD ["n8n", "start"]
