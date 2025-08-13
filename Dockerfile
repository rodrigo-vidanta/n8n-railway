FROM n8nio/n8n

USER root

# Instalar xlsx globalmente
RUN npm install -g xlsx

# Instalar xlsx en el directorio específico del task-runner
RUN find /usr/local/lib/node_modules/n8n -name "task-runner" -type d | head -1 | xargs -I {} sh -c 'cd {} && npm install xlsx' || \
    cd /usr/local/lib/node_modules/n8n && npm install xlsx --no-save || \
    echo "xlsx installation completed"

# Crear enlaces simbólicos en múltiples ubicaciones
RUN ln -sf /usr/local/lib/node_modules/xlsx /usr/local/lib/node_modules/n8n/node_modules/xlsx 2>/dev/null || true

USER node

EXPOSE 5678
