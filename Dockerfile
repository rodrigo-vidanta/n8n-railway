FROM n8nio/n8n:latest

USER root

# Install required packages
RUN echo "Installing required packages..." && \
    apk add --no-cache \
    curl \
    gettext \
    coreutils \
    openssl \
    ca-certificates \
    musl-dev \
    tini && \
    echo "Packages installed successfully"

# Create a separate directory for our OpenTelemetry packages
WORKDIR /opt/otel

# Create package.json for our OpenTelemetry dependencies
RUN cat > package.json <<'EOF'
{
  "name": "n8n-otel-langfuse",
  "version": "1.0.0",
  "dependencies": {
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/sdk-node": "^0.52.1",
    "@opentelemetry/auto-instrumentations-node": "^0.49.1",
    "@opentelemetry/exporter-trace-otlp-http": "^0.52.1",
    "@opentelemetry/exporter-logs-otlp-http": "^0.52.1",
    "@opentelemetry/resources": "^1.25.1",
    "@opentelemetry/semantic-conventions": "^1.25.1",
    "@opentelemetry/instrumentation": "^0.52.1",
    "@opentelemetry/context-async-hooks": "^1.25.1",
    "winston": "^3.13.1",
    "flat": "^6.0.1"
  }
}
EOF

# Install OpenTelemetry dependencies
RUN npm install --production

# Copy node_modules to global location for access
RUN cp -r node_modules/* /usr/local/lib/node_modules/

# Switch to n8n's installation directory
WORKDIR /usr/local/lib/node_modules/n8n

# Create n8n instrumentation file
RUN cat > n8n-otel-instrumentation-langfuse.js <<'EOF'
const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');
const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

function setupN8nOpenTelemetry() {
  try {
    const { WorkflowExecute } = require('n8n-core');

    console.log("🔧 Setting up n8n manual instrumentation for Langfuse...");

    // Helper function to detect AI system from model name
    function detectAISystem(modelName) {
      if (!modelName || modelName === 'unknown') return 'unknown';
      const model = modelName.toLowerCase();
      
      if (model.includes('gpt') || model.includes('openai')) return 'openai';
      if (model.includes('claude') || model.includes('anthropic')) return 'anthropic';
      if (model.includes('gemini') || model.includes('google')) return 'google';
      if (model.includes('llama') || model.includes('meta')) return 'meta';
      if (model.includes('azure')) return 'azure_openai';
      if (model.includes('cohere')) return 'cohere';
      if (model.includes('mistral')) return 'mistral';
      if (model.includes('huggingface')) return 'huggingface';
      
      return 'other';
    }

    // Workflow-level instrumentation
    const originalProcessRun = WorkflowExecute.prototype.processRunExecutionData;
    WorkflowExecute.prototype.processRunExecutionData = function (workflow) {
      const wfData = workflow || {};
      const workflowId = wfData?.id ?? "unknown";
      const workflowName = wfData?.name ?? "unknown";

      console.log("📊 Starting workflow: " + workflowName + " (" + workflowId + ")");

      const workflowAttributes = {
        'langfuse.type': 'workflow',
        'langfuse.name': workflowName,
        'n8n.workflow.id': workflowId,
        'n8n.workflow.name': workflowName,
        'n8n.service': 'workflow-engine',
        ...flat(wfData?.settings ?? {}, { 
          delimiter: '.', 
          transformKey: (key) => 'n8n.workflow.settings.' + key
        }),
      };

      const span = tracer.startSpan('n8n.workflow.execute', {
        attributes: workflowAttributes,
        kind: SpanKind.INTERNAL
      });

      const activeContext = trace.setSpan(context.active(), span);
      return context.with(activeContext, () => {
        const cancelable = originalProcessRun.apply(this, arguments);

        cancelable.then(
          (result) => {
            console.log("✅ Workflow completed successfully");
            span.setAttributes({
              'langfuse.status': 'success',
              'n8n.workflow.nodes_executed': result?.data?.resultData?.runData ? Object.keys(result.data.resultData.runData).length : 0
            });

            if (result?.data?.resultData?.error) {
              const err = result.data.resultData.error;
              span.recordException(err);
              span.setStatus({
                code: SpanStatusCode.ERROR,
                message: String(err.message || err),
              });
              span.setAttributes({
                'lang
