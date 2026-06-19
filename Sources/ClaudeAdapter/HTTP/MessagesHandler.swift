import Foundation
import AgentBridgeCore
import FoundationModels
import Hummingbird
import HTTPTypes
import NIOCore

func handleMessages(
    request: Request,
    context: BasicRequestContext,
    afm: AFMRuntime,
    diagnostics: Diagnostics,
    contextLedger: any ContextLedger
) async throws -> Response {
    let anthropicReq: MessagesRequest
    do {
        anthropicReq = try await request.decode(as: MessagesRequest.self, context: context)
    } catch {
        return anthropicErrorResponse(.badRequest("Failed to decode /v1/messages request body: \(error)"))
    }

    guard ModelRegistry.isSupported(anthropicReq.model) else {
        return anthropicErrorResponse(.unsupportedModel("Unsupported model: \(anthropicReq.model). Use 'claude-afm-local' or a configured alias."))
    }

    let normalized = MessageNormalizer.normalize(anthropicReq, diagnostics: diagnostics)
    let rawInstructions = TranscriptBuilder.instructions(from: normalized)
    let rawConversation = TranscriptBuilder.conversation(from: normalized)

    guard !PromptTruncator.isTooLarge(instructions: rawInstructions, conversation: rawConversation) else {
        return anthropicErrorResponse(.contextTooLarge("Input exceeds claude-afm-bridge hard context limit before generation."))
    }

    guard case .available = afm.availability else {
        return anthropicErrorResponse(.afmUnavailable("Apple Foundation Models are not available on this device."))
    }

    let prepared: PreparedClaudeContext
    do {
        prepared = try await ClaudeContextPlanner.prepare(
            normalized,
            contextSize: afm.model.contextSize,
            ledger: contextLedger
        )
    } catch {
        return anthropicErrorResponse(.generationFailed("Context planning failed: \(error)"))
    }
    let instructions = prepared.instructions
    let conversation = prepared.prompt
    if prepared.plan.truncated {
        diagnostics.note("context plan omitted \(prepared.plan.omittedSegmentIDs.count) segment(s) to fit \(prepared.plan.budget) input tokens")
    }
    let options = GenerationOptionsMapper.map(maxTokens: normalized.maxTokens, temperature: normalized.temperature)
    let useStructured = normalized.hasTools

    if normalized.stream {
        return Response(status: .ok, headers: sseHeaders(), body: .init { writer in
            let allocator = ByteBufferAllocator()
            let messageID = MessageID.make()

            try await writer.write(SSEWriter.event("message_start", payload: MessageStartEvent(id: messageID, model: normalized.model, inputTokens: 0), allocator: allocator))

            if useStructured {
                try await streamStructured(afm: afm, model: normalized.model, tools: normalized.tools ?? [], instructions: instructions, conversation: conversation, options: options, writer: &writer, allocator: allocator)
            } else {
                try await streamText(afm: afm, model: normalized.model, instructions: instructions, conversation: conversation, options: options, writer: &writer, allocator: allocator)
            }

            try await writer.finish(nil)
        })
    }

    if useStructured {
        do {
            let result = try await afm.generateStructured(
                instructions: instructions,
                conversation: conversation,
                tools: normalized.tools ?? [],
                options: options
            )
            if result.hasToolCall, let name = result.toolName {
                let (parsed, validationError) = ToolMapper.validateGeneratedToolCall(
                    name: name,
                    argumentsJSON: result.toolArguments,
                    against: normalized.tools ?? []
                )
                guard let parsed else {
                    let text = [result.text, ToolMapper.invalidToolCallText(validationError)].compactMap { $0 }.joined(separator: "\n\n")
                    return jsonResponse(OutputMapper.toTextMessage(
                        model: normalized.model, text: text,
                        inputTokens: result.inputTokens, outputTokens: result.outputTokens, stopReason: "end_turn"
                    ))
                }
                return jsonResponse(OutputMapper.toMixedMessage(
                    model: normalized.model, text: result.text, toolName: parsed.name,
                    arguments: parsed.argumentsJSON, inputTokens: result.inputTokens, outputTokens: result.outputTokens
                ))
            } else {
                return jsonResponse(OutputMapper.toTextMessage(
                    model: normalized.model, text: result.text ?? "",
                    inputTokens: result.inputTokens, outputTokens: result.outputTokens, stopReason: "end_turn"
                ))
            }
        } catch let error as LanguageModelSession.GenerationError {
            if case .refusal = error {
                return jsonResponse(OutputMapper.toTextMessage(
                    model: normalized.model, text: "The model declined to generate a response (guardrail refusal).",
                    inputTokens: 0, outputTokens: 1, stopReason: "end_turn"
                ))
            }
            return anthropicErrorResponse(ErrorMapper.map(error))
        } catch {
            return anthropicErrorResponse(ErrorMapper.map(error))
        }
    }

    do {
        let result = try await afm.generate(
            instructions: instructions,
            conversation: conversation,
            options: options,
            conversationKey: prepared.sessionKey,
            sessionFingerprint: prepared.sessionFingerprint,
            incrementalPrompt: prepared.incrementalPrompt
        )
        return jsonResponse(OutputMapper.toTextMessage(
            model: normalized.model, text: result.text,
            inputTokens: result.inputTokens, outputTokens: result.outputTokens, stopReason: result.stopReason
        ))
    } catch let error as LanguageModelSession.GenerationError {
        if case .refusal = error {
            return jsonResponse(OutputMapper.toTextMessage(
                model: normalized.model, text: "The model declined to generate a response (guardrail refusal).",
                inputTokens: 0, outputTokens: 1, stopReason: "end_turn"
            ))
        }
        return anthropicErrorResponse(ErrorMapper.map(error))
    } catch {
        return anthropicErrorResponse(ErrorMapper.map(error))
    }
}

