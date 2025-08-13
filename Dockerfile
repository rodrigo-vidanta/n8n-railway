FROM n8nio/n8n

# Cambiar a usuario root para instalar dependencias
USER root

# Instalar xlsx en el directorio correcto de n8n
RUN cd /usr/local/lib/node_modules/n8n && npm install xlsx

# Volver al usuario node
USER node

EXPOSE 5678
