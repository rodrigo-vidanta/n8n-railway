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
                'langfuse.status': 'error',
                'langfuse.error.type': err.name || 'WorkflowError'
              });
            }
          },
          (error) => {
            console.error("❌ Workflow failed:", error.message);
            span.recordException(error);
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: String(error.message || error),
            });
            span.setAttributes({
              'langfuse.status': 'error',
              'langfuse.error.type': error.name || 'WorkflowError'
            });
          }
        ).finally(() => {
          span.end();
        });

        return cancelable;
      });
    };

    // Node-level instrumentation with enhanced LLM detection
    const originalRunNode = WorkflowExecute.prototype.runNode;
    WorkflowExecute.prototype.runNode = async function (
      workflow,
      executionData,
      runExecutionData,
      runIndex,
      additionalData,
      mode,
      abortSignal
    ) {
      if (!this) {
        console.warn('WorkflowExecute context is undefined');
        return originalRunNode.apply(this, arguments);
      }

      const executionId = additionalData?.executionId ?? 'unknown';
      const node = executionData?.node ?? {};
      const nodeType = node?.type ?? 'unknown';
      const nodeName = node?.name ?? 'unknown';
      
      // Enhanced LLM detection - covers more AI/LLM node types
      const isLLMNode = 
        nodeType.toLowerCase().includes('llm') || 
        nodeType.toLowerCase().includes('openai') ||
        nodeType.toLowerCase().includes('anthropic') ||
        nodeType.toLowerCase().includes('azure') ||
        nodeType.toLowerCase().includes('gemini') ||
        nodeType.toLowerCase().includes('claude') ||
        nodeType.toLowerCase().includes('vertex') ||
        nodeType.toLowerCase().includes('bedrock') ||
        nodeType.toLowerCase().includes('cohere') ||
        nodeType.toLowerCase().includes('huggingface') ||
        nodeType.toLowerCase().includes('mistral') ||
        nodeType.toLowerCase().includes('ai') ||
        nodeName.toLowerCase().includes('gpt') ||
        nodeName.toLowerCase().includes('claude') ||
        nodeName.toLowerCase().includes('llama') ||
        nodeName.toLowerCase().includes('langfuse') ||
        nodeType.includes('langchain');

      console.log("🔍 Processing node: " + nodeName + " (" + nodeType + ") - LLM: " + isLLMNode);

      const nodeAttributes = {
        'langfuse.type': isLLMNode ? 'generation' : 'span',
        'langfuse.name': nodeName,
        'n8n.node.type': nodeType,
        'n8n.node.name': nodeName,
        'n8n.workflow.id': workflow?.id ?? 'unknown',
        'n8n.execution.id': executionId,
        'n8n.node.is_llm': isLLMNode,
      };
      
      // Add LLM-specific attributes
      if (isLLMNode) {
        const nodeParams = node?.parameters ?? {};
        if (nodeParams.model) {
          nodeAttributes['langfuse.model'] = nodeParams.model;
        }
        if (nodeParams.temperature !== undefined) {
          nodeAttributes['langfuse.model.temperature'] = nodeParams.temperature;
        }
        if (nodeParams.maxTokens !== undefined) {
          nodeAttributes['langfuse.model.max_tokens'] = nodeParams.maxTokens;
        }
        console.log("🤖 LLM node detected: " + nodeName + " with model: " + (nodeParams.model || 'unknown'));
      }

      // Flatten node configuration
      const flattenedNode = flat(node ?? {}, { delimiter: '.' });
      for (const [key, value] of Object.entries(flattenedNode)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          nodeAttributes['n8n.node.' + key] = value;
        }
      }
      
      const spanName = isLLMNode ? 'n8n.llm.generation' : 'n8n.node.execute';
      
      return tracer.startActiveSpan(
        spanName,
        { attributes: nodeAttributes, kind: SpanKind.INTERNAL },
        async (nodeSpan) => {
          const startTime = Date.now();
          
          try {
            const result = await originalRunNode.apply(this, [
              workflow, executionData, runExecutionData, runIndex, additionalData, mode, abortSignal
            ]);
            
            const endTime = Date.now();
            const latency = endTime - startTime;
            
            console.log("⚡ Node executed in " + latency + "ms");
            
            // Capture results with enhanced LLM handling
            try {
              const outputData = result?.data?.[runIndex];
              const outputJson = outputData?.map((item) => item.json);
              
              nodeSpan.setAttributes({
                'langfuse.status': 'success',
                'langfuse.latency': latency,
                'n8n.node.output_count': outputData?.length || 0,
                'n8n.node.latency_ms': latency
              });

              // Enhanced LLM data extraction
              if (isLLMNode && outputJson && outputJson.length > 0) {
                const firstOutput = outputJson[0];
                console.log("📊 LLM Output keys:", Object.keys(firstOutput || {}));
                
                if (firstOutput && typeof firstOutput === 'object') {
                  // Token usage - try multiple possible formats
                  const usage = firstOutput.usage || firstOutput.token_usage || {};
                  if (Object.keys(usage).length > 0) {
                    nodeSpan.setAttributes({
                      'langfuse.usage.input': usage.prompt_tokens || usage.input_tokens || usage.input || 0,
                      'langfuse.usage.output': usage.completion_tokens || usage.output_tokens || usage.output || 0,
                      'langfuse.usage.total': usage.total_tokens || usage.total || 0
                    });
                    console.log("📈 Token usage captured:", usage);
                  }
                  
                  // Model response - try multiple possible response fields
                  const response = firstOutput.text || 
                                 firstOutput.content || 
                                 firstOutput.response || 
                                 firstOutput.output || 
                                 firstOutput.message?.content ||
                                 firstOutput.choices?.[0]?.message?.content ||
                                 firstOutput.choices?.[0]?.text;
                                 
                  if (response) {
                    const responseStr = typeof response === 'string' ? response : JSON.stringify(response);
                    nodeSpan.setAttribute('langfuse.generation.output', 
                      responseStr.length > 5000 ? responseStr.substring(0, 5000) + '...[truncated]' : responseStr
                    );
                    console.log("📝 Response captured (" + responseStr.length + " chars)");
                  }

                  // Input capture for LLM nodes
                  const inputData = executionData?.data?.main?.[0]?.[0]?.json;
                  if (inputData) {
                    const inputStr = typeof inputData === 'string' ? inputData : JSON.stringify(inputData);
                    nodeSpan.setAttribute('langfuse.generation.input', 
                      inputStr.length > 5000 ? inputStr.substring(0, 5000) + '...[truncated]' : inputStr
                    );
                  }

                  // Cost tracking if available
                  if (firstOutput.cost || firstOutput.price) {
                    const cost = firstOutput.cost || firstOutput.price;
                    nodeSpan.setAttribute('langfuse.usage.cost', typeof cost === 'number' ? cost : parseFloat(cost) || 0);
                  }
                }
              }

              // Store full output for non-LLM nodes (truncated)
              if (!isLLMNode && outputJson) {
                const outputString = JSON.stringify(outputJson);
                const truncatedOutput = outputString.length > 2000 ? 
                  outputString.substring(0, 2000) + '...[truncated]' : outputString;
                nodeSpan.setAttribute('n8n.node.output', truncatedOutput);
              }
              
            } catch (outputError) {
              console.warn('Failed to capture node output:', outputError.message);
            }
            
            return result;
            
          } catch (error) {
            const endTime = Date.now();
            const latency = endTime - startTime;
            
            console.error("❌ Node failed after " + latency + "ms:", error.message);
            
            nodeSpan.recordException(error);
            nodeSpan.setStatus({
              code: SpanStatusCode.ERROR,
              message: String(error.message || error),
            });
            
            nodeSpan.setAttributes({
              'langfuse.status': 'error',
              'langfuse.latency': latency,
              'langfuse.error.type': error.name || 'NodeExecutionError',
              'n8n.node.latency_ms': latency
            });
            
            throw error;
          } finally {
            nodeSpan.end();
          }
        }
      );
    };

    console.log("✅ n8n manual instrumentation configured successfully");

  } catch (e) {
    console.error("❌ Failed to set up n8n OpenTelemetry instrumentation:", e.message);
  }
}

