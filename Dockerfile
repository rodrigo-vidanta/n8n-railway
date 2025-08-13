FROM n8nio/n8n

# Cambiar a root para modificaciones
USER root

# Instalar xlsx en múltiples ubicaciones para asegurar compatibilidad
RUN npm install -g xlsx && \
    cd /usr/local/lib/node_modules/n8n && \
    npm install xlsx && \
    cd /home/node && \
    npm install xlsx

# También instalarlo en el directorio del task-runner
RUN cd /usr/local/lib/node_modules/n8n/node_modules/.pnpm && \
    find . -name "task-runner*" -type d -exec sh -c 'cd "$1" && npm install xlsx' _ {} \; || true

# Crear enlace simbólico global
RUN ln -sf /usr/local/lib/node_modules/xlsx /usr/local/lib/node_modules/n8n/node_modules/xlsx || true

# Volver a usuario node
USER node

EXPOSE 5678

# Rebuild forzado - cambio 1
