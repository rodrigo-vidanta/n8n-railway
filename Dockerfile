FROM node:20-alpine

# Instalar dependencias
RUN apk add --no-cache python3 make g++

# Instalar n8n y xlsx globalmente
RUN npm install -g n8n xlsx

# Después de instalar n8n, instalar xlsx en el task-runner específico
RUN cd /usr/local/lib/node_modules/n8n && \
    find . -path "*/task-runner*/node_modules" -type d | head -1 | xargs -I {} sh -c 'cd "{}" && npm install xlsx' || \
    echo "Task runner path not found, continuing..."

# También copiar xlsx al directorio del task-runner usando el path exacto del error
RUN mkdir -p "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules" && \
    cp -r /usr/local/lib/node_modules/xlsx "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" || \
    echo "Specific path copy failed, continuing..."

# Variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

USER node
WORKDIR /home/node

EXPOSE 5678

CMD ["n8n", "start"]