module.exports = setupN8nOpenTelemetry;
EOF

# Create main tracing file
RUN cat > tracing-langfuse.js <<'EOF'
"use strict";

console.log("🔥 TRACING-LANGFUSE.JS LOADED!");
console.log("🔍 Working directory:", process.cwd());
console.log("🔍 Node version:", process.version);
console.log("🔍 LANGFUSE_BASEURL:", process.env.LANGFUSE_BASEURL);
console.log("🔍 LANGFUSE_SECRET_KEY presente:", !!process.env.LANGFUSE_SECRET_KEY);
console.log("🔍 LANGFUSE_PUBLIC_KEY presente:", !!process.env.LANGFUSE_PUBLIC_KEY);

// Exit early if credentials are missing
if (!process.env.LANGFUSE_SECRET_KEY || !process.env.LANGFUSE_PUBLIC_KEY || !process.env.LANGFUSE_BASEURL) {
  console.log("⚠️ Langfuse credentials missing, skipping OpenTelemetry setup");
  console.log("Secret key:", !!process.env.LANGFUSE_SECRET_KEY);
  console.log("Public key:", !!process.env.LANGFUSE_PUBLIC_KEY);  
  console.log("Base URL:", !!process.env.LANGFUSE_BASEURL);
  return;
}

// Enable async context propagation
const { context } = require("@opentelemetry/api");
try {
  const { AsyncHooksContextManager } = require("@opentelemetry/context-async-hooks");
  const activeManager = context._getContextManager();
  if (!activeManager || activeManager.constructor.name === 'NoopContextManager') {
    const contextManager = new AsyncHooksContextManager();
    context.setGlobalContextManager(contextManager.enable());
    console.log("✅ Async context manager enabled");
  } else {
    console.log("ℹ️ Context manager already active:", activeManager.constructor.name);
  }
} catch (error) {
  console.log("⚠️ Failed to setup context manager:", error.message);
}

