FROM n8nio/n8n

USER root

# Instalar xlsx globalmente
RUN npm install -g xlsx

# Encontrar e instalar xlsx en el directorio específico del task-runner
RUN cd /usr/local/lib/node_modules/n8n/node_modules/.pnpm && \
    find . -name "*task-runner*" -type d | head -1 | xargs -I {} sh -c 'cd "{}" && mkdir -p node_modules && cp -r /usr/local/lib/node_modules/xlsx node_modules/' || \
    echo "Task runner directory not found, trying alternative approach"

# Crear enlace directo en el path que muestra el error
RUN mkdir -p "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules" && \
    cp -r /usr/local/lib/node_modules/xlsx "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" || \
    echo "Specific path not found"

# Enlaces adicionales
RUN ln -sf /usr/local/lib/node_modules/xlsx /usr/local/lib/node_modules/n8n/node_modules/xlsx 2>/dev/null || true

USER node

EXPOSE 5678
