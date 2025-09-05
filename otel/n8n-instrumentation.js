const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');

function setupN8nInstrumentation() {
  try {
    const { WorkflowExecute } = require('n8n-core');
    const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

    console.log("🔧 Setting up n8n instrumentation for Langfuse...");

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
      if (model.includes('groq')) return 'groq';
      if (model.includes('vertex')) return 'vertex';
      if (model.includes('huggingface')) return 'huggingface';
      
      return 'other';
    }

    // Helper function to extract LLM data from node execution
    function extractLLMData(nodeData, runData) {
      const llmData = { model: null, input: null, output: null, system: 'unknown', tokens: null };

      try {
        const nodeType = nodeData?.type || '';
        const nodeName = nodeData?.name || '';
        const parameters = nodeData?.parameters || {};

        // Detect AI nodes by type or name
        const aiIndicators = ['openai', 'anthropic', 'langchain', 'claude', 'gpt', 'azure', 'vertex', 'groq', 'llm', 'ai'];
        const isAINode = aiIndicators.some(indicator => 
          nodeType.toLowerCase().includes(indicator) || 
          nodeName.toLowerCase().includes(indicator)
        );

        if (isAINode) {
          // Extract model information
          llmData.model = parameters?.model || parameters?.options?.model || parameters?.modelName || 'unknown';
          llmData.system = detectAISystem(llmData.model);

          // Extract input (prompts, messages)
          if (parameters?.prompt) {
            llmData.input = parameters.prompt;
          } else if (parameters?.message) {
            llmData.input = parameters.message;
          } else if (parameters?.messages) {
            llmData.input = JSON.stringify(parameters.messages);
          } else if (parameters?.options?.messages) {
            llmData.input = JSON.stringify(parameters.options.messages);
          } else if (parameters?.text) {
            llmData.input = parameters.text;
          }

          // Extract output from run data
          if (runData && runData.length > 0) {
            const lastRun = runData[runData.length - 1];
            if (lastRun?.data?.main && lastRun.data.main.length > 0) {
              const outputData = lastRun.data.main[0];
              if (outputData && outputData.length > 0) {
                const output = outputData[0]?.json || outputData[0];
                llmData.output = JSON.stringify(output);

                // Try to extract token usage from output
                try {
                  if (output.usage) {
                    llmData.tokens = {
                      input: output.usage.prompt_tokens || output.usage.input_tokens || 0,
                      output: output.usage.completion_tokens || output.usage.output_tokens || 0
                    };
                  }
                } catch (e) {
                  // Ignore token extraction errors
                }
              }
            }
          }
        }
      } catch (error) {
        console.error("Error extracting LLM data:", error);
      }

      return llmData;
    }

    // Helper function to set GenAI attributes on span
    function setGenAIAttributes(span, llmData, nodeData) {
      try {
        // Basic GenAI attributes
        if (llmData.system && llmData.system !== 'unknown') {
          span.setAttributes({
            'gen_ai.system': llmData.system,
            'gen_ai.request.model': llmData.model || 'unknown'
          });

          // Server attributes based on system
          switch (llmData.system) {
            case 'openai':
              span.setAttributes({
                'server.address': 'api.openai.com',
                'server.port': 443
              });
              break;
            case 'azure_openai':
              span.setAttributes({
                'server.address': 'cognitiveservices.azure.com',
                'server.port': 443
              });
              break;
            case 'anthropic':
              span.setAttributes({
                'server.address': 'api.anthropic.com',
                'server.port': 443
              });
              break;
            case 'vertex':
              span.setAttributes({
                'server.address': 'googleapis.com',
                'server.port': 443
              });
              break;
            case 'groq':
              span.setAttributes({
                'server.address': 'api.groq.com',
                'server.port': 443
              });
              break;
          }
        }

        // Input/Output
        if (llmData.input) {
          span.setAttributes({
            'gen_ai.prompt': llmData.input.substring(0, 1000) // Limit size
          });
        }

        if (llmData.output) {
          span.setAttributes({
            'gen_ai.completion': llmData.output.substring(0, 1000) // Limit size
          });
        }

        // Token usage
        if (llmData.tokens) {
          span.setAttributes({
            'gen_ai.usage.input_tokens': llmData.tokens.input,
            'gen_ai.usage.output_tokens': llmData.tokens.output
          });
        }

        // Model parameters from node configuration
        if (nodeData?.parameters) {
          const params = nodeData.parameters;
          if (params.temperature !== undefined) {
            span.setAttributes({ 'gen_ai.request.temperature': params.temperature });
          }
          if (params.max_tokens !== undefined || params.maxTokens !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.max_tokens': params.max_tokens || params.maxTokens 
            });
          }
          if (params.top_p !== undefined || params.topP !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.top_p': params.top_p || params.topP 
            });
          }
          if (params.stream !== undefined) {
            span.setAttributes({ 'gen_ai.request.is_stream': params.stream });
          }
        }

      } catch (error) {
        console.error("Error setting GenAI attributes:", error);
      }
    }

    // Workflow-level instrumentation
    const originalProcessRun = WorkflowExecute.prototype.processRunExecutionData;
    WorkflowExecute.prototype.processRunExecutionData = function (workflow) {
      const wfData = workflow || {};
      const workflowId = wfData?.id ?? "unknown";
      const workflowName = wfData?.name ?? "unknown";

      // Reduced logging - only log workflow starts in debug mode
      if (process.env.OTEL_LOG_LEVEL === 'debug') {
        console.log("📊 Starting workflow: " + workflowName + " (" + workflowId + ")");
      }

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
            // Reduced logging - only log completions in debug mode
            if (process.env.OTEL_LOG_LEVEL === 'debug') {
              console.log("✅ Workflow completed successfully");
            }
            
            const runData = result?.data?.resultData?.runData || {};
            const nodes = Array.isArray(wfData?.nodes) ? wfData.nodes : [];
            let llmNodeCount = 0;
            
            // Process nodes and create child spans
            if (nodes.length > 0) {
              nodes.forEach((nodeData, index) => {
              const nodeName = nodeData.name;
              const nodeRunData = runData[nodeName];
              
              if (nodeRunData) {
                const llmData = extractLLMData(nodeData, nodeRunData);
                
                if (llmData.system !== 'unknown') {
                  llmNodeCount++;
                  
                  // Create LLM span
                  const llmSpan = tracer.startSpan('n8n.llm.generation', {
                    attributes: {
                      'n8n.node.name': nodeName,
                      'n8n.node.type': nodeData.type,
                      'n8n.node.index': index
                    },
                    kind: SpanKind.CLIENT
                  }, activeContext);
                  
                  // Set GenAI attributes
                  setGenAIAttributes(llmSpan, llmData, nodeData);
                  
                  llmSpan.setStatus({ code: SpanStatusCode.OK });
                  llmSpan.end();
                } else {
                  // Create regular node span
                  const nodeSpan = tracer.startSpan('n8n.node.execute', {
                    attributes: {
                      'n8n.node.name': nodeName,
                      'n8n.node.type': nodeData.type,
                      'n8n.node.index': index
                    },
                    kind: SpanKind.INTERNAL
                  }, activeContext);
                  
                  nodeSpan.setStatus({ code: SpanStatusCode.OK });
                  nodeSpan.end();
                }
              }
            });
            }

            span.setAttributes({
              'langfuse.status': 'success',
              'n8n.workflow.nodes_executed': result?.data?.resultData?.runData ? Object.keys(result.data.resultData.runData).length : 0,
              'n8n.workflow.llm_nodes': llmNodeCount
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
                'error.message': String(err.message || err)
              });
            }

            span.end();
          },
          (error) => {
            console.error("❌ Workflow failed:", error);
            span.recordException(error);
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: String(error.message || error),
            });
            span.setAttributes({
              'langfuse.status': 'error',
              'error.message': String(error.message || error)
            });
            span.end();
          }
        );

        return cancelable;
      });
    };

    console.log("✅ n8n instrumentation setup completed!");
  } catch (error) {
    console.error("❌ Failed to setup n8n instrumentation:", error);
  }
}

module.exports = { setupN8nInstrumentation };