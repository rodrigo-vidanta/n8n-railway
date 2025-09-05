const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');

function setupN8nInstrumentation() {
  try {
    const { WorkflowExecute } = require('n8n-core');
    const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

    console.log("🔧 Setting up n8n instrumentation for Langfuse...");

    // Helper function to detect AI system from model name or node type
    function detectAISystem(modelName, nodeType) {
      const model = (modelName || '').toLowerCase();
      const type = (nodeType || '').toLowerCase();
      
      if (model.includes('gpt') || model.includes('openai') || type.includes('openai')) return 'openai';
      if (model.includes('azure') || type.includes('azure')) return 'azure_openai';
      if (model.includes('claude') || model.includes('anthropic') || type.includes('anthropic')) return 'anthropic';
      if (model.includes('gemini') || model.includes('vertex') || type.includes('vertex') || type.includes('google')) return 'vertex';
      if (model.includes('groq') || type.includes('groq')) return 'groq';
      if (model.includes('llama') || model.includes('mistral') || model.includes('opensource')) return 'opensource';
      
      return 'unknown';
    }

    // Helper function to extract LLM data from node execution
    function extractLLMData(nodeData, runData) {
      const llmData = { model: null, input: null, output: null, system: null, tokens: null };

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
          llmData.model = parameters?.model || parameters?.options?.model || parameters?.modelName;
          llmData.system = detectAISystem(llmData.model, nodeType);

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
        console.warn("⚠️ Error extracting LLM data:", error.message);
      }

      return llmData;
    }

    // Helper function to set GenAI span attributes
    function setGenAIAttributes(span, llmData, nodeData) {
      if (llmData.system !== 'unknown') {
        span.setAttributes({
          'gen_ai.system': llmData.system,
          'gen_ai.operation.name': 'chat',
          'langfuse.observation.type': 'generation'
        });

        if (llmData.model) {
          span.setAttributes({
            'gen_ai.request.model': llmData.model,
            'gen_ai.response.model': llmData.model
          });
        }

        // Server attributes based on system
        if (llmData.system === 'openai') {
          span.setAttributes({
            'server.address': 'api.openai.com',
            'server.port': 443
          });
        } else if (llmData.system === 'azure_openai') {
          span.setAttributes({
            'server.port': 443
          });
        } else if (llmData.system === 'anthropic') {
          span.setAttributes({
            'server.address': 'api.anthropic.com',
            'server.port': 443
          });
        } else if (llmData.system === 'vertex') {
          span.setAttributes({
            'server.address': 'generativelanguage.googleapis.com',
            'server.port': 443
          });
        } else if (llmData.system === 'groq') {
          span.setAttributes({
            'server.address': 'api.groq.com',
            'server.port': 443
          });
        }

        if (llmData.input) {
          span.setAttributes({
            'input.value': llmData.input,
            'gen_ai.prompt.0.role': 'user',
            'gen_ai.prompt.0.content': llmData.input
          });
        }

        if (llmData.output) {
          span.setAttributes({
            'output.value': llmData.output,
            'gen_ai.completion.0.role': 'assistant',
            'gen_ai.completion.0.content': llmData.output
          });
        }

        // Updated token usage attributes (2024-2025 standard)
        if (llmData.tokens && (llmData.tokens.input > 0 || llmData.tokens.output > 0)) {
          span.setAttributes({
            'gen_ai.usage.input_tokens': llmData.tokens.input || 0,
            'gen_ai.usage.output_tokens': llmData.tokens.output || 0,
            'gen_ai.usage.total_tokens': (llmData.tokens.input || 0) + (llmData.tokens.output || 0)
          });
        }

        // Model parameters if available
        const parameters = nodeData?.parameters || {};
        if (parameters.temperature !== undefined) {
          span.setAttributes({
            'gen_ai.request.temperature': parameters.temperature
          });
        }
        if (parameters.max_tokens !== undefined || parameters.maxTokens !== undefined) {
          span.setAttributes({
            'gen_ai.request.max_tokens': parameters.max_tokens || parameters.maxTokens
          });
        }
        if (parameters.top_p !== undefined) {
          span.setAttributes({
            'gen_ai.request.top_p': parameters.top_p
          });
        }

        // Cost information if available
        if (llmData.cost) {
          span.setAttributes({
            'gen_ai.usage.cost': llmData.cost
          });
        }

        // Streaming detection
        if (parameters.stream) {
          span.setAttributes({
            'gen_ai.request.is_stream': parameters.stream
          });
        }
      }
    }

    // Workflow-level instrumentation
    const originalProcessRun = WorkflowExecute.prototype.processRunExecutionData;
    WorkflowExecute.prototype.processRunExecutionData = function (workflow) {
      const wfData = workflow || {};
      const workflowName = wfData?.name ?? "unknown";
      const workflowId = wfData?.id ?? "unknown";

      console.log("📊 Starting workflow:", workflowName);

      const span = tracer.startSpan('n8n.workflow.execute', {
        attributes: {
          'langfuse.trace.name': workflowName,
          'n8n.workflow.name': workflowName,
          'n8n.workflow.id': workflowId,
          'n8n.service': 'workflow-engine'
        },
        kind: SpanKind.INTERNAL
      });

      const activeContext = trace.setSpan(context.active(), span);
      return context.with(activeContext, () => {
        const cancelable = originalProcessRun.apply(this, arguments);

        cancelable.then(
          (result) => {
            console.log("✅ Workflow completed successfully");
            
            const runData = result?.data?.resultData?.runData || {};
            const nodes = wfData?.nodes || [];
            let llmNodeCount = 0;
            
            // Create child spans for each node execution
            nodes.forEach((nodeData, index) => {
              const nodeName = nodeData.name;
              const nodeRunData = runData[nodeName];
              
              if (nodeRunData) {
                const llmData = extractLLMData(nodeData, nodeRunData);
                
                if (llmData.system !== 'unknown') {
                  llmNodeCount++;
                  
                  // Create a child span for the LLM operation
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
                  
                  console.log(`🤖 Processed LLM node: ${nodeName} (${llmData.system})`);
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

            span.setAttributes({
              'langfuse.status': 'success',
              'n8n.workflow.nodes_executed': Object.keys(runData).length,
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
