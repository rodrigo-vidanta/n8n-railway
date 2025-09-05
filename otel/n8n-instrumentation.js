const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');

function setupN8nInstrumentation() {
  try {
    const { WorkflowExecute } = require('n8n-core');
    const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

    console.log("🔧 Setting up n8n instrumentation for Langfuse...");

    // Helper function to detect AI system from model name
    function detectAISystem(modelName, nodeType, nodeName) {
      const model = (modelName || '').toLowerCase();
      const type = (nodeType || '').toLowerCase();
      const name = (nodeName || '').toLowerCase();
      
      // Check in model name first
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
      
      // Check in node type and name - enhanced for LangChain types
      if (type.includes('lmchatanthropic') || type.includes('anthropic') || name.includes('anthropic') || name.includes('claude')) return 'anthropic';
      if (type.includes('lmchatazureopenai') || type.includes('azure') || name.includes('azure openai')) return 'azure_openai';
      if (type.includes('lmchatopenai') || type.includes('openai') || name.includes('openai') || name.includes('gpt')) return 'openai';
      if (type.includes('lmchatgooglevertex') || type.includes('vertex') || type.includes('google') || name.includes('vertex') || name.includes('google')) return 'vertex';
      if (type.includes('groq') || name.includes('groq')) return 'groq';
      
      // If we detected it as AI but can't determine system, return 'other'
      return (!modelName || modelName === 'unknown') ? 'unknown' : 'other';
    }

    // Helper function to extract LLM data from node execution
    function extractLLMData(nodeData, runData) {
      const llmData = { model: null, input: null, output: null, system: 'unknown', tokens: null };

      try {
        const nodeType = nodeData?.type || '';
        const nodeName = nodeData?.name || '';
        const parameters = nodeData?.parameters || {};

        // Detect AI nodes by type or name - enhanced for LangChain nodes
        const aiTypeIndicators = [
          'langchain.lm', 'langchain.chat', 'lmChat', 'chatModel',
          'openai', 'anthropic', 'claude', 'gpt', 'azure', 'vertex', 'groq', 
          'llm', 'ai', 'chat', 'completion'
        ];
        const aiNameIndicators = [
          'chat model', 'openai', 'anthropic', 'claude', 'azure', 'vertex', 
          'groq', 'llm', 'ai', 'gpt'
        ];
        
        const isAINode = aiTypeIndicators.some(indicator => 
          nodeType.toLowerCase().includes(indicator)
        ) || aiNameIndicators.some(indicator => 
          nodeName.toLowerCase().includes(indicator)
        );

        // Debug: Log node detection
        if (process.env.OTEL_LOG_LEVEL === 'debug') {
          console.log(`Checking node: ${nodeName} (${nodeType}) - isAI: ${isAINode}`);
        }

        if (isAINode) {
          // Extract model information
          llmData.model = parameters?.model || parameters?.options?.model || parameters?.modelName || 'unknown';
          llmData.system = detectAISystem(llmData.model, nodeType, nodeName);

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

          // Extract input and output from run data
          if (runData && runData.length > 0) {
            // Extract input from first run
            const firstRun = runData[0];
            if (firstRun?.data?.main && firstRun.data.main.length > 0) {
              const inputData = firstRun.data.main[0];
              if (inputData && inputData.length > 0) {
                const input = inputData[0]?.json || inputData[0];
                // Look for common input fields
                if (input) {
                  llmData.input = input.chatInput || input.prompt || input.message || input.text || JSON.stringify(input).substring(0, 1000);
                }
              }
            }

            // Extract output from last run
            const lastRun = runData[runData.length - 1];
            if (lastRun?.data?.main && lastRun.data.main.length > 0) {
              const outputData = lastRun.data.main[0];
              if (outputData && outputData.length > 0) {
                const output = outputData[0]?.json || outputData[0];
                if (output) {
                  // Look for common output fields
                  llmData.output = output.response || output.content || output.text || JSON.stringify(output).substring(0, 1000);
                  
                  // Extract model from output metadata
                  if (output.model) {
                    llmData.model = output.model;
                  } else if (output.response_metadata?.model) {
                    llmData.model = output.response_metadata.model;
                  }

                  // Try to extract token usage from output
                  try {
                    if (output.usage) {
                      llmData.tokens = {
                        input: output.usage.prompt_tokens || output.usage.input_tokens || 0,
                        output: output.usage.completion_tokens || output.usage.output_tokens || 0
                      };
                    } else if (output.response_metadata?.tokenUsage) {
                      llmData.tokens = {
                        input: output.response_metadata.tokenUsage.promptTokens || 0,
                        output: output.response_metadata.tokenUsage.completionTokens || 0
                      };
                    }
                  } catch (e) {
                    // Ignore token extraction errors
                  }
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
            
            // Process nodes and create child spans - use runData as primary source
            if (process.env.OTEL_LOG_LEVEL === 'debug') {
              console.log(`Processing ${nodes.length} nodes from wfData.nodes`);
              console.log(`RunData has ${Object.keys(runData).length} executed nodes:`, Object.keys(runData));
            }
            
            // Process from runData (executed nodes) instead of wfData.nodes
            Object.keys(runData).forEach((nodeName, index) => {
              const nodeRunData = runData[nodeName];
              
              // Try to find node definition in wfData.nodes, fallback to name-based detection
              let nodeData = nodes.find(n => n.name === nodeName) || { 
                name: nodeName, 
                type: 'unknown', 
                parameters: {} 
              };
              
              if (process.env.OTEL_LOG_LEVEL === 'debug') {
                console.log(`Node ${index}: ${nodeName} (${nodeData.type}) - hasRunData: ${!!nodeRunData}`);
              }
              
              if (nodeRunData) {
                const llmData = extractLLMData(nodeData, nodeRunData);
                
                if (process.env.OTEL_LOG_LEVEL === 'debug') {
                  console.log(`LLM Data for ${nodeName}:`, { 
                    system: llmData.system, 
                    model: llmData.model,
                    hasInput: !!llmData.input,
                    hasOutput: !!llmData.output 
                  });
                  
                  // Debug: Log runData structure for LLM nodes
                  if (llmData.system !== 'unknown') {
                    console.log(`RunData structure for ${nodeName}:`, JSON.stringify({
                      runDataLength: nodeRunData.length,
                      firstRun: nodeRunData[0]?.data?.main ? 'has main data' : 'no main data',
                      lastRun: nodeRunData[nodeRunData.length - 1]?.data?.main ? 'has main data' : 'no main data',
                      firstRunKeys: nodeRunData[0] ? Object.keys(nodeRunData[0]) : 'no first run',
                      firstRunDataKeys: nodeRunData[0]?.data ? Object.keys(nodeRunData[0].data) : 'no data',
                      sampleFirstRun: nodeRunData[0] ? JSON.stringify(nodeRunData[0]).substring(0, 500) : 'none'
                    }));
                  }
                }
                
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