FROM node:18-alpine

# Instalar dependencias del sistema
RUN apk add --no-cache \
    python3 \
    make \
    g++ \
    git \
    curl

# Crear usuario node
RUN addgroup -g 1000 node && adduser -u 1000 -G node -s /bin/sh -D node

# Instalar n8n y xlsx como usuario root
RUN npm install -g n8n@1.106.3 xlsx

# Configurar variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678
ENV N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Cambiar a usuario node
USER node
WORKDIR /home/node

# Verificar que xlsx esté disponible (debugging)
RUN node -e "console.log('xlsx test:', require('xlsx').version)" || echo "xlsx not found"

EXPOSE 5678

CMD ["n8n", "start"]
