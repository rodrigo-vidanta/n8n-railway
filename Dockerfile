FROM node:18-alpine

# Instalar dependencias
RUN apk add --no-cache python3 make g++ git

# Crear usuario
RUN addgroup -g 1000 node && adduser -u 1000 -G node -s /bin/sh -D node

# Instalar n8n y xlsx
RUN npm install -g n8n xlsx

# Variables de entorno
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

USER node
WORKDIR /home/node

EXPOSE 5678

CMD ["n8n", "start"]
