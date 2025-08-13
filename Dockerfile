FROM n8nio/n8n

# Cambiar a root
USER root

# Instalar xlsx globalmente primero
RUN npm install -g xlsx

# Copiar xlsx al directorio de n8n usando enlaces simbólicos
RUN mkdir -p /usr/local/lib/node_modules/n8n/node_modules && \
    ln -sf /usr/local/lib/node_modules/xlsx /usr/local/lib/node_modules/n8n/node_modules/xlsx

# También crear enlace en el home del usuario node
RUN mkdir -p /home/node/node_modules && \
    ln -sf /usr/local/lib/node_modules/xlsx /home/node/node_modules/xlsx

# Volver a usuario node
USER node

EXPOSE 5678
