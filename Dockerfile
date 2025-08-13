FROM n8nio/n8n

# Instalar xlsx
USER root
RUN npm install -g xlsx
USER node

EXPOSE 5678