const opentelemetry = require("@opentelemetry/sdk-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { registerInstrumentations } = require("@opentelemetry/instrumentation");
const { Resource } = require("@opentelemetry/resources");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");

console.log("🚀 Configuring OpenTelemetry SDK for Langfuse...");

// Calculate the correct endpoint based on Langfuse base URL
const langfuseEndpoint = process.env.LANGFUSE_BASEURL + "/api/public/otel/v1/traces";
console.log("📡 Endpoint:", langfuseEndpoint);

// Create Basic Auth token (as per Langfuse documentation)
const Buffer = require('buffer').Buffer;
const authToken = Buffer.from(process.env.LANGFUSE_PUBLIC_KEY + ":" + process.env.LANGFUSE_SECRET_KEY).toString('base64');
const langfuseHeaders = {
  'Authorization': 'Basic ' + authToken
};

console.log("🔑 Headers configured with Basic Auth");

// Setup basic instrumentations
const autoInstrumentations = getNodeAutoInstrumentations({
  "@opentelemetry/instrumentation-dns": { enabled: false },
  "@opentelemetry/instrumentation-net": { enabled: false },
  "@opentelemetry/instrumentation-tls": { enabled: false },
  "@opentelemetry/instrumentation-fs": { enabled: false },
  "@opentelemetry/instrumentation-http": { enabled: true },
  "@opentelemetry/instrumentation-express": { enabled: true },
  "@opentelemetry/instrumentation-pg": {
    enhancedDatabaseReporting: true,
  }
});

registerInstrumentations({
  instrumentations: [autoInstrumentations],
});

try {
  const traceExporter = new OTLPTraceExporter({
    url: langfuseEndpoint,
    headers: langfuseHeaders,
  });

  console.log("📤 OTLP Trace Exporter created");

  const sdk = new opentelemetry.NodeSDK({
    resource: new Resource({
      [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || "n8n-langfuse",
      [SemanticResourceAttributes.SERVICE_VERSION]: "1.0.0",
      'langfuse.version': '1.0',
      'deployment.environment': process.env.DEPLOYMENT_ENV || 'railway'
    }),
    traceExporter: traceExporter,
    instrumentations: [], // Already registered above
  });

  // Start SDK
  sdk.start();
  console.log("🎯 OpenTelemetry SDK started with Langfuse integration");
  
  // Setup n8n specific instrumentation
  const setupN8nOpenTelemetry = require("./n8n-otel-instrumentation-langfuse");
  setupN8nOpenTelemetry();
  
} catch (error) {
  console.log("❌ Failed to start SDK:", error.message);
  console.log("Stack:", error.stack);
}

// Error handling
process.on("uncaughtException", async (err) => {
  console.error("Uncaught Exception", err);
  process.exit(1);
});

process.on("unhandledRejection", (reason, promise) => {
  console.error("Unhandled Promise Rejection", reason);
});

console.log("🎉 Tracing setup completed");
EOF

# Create entrypoint script
RUN cat > docker-entrypoint-langfuse.sh <<'EOF'
#!/bin/sh

echo "🔧 Setting up n8n with Langfuse OpenTelemetry integration..."

# Force trust proxy for Railway
export N8N_TRUST_PROXY=true

# Validation
if [ -z "$LANGFUSE_SECRET_KEY" ]; then
    echo "⚠️ LANGFUSE_SECRET_KEY not provided, continuing without Langfuse"
fi

if [ -z "$LANGFUSE_PUBLIC_KEY" ]; then
    echo "⚠️ LANGFUSE_PUBLIC_KEY not provided, continuing without Langfuse"
fi

if [ -z "$LANGFUSE_BASEURL" ]; then
    echo "⚠️ LANGFUSE_BASEURL not provided, defaulting to US region"
    export LANGFUSE_BASEURL="https://us.cloud.langfuse.com"
fi

# OpenTelemetry configuration for Langfuse
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-n8n-langfuse}"
export OTEL_LOG_LEVEL="${OTEL_LOG_LEVEL:-info}"
export OTEL_RESOURCE_ATTRIBUTES="service.name=${OTEL_SERVICE_NAME},service.version=1.0.0,deployment.environment=${DEPLOYMENT_ENV:-railway}"

# Suppress duplicate registration warnings
export OTEL_SUPPRESS_DUPLICATE_REGISTRATION=true

echo "========================================="
echo "n8n + OpenTelemetry + Langfuse"
echo "========================================="
echo "Service: $OTEL_SERVICE_NAME"
echo "Langfuse: $LANGFUSE_BASEURL"
echo "Log Level: $OTEL_LOG_LEVEL"
echo "Trust Proxy: $N8N_TRUST_PROXY"
echo "========================================="

# Start n8n with OpenTelemetry
echo "Starting n8n with Langfuse OpenTelemetry instrumentation..."
exec node --require /usr/local/lib/node_modules/n8n/tracing-langfuse.js /usr/local/bin/n8n "$@"
EOF

# Make scripts executable and set ownership
RUN chmod +x docker-entrypoint-langfuse.sh && \
    chown node:node *.js *.sh

# Environment variables
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx,langfuse,@opentelemetry/api,@opentelemetry/sdk-node,winston,flat
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678
ENV N8N_TRUST_PROXY=true

# Default Langfuse configuration (override in Railway)
ENV LANGFUSE_SECRET_KEY=""
ENV LANGFUSE_PUBLIC_KEY=""
ENV LANGFUSE_BASEURL="https://us.cloud.langfuse.com"

# OpenTelemetry configuration
ENV OTEL_SERVICE_NAME="n8n-langfuse-production"
ENV OTEL_LOG_LEVEL="info"
ENV OTEL_SUPPRESS_DUPLICATE_REGISTRATION="true"
ENV DEPLOYMENT_ENV="railway"

USER node
WORKDIR /home/node
EXPOSE 5678

ENTRYPOINT ["tini", "--", "/usr/local/lib/node_modules/n8n/docker-entrypoint-langfuse.sh"]