private func sseHeaders() -> HTTPFields {
    var h: HTTPFields = [.contentType: "text/event-stream"]
    h.append(HTTPField(name: HTTPField.Name("cache-control")!, value: "no-cache"))
    h.append(HTTPField(name: HTTPField.Name("connection")!, value: "keep-alive"))
    return h
}

private func streamText(
    afm: AFMRuntime, model: String, instructions: String, conversation: String, options: GenerationOptions,
    writer: inout any ResponseBodyWriter, allocator: ByteBufferAllocator
) async throws {
    try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: 0), allocator: allocator))

    let session = afm.newSession(instructions: instructions)
    var lastEmitted = ""

    do {
        let stream = session.streamResponse(to: conversation, options: options)
        for try await snapshot in stream {
            let cumulative = snapshot.content
            let delta = DeltaStreamer.delta(previous: lastEmitted, current: cumulative)
            lastEmitted = cumulative
            if !delta.isEmpty {
                try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: 0, text: delta), allocator: allocator))
            }
        }
    } catch let error as LanguageModelSession.GenerationError {
        if case .refusal = error {
            let notice = "The model declined to generate a response (guardrail refusal)."
            try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: 0, text: notice), allocator: allocator))
            lastEmitted = notice
        } else {
            let err = ErrorMapper.map(error)
            try await writer.write(SSEWriter.event("error", payload: AnthropicErrorEnvelope(errorType: err.errorType, message: err.message), allocator: allocator))
            return
        }
    }

    let outputTokens = await TokenCounter.countOutput(model: afm.model, text: lastEmitted)
    try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: 0), allocator: allocator))
    try await writer.write(SSEWriter.event("message_delta", payload: MessageDeltaEvent(stopReason: "end_turn", outputTokens: outputTokens), allocator: allocator))
    try await writer.write(SSEWriter.event("message_stop", payload: MessageStopEvent(), allocator: allocator))
}

