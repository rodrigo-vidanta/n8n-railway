FROM node:20-alpine

# Instalar dependencias esenciales
RUN apk add --no-cache python3 make g++

# Instalar n8n y xlsx globalmente
RUN npm install -g n8n xlsx

# Variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

# Usuario por defecto
USER node
WORKDIR /home/node

EXPOSE 5678

CMD ["n8n", "start"]
