const { trace, context, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const flat = require('flat');

function setupN8nInstrumentation() {
  try {
    const { WorkflowExecute } = require('n8n-core');
    const tracer = trace.getTracer('n8n-langfuse-instrumentation', '1.0.0');

    console.log("🔧 Setting up n8n instrumentation for Langfuse...");

    // Helper function to detect AI system from model name, node type, and name
    function detectAISystem(modelName, nodeType, nodeName) {
      const model = (modelName || '').toLowerCase();
      const type = (nodeType || '').toLowerCase();
      const name = (nodeName || '').toLowerCase();
      
      // Check in model name first
      if (model.includes('gpt') || model.includes('openai')) return 'openai';
      if (model.includes('claude') || model.includes('anthropic')) return 'anthropic';
      if (model.includes('gemini') || model.includes('google')) return 'vertex';
      if (model.includes('llama') || model.includes('meta')) return 'meta';
      if (model.includes('azure')) return 'azure_openai';
      if (model.includes('cohere')) return 'cohere';
      if (model.includes('mistral')) return 'mistral';
      if (model.includes('groq')) return 'groq';
      
      // Check in node type and name - enhanced for LangChain types
      if (type.includes('lmchatanthropic') || type.includes('anthropic') || name.includes('anthropic') || name.includes('claude')) return 'anthropic';
      if (type.includes('lmchatazureopenai') || type.includes('azure') || name.includes('azure openai')) return 'azure_openai';
      if (type.includes('lmchatopenai') || type.includes('openai') || name.includes('openai') || name.includes('gpt')) return 'openai';
      if (type.includes('lmchatgooglevertex') || type.includes('vertex') || type.includes('google') || name.includes('vertex') || name.includes('google')) return 'vertex';
      if (type.includes('groq') || name.includes('groq')) return 'groq';
      if (type.includes('langchain') || name.includes('corrector') || name.includes('transcripciones')) return 'openai'; // Default for chains
      
      return 'unknown';
    }

    // Function to extract LLM data from node data and run data
    function extractLLMData(nodeData, runData) {
      const llmData = { 
        system: 'unknown', 
        model: null, 
        input: null, 
        output: null, 
        tokens: null, 
        cost: null, 
        toolCalls: null, 
        functionCall: null 
      };
      
      try {
        const nodeType = nodeData?.type || '';
        const nodeName = nodeData?.name || '';
        const parameters = nodeData?.parameters || {};

        // Detect AI nodes by type or name - enhanced for ALL LangChain nodes
        const aiTypeIndicators = [
          'langchain.lm', 'langchain.chat', 'langchain.chain', // ← AGREGADO chainLlm
          'lmChat', 'chatModel', 'chainLlm',
          'openai', 'anthropic', 'claude', 'gpt', 'azure', 'vertex', 'groq', 
          'llm', 'ai', 'chat', 'completion'
        ];
        const aiNameIndicators = [
          'chat model', 'corrector', 'transcripciones', // ← AGREGADO para tu caso
          'openai', 'anthropic', 'claude', 'azure', 'vertex', 
          'groq', 'llm', 'ai', 'gpt'
        ];
        
        const isAINode = aiTypeIndicators.some(indicator => 
          nodeType.toLowerCase().includes(indicator)
        ) || aiNameIndicators.some(indicator => 
          nodeName.toLowerCase().includes(indicator)
        );

        // Debug: Log node detection - COMPLETO sin truncar
        console.log(`=== NODE DETECTION DEBUG ===`);
        console.log(`Node: ${nodeName}`);
        console.log(`Type: ${nodeType}`);
        console.log(`Is AI: ${isAINode}`);

        if (isAINode) {
          // Extract model information (múltiples ubicaciones)
          llmData.model = parameters?.model || 
                         parameters?.options?.model || 
                         parameters?.modelName ||
                         parameters?.deployment || // Azure OpenAI usa deployment
                         'unknown';
          llmData.system = detectAISystem(llmData.model, nodeType, nodeName);

          // Extract input from parameters
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

          // Extract input and output from run data - CORRECTED for n8n structure
          if (runData && runData.length > 0) {
            const lastRun = runData[runData.length - 1];
            
            // n8n LangChain nodes use ai_languageModel output
            if (lastRun?.data?.ai_languageModel && lastRun.data.ai_languageModel.length > 0) {
              const aiData = lastRun.data.ai_languageModel[0];
              if (aiData && aiData.length > 0) {
                const output = aiData[0]?.json;
                if (output) {
                  // Extract output text (múltiples formatos)
                  if (output.response?.generations?.[0]?.[0]?.text) {
                    llmData.output = output.response.generations[0][0].text;
                  } else if (output.response?.content) {
                    llmData.output = output.response.content;
                  } else if (output.content) {
                    llmData.output = output.content;
                  } else if (output.text) {
                    llmData.output = output.text;
                  } else if (output.message?.content) {
                    llmData.output = output.message.content;
                  }
                  
                  // Extract input (buscar en múltiples ubicaciones)
                  if (output.response?.prompt || output.prompt) {
                    llmData.input = output.response?.prompt || output.prompt;
                  } else if (output.response?.messages) {
                    llmData.input = JSON.stringify(output.response.messages);
                  } else if (output.messages) {
                    llmData.input = JSON.stringify(output.messages);
                  }
                  
                  // Extract modelo (múltiples ubicaciones)
                  if (output.response?.model) {
                    llmData.model = output.response.model;
                  } else if (output.response?.response_metadata?.model) {
                    llmData.model = output.response.response_metadata.model;
                  } else if (output.model) {
                    llmData.model = output.model;
                  } else if (output.response_metadata?.model) {
                    llmData.model = output.response_metadata.model;
                  }

                  // Extract token usage (estructura REAL de Azure OpenAI)
                  try {
                    let usage = null;
                    
                    // Azure OpenAI format (estructura real encontrada)
                    if (output.tokenUsage) {
                      usage = output.tokenUsage;
                      llmData.tokens = {
                        input: usage.promptTokens || usage.input_tokens || 0,
                        output: usage.completionTokens || usage.output_tokens || 0
                      };
                    }
                    // LangChain Anthropic format
                    else if (output.response?.response_metadata?.tokenUsage) {
                      usage = output.response.response_metadata.tokenUsage;
                      llmData.tokens = {
                        input: usage.promptTokens || usage.input_tokens || 0,
                        output: usage.completionTokens || usage.output_tokens || 0
                      };
                    }
                    // Standard OpenAI format
                    else if (output.response?.usage) {
                      usage = output.response.usage;
                      llmData.tokens = {
                        input: usage.prompt_tokens || usage.input_tokens || 0,
                        output: usage.completion_tokens || usage.output_tokens || 0
                      };
                    }
                    // Direct usage object
                    else if (output.usage) {
                      usage = output.usage;
                      llmData.tokens = {
                        input: usage.prompt_tokens || usage.input_tokens || 0,
                        output: usage.completion_tokens || usage.output_tokens || 0
                      };
                    }
                    // Response metadata format
                    else if (output.response_metadata?.tokenUsage) {
                      usage = output.response_metadata.tokenUsage;
                      llmData.tokens = {
                        input: usage.promptTokens || usage.input_tokens || 0,
                        output: usage.completionTokens || usage.output_tokens || 0
                      };
                    }
                    
                    // Extract cost information if available
                    if (usage?.cost || output.cost || output.response?.cost) {
                      llmData.cost = usage?.cost || output.cost || output.response.cost;
                    }
                    
                  } catch (e) {
                    console.log(`Error extracting tokens for ${nodeName}:`, e.message);
                  }
                  
                  // Extract tool usage if available
                  try {
                    if (output.response?.tool_calls || output.tool_calls) {
                      llmData.toolCalls = output.response?.tool_calls || output.tool_calls;
                    }
                    if (output.response?.function_call || output.function_call) {
                      llmData.functionCall = output.response?.function_call || output.function_call;
                    }
                  } catch (e) {
                    // Ignore tool extraction errors
                  }
                  
                  // DEBUG: Log COMPLETE structure without truncation
                  console.log(`=== COMPLETE AI_LANGUAGEMODEL DATA ===`);
                  console.log(`Node: ${nodeName}`);
                  console.log(`Full output structure:`, JSON.stringify(output, null, 2));
                  console.log(`=== END COMPLETE DATA ===`);
                }
              }
            }
            
            // Also try standard main output for non-LangChain nodes
            else if (lastRun?.data?.main && lastRun.data.main.length > 0) {
              const outputData = lastRun.data.main[0];
              if (outputData && outputData.length > 0) {
                const output = outputData[0]?.json || outputData[0];
                llmData.output = JSON.stringify(output);
                
                // Standard token extraction
                if (output.usage) {
                  llmData.tokens = {
                    input: output.usage.prompt_tokens || output.usage.input_tokens || 0,
                    output: output.usage.completion_tokens || output.usage.output_tokens || 0
                  };
                }
                
                if (output.model || output.response_metadata?.model) {
                  llmData.model = output.model || output.response_metadata.model;
                }
              }
            }
          }

          // DEBUG: Log COMPLETE extraction results
          console.log(`=== EXTRACTION RESULTS ===`);
          console.log(`Node: ${nodeName}`);
          console.log(`System: ${llmData.system}`);
          console.log(`Model: ${llmData.model}`);
          console.log(`Has Input: ${!!llmData.input}`);
          console.log(`Has Output: ${!!llmData.output}`);
          console.log(`Input (first 500 chars): ${llmData.input ? llmData.input.substring(0, 500) : 'null'}`);
          console.log(`Output (first 500 chars): ${llmData.output ? llmData.output.substring(0, 500) : 'null'}`);
          console.log(`Tokens: ${JSON.stringify(llmData.tokens)}`);
          console.log(`Cost: ${llmData.cost}`);
          console.log(`=== END EXTRACTION RESULTS ===`);
        }

        return llmData;
      } catch (error) {
        console.error(`Error extracting LLM data for ${nodeData?.name}:`, error);
        return llmData;
      }
    }

    // Helper function to set GenAI span attributes with ALL data
    function setGenAIAttributes(span, llmData, nodeData) {
      try {
        // Core GenAI attributes
        span.setAttributes({
          'gen_ai.system': llmData.system,
          'gen_ai.operation.name': 'chat'
        });

        // Model information
        if (llmData.model && llmData.model !== 'unknown') {
          span.setAttributes({
            'gen_ai.request.model': llmData.model,
            'gen_ai.response.model': llmData.model
          });
        }

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
              'server.address': 'aiplatform.googleapis.com',
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

        // Input/Output with Langfuse specific attributes - NO TRUNCAR
        if (llmData.input) {
          span.setAttributes({
            'gen_ai.prompt': llmData.input, // NO truncar para debug
            'langfuse.generation.input': llmData.input // Langfuse specific completo
          });
        }

        if (llmData.output) {
          span.setAttributes({
            'gen_ai.completion': llmData.output, // NO truncar para debug
            'langfuse.generation.output': llmData.output // Langfuse specific completo
          });
        }

        // Token usage with Langfuse attributes
        if (llmData.tokens && (llmData.tokens.input > 0 || llmData.tokens.output > 0)) {
          const inputTokens = llmData.tokens.input || 0;
          const outputTokens = llmData.tokens.output || 0;
          const totalTokens = inputTokens + outputTokens;
          
          span.setAttributes({
            'gen_ai.usage.input_tokens': inputTokens,
            'gen_ai.usage.output_tokens': outputTokens,
            'gen_ai.usage.total_tokens': totalTokens,
            // Langfuse specific token attributes
            'langfuse.generation.usage.input': inputTokens,
            'langfuse.generation.usage.output': outputTokens,
            'langfuse.generation.usage.total': totalTokens
          });
        }
        
        // Cost information
        if (llmData.cost) {
          span.setAttributes({
            'gen_ai.usage.cost': llmData.cost,
            'langfuse.generation.cost': llmData.cost
          });
        }
        
        // Tool usage information
        if (llmData.toolCalls && llmData.toolCalls.length > 0) {
          span.setAttributes({
            'gen_ai.tool.calls': JSON.stringify(llmData.toolCalls), // NO truncar
            'langfuse.generation.tools.used': llmData.toolCalls.length
          });
        }
        
        if (llmData.functionCall) {
          span.setAttributes({
            'gen_ai.function.call': JSON.stringify(llmData.functionCall) // NO truncar
          });
        }

        // Model parameters from node configuration (extendido)
        if (nodeData?.parameters) {
          const params = nodeData.parameters;
          const options = params.options || {};
          
          // Temperature
          if (params.temperature !== undefined || options.temperature !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.temperature': params.temperature || options.temperature 
            });
          }
          
          // Max tokens (múltiples nombres)
          const maxTokens = params.max_tokens || params.maxTokens || options.maxTokens || 
                           options.max_tokens || options.maxTokensToSample || options.maxOutputTokens;
          if (maxTokens !== undefined && maxTokens > 0) {
            span.setAttributes({ 'gen_ai.request.max_tokens': maxTokens });
          }
          
          // Top P
          if (params.top_p !== undefined || params.topP !== undefined || options.top_p !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.top_p': params.top_p || params.topP || options.top_p 
            });
          }
          
          // Streaming
          if (params.stream !== undefined || options.stream !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.is_stream': params.stream || options.stream 
            });
          }
          
          // Frequency penalty
          if (params.frequency_penalty !== undefined || options.frequency_penalty !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.frequency_penalty': params.frequency_penalty || options.frequency_penalty 
            });
          }
          
          // Presence penalty
          if (params.presence_penalty !== undefined || options.presence_penalty !== undefined) {
            span.setAttributes({ 
              'gen_ai.request.presence_penalty': params.presence_penalty || options.presence_penalty 
            });
          }
          
          // Model specific parameters
          const modelParams = {
            temperature: params.temperature || options.temperature,
            max_tokens: maxTokens,
            top_p: params.top_p || params.topP || options.top_p,
            stream: params.stream || options.stream,
            frequency_penalty: params.frequency_penalty || options.frequency_penalty,
            presence_penalty: params.presence_penalty || options.presence_penalty
          };
          
          // Remove undefined values
          Object.keys(modelParams).forEach(key => {
            if (modelParams[key] === undefined) delete modelParams[key];
          });
          
          if (Object.keys(modelParams).length > 0) {
            span.setAttributes({
              'langfuse.generation.modelParameters': JSON.stringify(modelParams)
            });
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
      const workflowName = wfData?.name ?? "unknown";
      const workflowId = wfData?.id ?? "unknown";

      console.log(`📊 Starting workflow: ${workflowName} (${workflowId})`);

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
            const nodes = Array.isArray(wfData?.nodes) ? wfData.nodes : [];
            let llmNodeCount = 0;
            
            // DEBUG: Log COMPLETE workflow structure
            console.log(`=== COMPLETE WORKFLOW DEBUG ===`);
            console.log(`Workflow: ${workflowName}`);
            console.log(`Nodes from wfData.nodes: ${nodes.length}`);
            console.log(`RunData executed nodes: ${Object.keys(runData).length}`);
            console.log(`RunData keys: [${Object.keys(runData).map(k => `'${k}'`).join(', ')}]`);
            
            // Process executed nodes from runData (not wfData.nodes)
            Object.keys(runData).forEach((nodeName, index) => {
              // Try to find node definition in wfData.nodes, fallback to name-based
              let nodeData = nodes.find(n => n.name === nodeName) || { 
                name: nodeName, 
                type: 'unknown', 
                parameters: {} 
              };
              
              const nodeRunData = runData[nodeName];
              
              console.log(`=== NODE ${index} DEBUG ===`);
              console.log(`Name: ${nodeName}`);
              console.log(`Type: ${nodeData.type}`);
              console.log(`Has RunData: ${!!nodeRunData}`);
              
              if (nodeRunData) {
                console.log(`RunData length: ${nodeRunData.length}`);
                if (nodeRunData.length > 0) {
                  const firstRun = nodeRunData[0];
                  console.log(`First run keys: [${Object.keys(firstRun).join(', ')}]`);
                  if (firstRun.data) {
                    console.log(`First run data keys: [${Object.keys(firstRun.data).join(', ')}]`);
                    
                    // Log complete structure for AI nodes
                    if (firstRun.data.ai_languageModel) {
                      console.log(`=== AI_LANGUAGEMODEL COMPLETE STRUCTURE ===`);
                      console.log(JSON.stringify(firstRun.data.ai_languageModel, null, 2));
                      console.log(`=== END AI_LANGUAGEMODEL STRUCTURE ===`);
                    }
                  }
                }
                
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