private func streamStructured(
    afm: AFMRuntime, model: String, tools: [ToolDefinition], instructions: String, conversation: String, options: GenerationOptions,
    writer: inout any ResponseBodyWriter, allocator: ByteBufferAllocator
) async throws {
    do {
        let result = try await afm.generateStructured(
            instructions: instructions,
            conversation: conversation,
            tools: tools,
            options: options
        )
        let lastText = result.text ?? ""
        let toolName = result.toolName
        let toolArgs = result.toolArguments

        var blockIndex = 0
        if !lastText.isEmpty {
            try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: blockIndex), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: blockIndex, text: lastText), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: blockIndex), allocator: allocator))
            blockIndex += 1
        }

        var stopReason = "end_turn"
        if let toolName {
            let (parsed, validationError) = ToolMapper.validateGeneratedToolCall(name: toolName, argumentsJSON: toolArgs, against: tools)
            if let parsed {
                let toolUseId = ToolMapper.makeToolUseID()
                try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: blockIndex, toolUseId: toolUseId, toolName: parsed.name), allocator: allocator))
                try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: blockIndex, partialJson: parsed.argumentsJSON), allocator: allocator))
                try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: blockIndex), allocator: allocator))
                stopReason = "tool_use"
            } else {
                try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: blockIndex), allocator: allocator))
                try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: blockIndex, text: ToolMapper.invalidToolCallText(validationError)), allocator: allocator))
                try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: blockIndex), allocator: allocator))
            }
            blockIndex += 1
        }

        if blockIndex == 0 {
            try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: 0), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: 0, text: "(no response generated)"), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: 0), allocator: allocator))
        }

        try await writer.write(SSEWriter.event("message_delta", payload: MessageDeltaEvent(stopReason: stopReason, outputTokens: result.outputTokens), allocator: allocator))
        try await writer.write(SSEWriter.event("message_stop", payload: MessageStopEvent(), allocator: allocator))

    } catch let error as LanguageModelSession.GenerationError {
        if case .refusal = error {
            try await writer.write(SSEWriter.event("content_block_start", payload: ContentBlockStartEvent(index: 0), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: 0, text: "The model declined to generate a response (guardrail refusal)."), allocator: allocator))
            try await writer.write(SSEWriter.event("content_block_stop", payload: ContentBlockStopEvent(index: 0), allocator: allocator))
            try await writer.write(SSEWriter.event("message_delta", payload: MessageDeltaEvent(stopReason: "end_turn", outputTokens: 1), allocator: allocator))
            try await writer.write(SSEWriter.event("message_stop", payload: MessageStopEvent(), allocator: allocator))
        } else {
            let err = ErrorMapper.map(error)
            try await writer.write(SSEWriter.event("error", payload: AnthropicErrorEnvelope(errorType: err.errorType, message: err.message), allocator: allocator))
        }
    } catch {
        let err = ErrorMapper.map(error)
        try await writer.write(SSEWriter.event("error", payload: AnthropicErrorEnvelope(errorType: err.errorType, message: err.message), allocator: allocator))
    }
}

func handleCountTokens(
    request: Request,
    context: BasicRequestContext,
    afm: AFMRuntime,
    diagnostics: Diagnostics
) async throws -> Response {
    let countReq: CountTokensRequest
    do {
        countReq = try await request.decode(as: CountTokensRequest.self, context: context)
    } catch {
        return anthropicErrorResponse(.badRequest("Failed to decode /v1/messages/count_tokens request body: \(error)"))
    }

    if let model = countReq.model, !ModelRegistry.isSupported(model) {
        diagnostics.ignoredField("model", detail: "(count_tokens: model '\(model)' not recognized but counted anyway)")
    }

    guard let normalized = MessageNormalizer.normalizeForCount(countReq, diagnostics: diagnostics) else {
        return jsonResponse(CountTokensResponse(inputTokens: 0))
    }

    let instructions = TranscriptBuilder.instructions(from: normalized)
    let conversation = TranscriptBuilder.conversation(from: normalized)

    guard !PromptTruncator.isTooLarge(instructions: instructions, conversation: conversation) else {
        return anthropicErrorResponse(.contextTooLarge("Input exceeds claude-afm-bridge hard context limit before token counting."))
    }

    if afm.availability.isAvailable {
        let inputTokens = await TokenCounter.countInput(model: afm.model, system: instructions, conversation: conversation)
        return jsonResponse(CountTokensResponse(inputTokens: inputTokens))
    } else {
        let combined = instructions + "\n\n" + conversation
        return jsonResponse(CountTokensResponse(inputTokens: TokenCounter.heuristic(combined)))
    }
}
