FROM n8nio/n8n:latest

USER root

# Install required packages
RUN apk add --no-cache curl gettext coreutils openssl ca-certificates musl-dev tini

# Create directories
RUN mkdir -p /opt/otel /usr/local/lib/node_modules/n8n/otel

# Copy OpenTelemetry files
COPY otel/ /opt/otel/
WORKDIR /opt/otel

# Install OpenTelemetry dependencies
RUN npm install --production && \
    cp -r node_modules/* /usr/local/lib/node_modules/

# Copy initialization files to n8n directory
COPY tracing-langfuse.js /usr/local/lib/node_modules/n8n/
COPY otel/n8n-instrumentation.js /usr/local/lib/node_modules/n8n/

# Switch back to n8n user and directory
USER node
WORKDIR /usr/local/lib/node_modules/n8n

# Environment variables - NODE_OPTIONS will be overridden by Railway env vars

EXPOSE 5678
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["n8n", "start"]