FROM node:20-alpine

USER root

# Install system dependencies
RUN echo "Installing system packages..." && \
    apk add --no-cache \
    curl \
    gettext \
    coreutils \
    openssl \
    ca-certificates \
    musl-dev \
    python3 \
    make \
    g++ \
    tini

# Copy package.json and install dependencies
COPY package.json /tmp/package.json
RUN cd /tmp && npm install --production

# Install n8n globally
RUN npm install -g n8n

# Switch to n8n's installation directory
WORKDIR /usr/local/lib/node_modules/n8n

# Copy all dependencies to global node_modules and n8n directory
RUN cp -r /tmp/node_modules/* /usr/local/lib/node_modules/ && \
    echo "Dependencies copied to global node_modules"

# Copy dependencies to n8n task-runner (multiple possible paths)
RUN cd /usr/local/lib/node_modules/n8n && \
    find . -path "*/task-runner*/node_modules" -type d | head -1 | xargs -I {} sh -c 'cd "{}" && cp -r /tmp/node_modules/* ./' || \
    echo "Task runner path not found via find, trying alternative..."

# Copy to specific pnpm path if it exists
RUN mkdir -p "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules" && \
    cp -r /tmp/node_modules/* "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+task-runner@file+packages+@n8n+task-runner_@opentelemetry+api@1.9.0_@opentelemetry_4ae381f08d5de33c403d45aa26683c87/node_modules/" || \
    echo "Specific pnpm path copy failed, continuing..."

# Create OpenTelemetry instrumentation files
RUN cat > tracing-langfuse.js <<EOF
"use strict";

// Enable proper async context propagation globally
const { AsyncHooksContextManager } = require("@opentelemetry/context-async-hooks");
const { context } = require("@opentelemetry/api");
const contextManager = new AsyncHooksContextManager();
context.setGlobalContextManager(contextManager.enable());

const opentelemetry = require("@opentelemetry/sdk-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { OTLPLogExporter } = require("@opentelemetry/exporter-logs-otlp-http");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { registerInstrumentations } = require("@opentelemetry/instrumentation");
const { Resource } = require("@opentelemetry/resources");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");
const setupN8nOpenTelemetry = require("./n8n-otel-instrumentation-langfuse");
const winston = require("winston");

const logger = winston.createLogger({
  level: "info",
  format: winston.format.json(),
  transports: [new winston.transports.Console()],
});

// Setup instrumentations
const instrumentations = [];

// Auto instrumentations (optimized for n8n)
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

instrumentations.push(autoInstrumentations);

// Add LLM provider specific instrumentations
try {
  const { AnthropicInstrumentor } = require('opentelemetry-instrumentation-anthropic');
  instrumentations.push(new AnthropicInstrumentor());
  console.log("✅ Anthropic OpenTelemetry instrumentation loaded");
} catch (error) {
  console.log("⚠️ Anthropic OpenTelemetry instrumentation not available");
}

try {
  const { VertexAIInstrumentor } = require('openinference-instrumentation-vertexai');
  instrumentations.push(new VertexAIInstrumentor());
  console.log("✅ Vertex AI OpenTelemetry instrumentation loaded");
} catch (error) {
  console.log("⚠️ Vertex AI OpenTelemetry instrumentation not available");
}

try {
  const { GoogleGenAIInstrumentor } = require('openinference-instrumentation-google-genai');
  instrumentations.push(new GoogleGenAIInstrumentor());
  console.log("✅ Google GenAI OpenTelemetry instrumentation loaded");
} catch (error) {
  console.log("⚠️ Google GenAI OpenTelemetry instrumentation not available");
}

registerInstrumentations({
  instrumentations: instrumentations,
});

// Setup n8n specific instrumentation
setupN8nOpenTelemetry();

// Configure Langfuse headers
const langfuseHeaders = {
  'Authorization': \`Bearer \${process.env.LANGFUSE_SECRET_KEY}\`,
  'x-langfuse-public-key': process.env.LANGFUSE_PUBLIC_KEY
};

console.log("🚀 Configuring OpenTelemetry SDK for Langfuse...");
console.log("📡 Endpoint:", process.env.LANGFUSE_BASEURL + "/api/public/ingestion");

const sdk = new opentelemetry.NodeSDK({
  logRecordProcessors: [
    new opentelemetry.logs.SimpleLogRecordProcessor(new OTLPLogExporter({
      url: process.env.LANGFUSE_BASEURL + "/api/public/ingestion",
      headers: langfuseHeaders,
    })),
  ],
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || "n8n-langfuse",
    [SemanticResourceAttributes.SERVICE_VERSION]: "1.0.0",
    'langfuse.version': '1.0',
    'deployment.environment': 'railway'
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.LANGFUSE_BASEURL + "/api/public/ingestion",
    headers: langfuseHeaders,
  }),
});

// Error handling
process.on("uncaughtException", async (err) => {
  logger.error("Uncaught Exception", { error: err });
  const span = opentelemetry.trace.getActiveSpan();
  if (span) {
    span.recordException(err);
    span.setStatus({ code: 2, message: err.message });
  }
  try {
    await sdk.forceFlush();
  } catch (flushErr) {
    logger.error("Error flushing telemetry data", { error: flushErr });
  }
  process.exit(1);
});

process.on("unhandledRejection", (reason, promise) => {
  logger.error("Unhandled Promise Rejection", { error: reason });
});

// Start SDK
sdk.start();
console.log("🎯 OpenTelemetry SDK started with Langfuse integration");
EOF

RUN cat > n8n-otel-instrumentation-langfuse.js <<EOF
const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');
const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

function setupN8nOpenTelemetry() {
  try {
    const { WorkflowExecute } = require('n8n-core');

    // Workflow-level instrumentation
    const originalProcessRun = WorkflowExecute.prototype.processRunExecutionData;
    WorkflowExecute.prototype.processRunExecutionData = function (workflow) {
      const wfData = workflow || {};
      const workflowId = wfData?.id ?? "unknown"
      const workflowName = wfData?.name ?? "unknown"

      const workflowAttributes = {
        'langfuse.type': 'workflow',
        'langfuse.name': workflowName,
        'n8n.workflow.id': workflowId,
        'n8n.workflow.name': workflowName,
        'n8n.service': 'workflow-engine',
        ...flat(wfData?.settings ?? {}, { 
          delimiter: '.', 
          transformKey: (key) => \`n8n.workflow.settings.\${key}\` 
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

    // Node-level instrumentation with LLM detection
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
      
      // Enhanced LLM detection
      const isLLMNode = nodeType.toLowerCase().includes('llm') || 
                       nodeType.toLowerCase().includes('openai') ||
                       nodeType.toLowerCase().includes('anthropic') ||
                       nodeType.toLowerCase().includes('azure') ||
                       nodeType.toLowerCase().includes('gemini') ||
                       nodeType.toLowerCase().includes('claude') ||
                       nodeType.toLowerCase().includes('vertex') ||
                       nodeType.toLowerCase().includes('bedrock') ||
                       nodeType.toLowerCase().includes('cohere') ||
                       nodeName.toLowerCase().includes('langfuse');

      const nodeAttributes = {
        'langfuse.type': isLLMNode ? 'generation' : 'span',
        'langfuse.name': nodeName,
        'n8n.node.type': nodeType,
        'n8n.node.name': nodeName,
        'n8n.workflow.id': workflow?.id ?? 'unknown',
        'n8n.execution.id': executionId,
        'n8n.node.is_llm': isLLMNode,
      };
      
      // LLM-specific attributes
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
      }

      // Flatten node configuration
      const flattenedNode = flat(node ?? {}, { delimiter: '.' });
      for (const [key, value] of Object.entries(flattenedNode)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          nodeAttributes[\`n8n.node.\${key}\`] = value;
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
                if (firstOutput && typeof firstOutput === 'object') {
                  // Token usage
                  if (firstOutput.usage) {
                    nodeSpan.setAttributes({
                      'langfuse.usage.input': firstOutput.usage.prompt_tokens || firstOutput.usage.input || 0,
                      'langfuse.usage.output': firstOutput.usage.completion_tokens || firstOutput.usage.output || 0,
                      'langfuse.usage.total': firstOutput.usage.total_tokens || firstOutput.usage.total || 0
                    });
                  }
                  
                  // Model response
                  const response = firstOutput.text || firstOutput.content || firstOutput.response || firstOutput.output;
                  if (response) {
                    const responseStr = typeof response === 'string' ? response : JSON.stringify(response);
                    nodeSpan.setAttribute('langfuse.generation.output', responseStr.length > 5000 ? responseStr.substring(0, 5000) + '...[truncated]' : responseStr);
                  }

                  // Input capture for LLM nodes
                  const inputData = executionData?.data?.main?.[0]?.[0]?.json;
                  if (inputData) {
                    const inputStr = typeof inputData === 'string' ? inputData : JSON.stringify(inputData);
                    nodeSpan.setAttribute('langfuse.generation.input', inputStr.length > 5000 ? inputStr.substring(0, 5000) + '...[truncated]' : inputStr);
                  }

                  // Cost tracking if available
                  if (firstOutput.cost || firstOutput.price) {
                    const cost = firstOutput.cost || firstOutput.price;
                    nodeSpan.setAttribute('langfuse.usage.cost', typeof cost === 'number' ? cost : parseFloat(cost) || 0);
                  }
                }
              }

              // Store full output for non-LLM nodes (truncated)
              if (!isLLMNode) {
                const outputString = JSON.stringify(outputJson);
                const truncatedOutput = outputString.length > 2000 ? 
                  outputString.substring(0, 2000) + '...[truncated]' : outputString;
                nodeSpan.setAttribute('n8n.node.output', truncatedOutput);
              }
              
            } catch (outputError) {
              console.warn('Failed to capture node output:', outputError);
            }
            
            return result;
            
          } catch (error) {
            const endTime = Date.now();
            const latency = endTime - startTime;
            
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

    console.log("✅ n8n OpenTelemetry instrumentation configured for Langfuse");

  } catch (e) {
    console.error("❌ Failed to set up n8n OpenTelemetry instrumentation:", e);
  }
}

module.exports = setupN8nOpenTelemetry;
EOF

RUN cat > docker-entrypoint-langfuse.sh <<EOF
#!/bin/sh

# Validation
if [ -z "\$LANGFUSE_SECRET_KEY" ]; then
    echo "ERROR: LANGFUSE_SECRET_KEY is required"
    exit 1
fi

if [ -z "\$LANGFUSE_PUBLIC_KEY" ]; then
    echo "ERROR: LANGFUSE_PUBLIC_KEY is required"
    exit 1
fi

# OpenTelemetry configuration for Langfuse
export OTEL_SERVICE_NAME="\${OTEL_SERVICE_NAME:-n8n-langfuse}"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_LOG_LEVEL="\${OTEL_LOG_LEVEL:-info}"
export OTEL_RESOURCE_ATTRIBUTES="service.name=\${OTEL_SERVICE_NAME},service.version=1.0.0,deployment.environment=railway"

echo "========================================="
echo "n8n + OpenTelemetry + Langfuse"
echo "========================================="
echo "Service: \$OTEL_SERVICE_NAME"
echo "Langfuse: \$LANGFUSE_BASEURL"
echo "Log Level: \$OTEL_LOG_LEVEL"
echo "========================================="

# Start n8n with OpenTelemetry
echo "Starting n8n with full OpenTelemetry instrumentation..."
exec node --require /usr/local/lib/node_modules/n8n/tracing-langfuse.js /usr/local/bin/n8n "\$@"
EOF

# Make scripts executable and set ownership
RUN chmod +x docker-entrypoint-langfuse.sh && \
    chown node:node *.js *.sh

# Environment variables
ENV NODE_FUNCTION_ALLOW_EXTERNAL=xlsx,langfuse,langfuse-langchain,@opentelemetry/api,@opentelemetry/sdk-node,opentelemetry-instrumentation-anthropic,openinference-instrumentation-vertexai,openinference-instrumentation-google-genai,winston,flat
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678

# Langfuse configuration (set in Railway)
ENV LANGFUSE_SECRET_KEY=""
ENV LANGFUSE_PUBLIC_KEY=""
ENV LANGFUSE_BASEURL="https://cloud.langfuse.com"

# OpenTelemetry configuration
ENV OTEL_SERVICE_NAME="n8n-langfuse-production"
ENV OTEL_LOG_LEVEL="info"

USER node
WORKDIR /home/node
EXPOSE 5678

ENTRYPOINT ["tini", "--", "/usr/local/lib/node_modules/n8n/docker-entrypoint-langfuse.sh"]
