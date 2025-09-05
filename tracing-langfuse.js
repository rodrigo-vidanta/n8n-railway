const { NodeSDK } = require('@opentelemetry/sdk-node');
const { Resource } = require('@opentelemetry/resources');
const { SEMRESATTRS_SERVICE_NAME, SEMRESATTRS_SERVICE_VERSION, SEMRESATTRS_DEPLOYMENT_ENVIRONMENT } = require('@opentelemetry/semantic-conventions');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');

console.log("🚀 Initializing OpenTelemetry for n8n with Langfuse...");

// Create Basic Auth from existing Langfuse keys
const basicAuth = Buffer.from(`${process.env.LANGFUSE_PUBLIC_KEY}:${process.env.LANGFUSE_SECRET_KEY}`).toString('base64');

const traceExporter = new OTLPTraceExporter({
  url: `${process.env.LANGFUSE_BASEURL}/api/public/otel`,
  headers: {
    'Authorization': `Basic ${basicAuth}`
  },
});

const resource = new Resource({
  [SEMRESATTRS_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME,
  [SEMRESATTRS_SERVICE_VERSION]: '1.0.0',
  [SEMRESATTRS_DEPLOYMENT_ENVIRONMENT]: process.env.DEPLOYMENT_ENV,
  'langfuse.version': '1.0'
});

const sdk = new NodeSDK({
  resource: resource,
  traceExporter: traceExporter,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-http': { enabled: true }
    })
  ],
});

sdk.start();
console.log("✅ OpenTelemetry initialized successfully");

// Setup n8n specific instrumentation
try {
  const { setupN8nInstrumentation } = require('./n8n-instrumentation.js');
  setupN8nInstrumentation();
} catch (error) {
  console.error("❌ Failed to setup n8n instrumentation:", error);
}

process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('OpenTelemetry terminated'))
    .catch((error) => console.log('Error terminating OpenTelemetry', error))
    .finally(() => process.exit(0));
});
