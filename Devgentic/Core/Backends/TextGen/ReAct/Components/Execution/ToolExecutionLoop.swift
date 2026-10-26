// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolExecutionLoop.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ToolExecutionLoop")

/// Deduplicates and executes a set of tool calls with HITL, ask_user interception,
/// tracing, and observation collection.
///
/// **Execution Strategy:**
/// - Autonomous tools (no user interaction required) run in parallel via TaskGroup.
/// - Interactive tools (`ask_user` or `requiresConfirmation`) run sequentially AFTER
///   autonomous tools complete, ensuring only one UI suspension banner is active at a time.
///
/// - Returns: An array of `ToolObservation` for each executed tool.
func executeToolCalls(
    toolCalls: [PendingToolCall],
    availableTools: [AgentTool],
    conversationID: UUID,
    currentIteration: Int,
    iterationSpan: TraceContext,
    toolMediator: ToolExecutionMediator,
    interactionMemory: RunInteractionMemory,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    /// Workflow node this run belongs to, or nil for chat/code. Scopes the "Allow for this chat"
    /// allowlist so a grant in one node does not answer for another — see `SessionToolApprovals`.
    approvalNodeID: UUID? = nil,
    /// [WF-SE6/SE11] The workflow node's EXPLICIT unattended-approval setting; false for
    /// chat/code and for nodes without it. Only consulted when the run is unattended.
    unattendedAutoApprove: Bool = false,
    /// Code mode's project folder. Nil for every other profile — those stay unconfined.
    workspaceRoot: String? = nil,
    /// Calls of this same step that failed validation while these passed; each becomes a "Not run" observation.
    rejectedCalls: [RejectedSiblingCall] = [],
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) async throws -> [ToolObservation] {

    // Emits the per-iteration reasoning trace up front, before dedup, so the iteration counter also counts iterations
    // that exit via `final_answer`.
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.reasoning),
        content: "Analyzing \(toolCalls.count) tool(s)...",
        metadata: ["iteration": "\(currentIteration)"]
    ))

    // Terminal fast path: when the model calls `final_answer`, every other call in this iteration is dropped, which also
    // prevents blocking on unrelated dispatch alongside it.
    if let finalCall = toolCalls.first(where: { $0.name == "final_answer" }) {
        let droppedCount = toolCalls.count - 1
        if droppedCount > 0 {
            let droppedNames = toolCalls.filter { $0.name != "final_answer" }.map(\.name).joined(separator: ", ")
            logger.warning("⚠️ final_answer called alongside \(droppedCount) other tool(s): [\(droppedNames)]. Dropping siblings — final_answer wins.")
        }
        return [try buildFinalAnswerObservation(
            call: finalCall,
            currentIteration: currentIteration,
            iterationSpan: iterationSpan,
            continuation: continuation,
            onTraceUpdate: onTraceUpdate
        )]
    }

    // --- Deduplicate ---
    let plan = planToolCalls(toolCalls)
    let uniqueToolCalls = plan.run
    logger.info("Deduped \(toolCalls.count) → \(uniqueToolCalls.count) unique tools.")

    // Partitions interactive tools (ask_user or HITL confirmation), which run sequentially so only one banner shows.
    // `uniquingKeysWith`, never `uniqueKeysWithValues`: a duplicate name is logged and the first registration wins.
    let toolLookup = Dictionary(availableTools.map { ($0.name, $0) }, uniquingKeysWith: { first, duplicate in
        logger.error("[TOOLRESOLVE] ⚠️ Two tools named '\(first.name)' reached the execution loop. CONSEQUENCE: calls go to the first registration; the duplicate is unreachable — and a provider that rejects duplicate tool names will have refused this request already. A tool was added after `resolveExecutableTools` de-duplicated the list.")
        return first
    })

    var autonomousTools: [PendingToolCall] = []
    var interactiveTools: [PendingToolCall] = []

    for tool in uniqueToolCalls {
        let isAskUser = tool.name == "ask_user"
        let requiresConfirmation = toolLookup[tool.name]?.requiresConfirmation ?? false

        if isAskUser || requiresConfirmation {
            interactiveTools.append(tool)
        } else {
            autonomousTools.append(tool)
        }
    }

    if !interactiveTools.isEmpty {
        logger.info("Partitioned tools: \(autonomousTools.count) autonomous (parallel), \(interactiveTools.count) interactive (sequential).")
    }

    // A superseded write did not run; the model is told so.
    var observations: [ToolObservation] = plan.superseded.map {
        supersededObservation(for: $0.call, by: $0.by, currentIteration: currentIteration)
    }
    // A rejected sibling did not run either; the model is told so, with the reason.
    observations += rejectedCalls.map { rejectedObservation(for: $0, currentIteration: currentIteration) }

    // Autonomous tools run in parallel, one task per lane; calls that change a common file run in order in a lane.
    if !autonomousTools.isEmpty {
        let lanes = executionLanes(for: autonomousTools, workspaceRoot: workspaceRoot)
        if lanes.count < autonomousTools.count {
            logger.info("[TOOLS] \(autonomousTools.count) autonomous call(s) in \(lanes.count) lane(s): calls that change the same file run one after another, in the order the model gave. CONSEQUENCE: no edit is overwritten by a concurrent one.")
        }
        try await withThrowingTaskGroup(of: [ToolObservation].self) { group in
            for lane in lanes {
                group.addTask {
                    var laneObservations: [ToolObservation] = []
                    for tool in lane {
                        try Task.checkCancellation()
                        laneObservations.append(try await executeSingleTool(
                            tool: tool,
                            availableTools: availableTools,
                            conversationID: conversationID,
                            currentIteration: currentIteration,
                            iterationSpan: iterationSpan,
                            toolMediator: toolMediator,
                            interactionMemory: interactionMemory,
                            continuation: continuation,
                            approvalNodeID: approvalNodeID,
                            unattendedAutoApprove: unattendedAutoApprove,
                            workspaceRoot: workspaceRoot,
                            onTraceUpdate: onTraceUpdate
                        ))
                    }
                    return laneObservations
                }
            }

            for try await laneObservations in group {
                observations.append(contentsOf: laneObservations)
            }
        }
    }

    // Interactive tools run sequentially, after the autonomous ones, so only one suspension banner is active at a time.
    for tool in interactiveTools {
        try Task.checkCancellation()

        let observation = try await executeSingleTool(
            tool: tool,
            availableTools: availableTools,
            conversationID: conversationID,
            currentIteration: currentIteration,
            iterationSpan: iterationSpan,
            toolMediator: toolMediator,
            interactionMemory: interactionMemory,
            continuation: continuation,
            approvalNodeID: approvalNodeID,
            unattendedAutoApprove: unattendedAutoApprove,
                workspaceRoot: workspaceRoot,
            onTraceUpdate: onTraceUpdate
        )
        observations.append(observation)
    }

    let outcomesOverview = observations.map { "[\($0.toolName): \($0.summary)]" }.joined(separator: ", ")
    logger.debug("Executed \(observations.count) parallel outcomes: \(outcomesOverview)")

    return observations
}

// MARK: - Single Tool Execution

/// Executes a single tool call with full event emission, ask_user interception,
/// HITL permission gating, tracing, and observation construction.
private func executeSingleTool(
    tool: PendingToolCall,
    availableTools: [AgentTool],
    conversationID: UUID,
    currentIteration: Int,
    iterationSpan: TraceContext,
    toolMediator: ToolExecutionMediator,
    interactionMemory: RunInteractionMemory,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    /// Workflow node this run belongs to, or nil for chat/code — scopes the approval allowlist.
    approvalNodeID: UUID?,
    /// [WF-SE6/SE11] see the outer overload.
    unattendedAutoApprove: Bool,
    /// Code mode's project folder; nil leaves the call unconfined.
    workspaceRoot: String?,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) async throws -> ToolObservation {

    let toolCallId = tool.id
    let toolName = tool.name

    // Workspace boundary: runs before anything else touches the arguments. Resolves relative paths against the project
    // (not $HOME) and refuses writes outside it; reads outside go through the confirmation banner. Nil root changes nothing.
    let tool0Arguments = tool.arguments
    let boundary = WorkspaceBoundaryDecision.evaluate(
        toolName: toolName,
        arguments: tool0Arguments,
        workspaceRoot: workspaceRoot
    )

    if case .refuse(let reason) = boundary.outcome {
        logger.error("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' REFUSED. \(reason) CONSEQUENCE: the tool did not run and nothing was written; the model receives this reason as its observation and can retry inside the project or ask the user to change the project folder.")
        let refusalOutput = ToolOutput(toolName: toolName, params: serializeToolParams(tool.arguments), output: reason, isSuccess: false)
        continuation.yield(.toolFailed(refusalOutput, category: .permissionRejected))
        return ToolObservation(
            stepId: currentIteration,
            toolCallId: toolCallId,
            toolName: toolName,
            result: reason,
            summary: reason,
            isSuccess: false,
            params: serializeToolParams(tool.arguments),
            output: reason,
            artifacts: [],
            failureCategory: .permissionRejected
        )
    }

    // Path arguments are project-anchored and canonical from here on, so what the user approves is what runs.
    let tool = PendingToolCall(id: tool.id, name: tool.name, arguments: boundary.arguments)
    let arguments = tool.arguments
    let paramsString = serializeToolParams(arguments)

    // Logged only when the boundary changed a path, so ordinary in-project calls stay quiet.
    if workspaceRoot != nil, boundary.arguments != tool0Arguments {
        logger.info("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' path(s) re-anchored to the project before dispatch: \(serializeToolParams(tool0Arguments)) → \(paramsString). CONSEQUENCE: the tool, the confirmation banner and the timeline all see the resolved path, so what the user approves is what runs.")
    }

    if case .askUser(let reason) = boundary.outcome {
        // No one can be asked in an unattended run (no banner is rendered), so the request is refused at once.
        if !WorkflowRunAttendance.canReachAHuman {
            let refusal = "\(reason) Nobody can answer in this run (it is unattended), so the path outside the project was NOT accessed. Stay inside the project folder."
            logger.notice("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' reaches outside the project in an UNATTENDED run. CONSEQUENCE: refused without parking; the model is told nobody can approve it.")
            let refusalOutput = ToolOutput(toolName: toolName, params: paramsString, output: refusal, isSuccess: false)
            continuation.yield(.toolFailed(refusalOutput, category: .permissionRejected))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: refusal,
                summary: refusal,
                isSuccess: false,
                params: paramsString,
                output: refusal,
                artifacts: [],
                failureCategory: .permissionRejected
            )
        }
        let operationID = UUID()
        logger.notice("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' reaches outside the project; asking the user. \(reason) CONSEQUENCE: the run PARKS on a confirmation banner and the compute budget stops counting while it waits; if the user declines, the model gets an honest observation and stays inside the project.")
        continuation.yield(.requestConfirmation(toolName: toolName, params: "\(reason)\n\n\(paramsString)", operationID: operationID))
        let approved = await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID, nodeID: approvalNodeID)
        // A Stop resolves the park as `false`; without this check it would be reported as a denial nobody made.
        try Task.checkCancellation()
        if !approved {
            let denial = "\(reason) The user declined. Stay inside the project folder, or ask them which folder to use."
            let denialOutput = ToolOutput(toolName: toolName, params: paramsString, output: denial, isSuccess: false)
            continuation.yield(.toolFailed(denialOutput, category: .userDenied))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: denial,
                summary: denial,
                isSuccess: false,
                params: paramsString,
                output: denial,
                artifacts: [],
                failureCategory: .userDenied
            )
        }
        logger.info("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' APPROVED by the user for a path outside the project: \(paramsString). CONSEQUENCE: this one call proceeds; the grant is not remembered, so a later out-of-project read asks again.")
    }
    // ─────────────────────────────────────────────────────────────────────────────────────────

    // Emit UI Event
    continuation.yield(.toolCall(name: toolName, params: paramsString, stepId: currentIteration))

    // Emit Trace Event
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .acting(.tool(name: toolName)),
        content: "Executing '\(toolName)'...",
        // `tool_params` rides along on the span event so the report shows what the tool was asked to do before the result lands.
        metadata: ["tool_name": toolName, "tool_params": paramsString]
    ))

    // Intercept ask_user
    if let question = AskUserInterceptor.extractQuestion(toolName: toolName, arguments: arguments) {
        // Loop safety: an identical re-ask replays the earlier response instead of re-raising the banner, so a stuck ask-loop
        // is deterministic and the repetition fingerprint's warn/stop ladder governs it.
        if let stored = await interactionMemory.storedResponse(forQuestion: question) {
            logger.info("[LoopSafety] 'ask_user' repeated an identical question — replaying the earlier response, no banner.")
            continuation.yield(.thought("↩️ Repeated question — replaying your earlier response."))
            let didAnswer = stored != nil
            let answerText = stored ?? "System: The user skipped or did not respond."
            let askOutput = ToolOutput(
                toolName: toolName,
                params: paramsString,
                output: didAnswer ? "User answered: \(answerText)" : "Skipped by user.",
                isSuccess: didAnswer
            )
            if didAnswer {
                continuation.yield(.toolSucceeded(askOutput))
            } else {
                continuation.yield(.toolFailed(askOutput, category: .cancelled))
            }
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: "User Response: \(answerText)",
                summary: "User Response: \(answerText)",
                isSuccess: didAnswer,
                params: question,
                output: "User Response: \(answerText)",
                artifacts: [],
                failureCategory: didAnswer ? nil : .cancelled
            )
        }

        // Nobody to ask in an unattended run: `suspendForClarification` is unbounded, so the call is refused with the existing
        // skip observation ("the user skipped or did not respond"); the confirmation arm's remedy does not apply to ask_user.
        if !WorkflowRunAttendance.canReachAHuman {
            let skipText = "System: No one is available to answer (this run is unattended). Proceed with reasonable assumptions, or stop and report what you need."
            logger.error("[HITL] ask_user REFUSED — nobody can answer this run (scheduled), question of \(question.count) chars. CONSEQUENCE: the agent is told immediately that no answer is coming and continues on assumptions, instead of parking indefinitely until the run deadline cancels everything.")
            // Closes the `.toolCall` row opened above before returning, as the identical-re-ask replay arm does.
            let askOutput = ToolOutput(toolName: toolName, params: paramsString, output: skipText, isSuccess: true)
            continuation.yield(.toolSucceeded(askOutput))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: skipText,
                summary: skipText,
                isSuccess: true,
                params: paramsString,
                output: skipText,
                artifacts: [],
                failureCategory: nil
            )
        }

        let operationID = UUID()
        continuation.yield(.requestClarification(
            question: question,
            operationID: operationID,
            options: AskUserInterceptor.extractOptions(arguments),
            multiline: AskUserInterceptor.extractMultiline(arguments)
        ))

        let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: operationID, conversationID: conversationID, nodeID: approvalNodeID)

        // A cancelled clarification resolves nil; checked before `recordAnswer` so a fabricated skip is neither
        // remembered nor reported as `.toolFailed(.cancelled)`.
        if Task.isCancelled { throw CancellationError() }

        // [Loop Safety] Remember the response (or skip) so an identical re-ask replays it.
        await interactionMemory.recordAnswer(question: question, response: userResponse)
        let didAnswer = userResponse != nil
        let answerText = userResponse ?? "System: The user skipped or did not respond."

        // Resolve the timeline chip: send = success, skip/timeout = cancelled (soft failure, no constraint).
        let askOutput = ToolOutput(
            toolName: toolName,
            params: paramsString,
            output: didAnswer ? "User answered: \(answerText)" : "Skipped by user.",
            isSuccess: didAnswer
        )
        if didAnswer {
            continuation.yield(.toolSucceeded(askOutput))
        } else {
            continuation.yield(.toolFailed(askOutput, category: .cancelled))
        }

        return ToolObservation(
            stepId: currentIteration,
            toolCallId: toolCallId,
            toolName: toolName,
            result: "User Response: \(answerText)",
            summary: "User Response: \(answerText)",
            isSuccess: didAnswer,
            params: question,
            output: "User Response: \(answerText)",
            artifacts: [],
            failureCategory: didAnswer ? nil : .cancelled
        )
    }

    // [HITL/A3] Default to the agent's arguments; replaced by user edits if the confirmation was edited.
    var effectiveArguments = arguments
    var effectiveParams = paramsString
    /// Set when the user changed the arguments in the banner; the observation must say so.
    var userEditedParams: String?

    // Dispatch (handles HITL)
    let dispatchOutcome = toolMediator.prepareDispatch(
        toolName: toolName,
        arguments: arguments,
        availableTools: availableTools
    )

    switch dispatchOutcome {
    case .requiresConfirmation(let ps):
        // HITL: the banner is skipped when this run allowed the tool (or this exact call), or the user chose "Allow for this
        // chat" (durable, scoped to the conversation and to `approvalNodeID` inside a workflow). Exact-call grants match on
        // the canonical form of the same `arguments` the banner was built from.
        if await SessionToolApprovals.shared.isAllowed(
            toolName: toolName, conversationID: conversationID, nodeID: approvalNodeID,
            canonicalArguments: SessionToolApprovals.canonicalArguments(arguments)
        ) {
            logger.info("[HITL] '\(toolName)' auto-approved by a standing grant — skipping banner.")
        } else if await interactionMemory.isDenied(toolName: toolName, params: paramsString) {
            // Loop safety: an identical already-declined request is auto-denied without a banner, with an observation identical
            // to a manual denial; a request with different arguments still reaches the user.
            logger.info("[LoopSafety] '\(toolName)' repeated an identical declined request — auto-denied, no banner.")
            continuation.yield(.thought("🚫 Repeated a declined request — auto-denied."))
            let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
            let denialOutput = ToolOutput(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
            continuation.yield(.toolFailed(denialOutput, category: .userDenied))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: denialResult.llmObservation,
                summary: denialResult.llmObservation,
                isSuccess: false,
                params: paramsString,
                output: denialResult.llmObservation,
                artifacts: [],
                failureCategory: .userDenied
            )
        } else if !WorkflowRunAttendance.canReachAHuman {
            // Nobody to ask in a scheduled run (no banner, no remote channel): refused fast with an actionable observation.
            // `hasRemoteResponder` matters: a ChatOps run is unattended but a human can answer the mirrored prompt.
            if unattendedAutoApprove {
                logger.notice("[HITL] '\(toolName)' auto-approved by the workflow node's EXPLICIT unattended setting (run is unattended). CONSEQUENCE: the tool runs with no banner; this is configured intent, not a leaked chat grant.")
                // fall through to execution below — same as an attended allowlist hit
            } else {
                let remedy = approvalNodeID != nil
                    ? "Enable \u{201C}Unattended auto-approve\u{201D} on this workflow node, or run attended."
                    : "Turn off Ask-first for this tool in the profile's Tool Library, or run attended."
                let reason = "Tool '\(toolName)' requires confirmation, but this run is unattended — nobody can answer. The tool was NOT executed. \(remedy)"
                logger.error("[HITL] '\(toolName)' REFUSED — unattended run, no standing approval. CONSEQUENCE: the tool is refused NOW with an honest observation instead of parking to nobody until the run deadline kills everything. \(remedy)")
                let refusalOutput = ToolOutput(toolName: toolName, params: paramsString, output: reason, isSuccess: false)
                // Timeline tier is `.permissionRejected` (not `.userDenied`); dashboard tier is the classified
                // `.hitlUnattendedRefused`.
                continuation.yield(.toolFailed(refusalOutput, category: .permissionRejected))
                await TraceRecorder.shared.emitAgentError(
                    span: iterationSpan,
                    error: ClassifiedAgentError.synthetic(
                        category: .hitlUnattendedRefused,
                        origin: "ToolExecutionLoop.unattendedConfirmation",
                        message: reason,
                        context: ["tool": toolName]
                    ),
                    iteration: currentIteration
                )
                return ToolObservation(
                    stepId: currentIteration,
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: reason,
                    summary: reason,
                    isSuccess: false,
                    params: paramsString,
                    output: reason,
                    artifacts: [],
                    failureCategory: .permissionRejected
                )
            }
        } else {
            let operationID = UUID()
            continuation.yield(.requestConfirmation(toolName: toolName, params: ps, operationID: operationID))

            let approved = await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID, nodeID: approvalNodeID)

            // Why: without this check Stop would record a denial, auto-deny identical later calls and charge the denial circuit breaker
            // A cancelled park is not a denial: teardown resolves a waiting permission with `false`, so throwing here avoids
            // recording a decision the user never made. Safe: the function is `async throws` and callers absorb CancellationError.
            if Task.isCancelled { throw CancellationError() }

            if approved, let edited = await ExecutionSuspensionService.shared.consumeEditedArguments(for: operationID) {
                // The user corrected the arguments in the banner: run with those, after the same workspace boundary.
                // A write outside is still refused; a read outside runs because the user approved exactly that path.
                let editedBoundary = WorkspaceBoundaryDecision.evaluate(
                    toolName: toolName, arguments: edited, workspaceRoot: workspaceRoot)
                if case .refuse(let reason) = editedBoundary.outcome {
                    let editedParams = serializeToolParams(edited)
                    logger.error("[WORKSPACE] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' REFUSED after the user edited its arguments. \(reason) CONSEQUENCE: the tool did not run and nothing was written; the model is told the edited call was refused.")
                    let refusal = "The user edited this call's arguments to \(editedParams), and that was refused: \(reason)"
                    continuation.yield(.toolFailed(ToolOutput(toolName: toolName, params: editedParams, output: refusal, isSuccess: false, rowParams: paramsString), category: .permissionRejected))
                    return ToolObservation(
                        stepId: currentIteration, toolCallId: toolCallId, toolName: toolName,
                        result: refusal, summary: refusal, isSuccess: false, params: editedParams,
                        output: refusal, artifacts: [], failureCategory: .permissionRejected)
                }
                effectiveArguments = editedBoundary.arguments
                effectiveParams = serializeToolParams(editedBoundary.arguments)
                if effectiveParams != paramsString {
                    userEditedParams = effectiveParams
                    logger.info("[HITL] conv \(conversationID.uuidString.prefix(8)) — '\(toolName)' runs with the user's edited arguments: \(paramsString) → \(effectiveParams). CONSEQUENCE: the observation tells the model its arguments were changed, so it doesn't reason from the ones it sent.")
                }
            }
            if !approved {
                // [Loop Safety] Remember the denial so an identical re-ask is auto-denied.
                await interactionMemory.recordDenial(toolName: toolName, params: paramsString)
                let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                let denialOutput = ToolOutput(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
                continuation.yield(.toolFailed(denialOutput, category: .userDenied))
                return ToolObservation(
                    stepId: currentIteration,
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: denialResult.llmObservation,
                    summary: denialResult.llmObservation,
                    isSuccess: false,
                    params: paramsString,
                    output: denialResult.llmObservation,
                    artifacts: [],
                    failureCategory: .userDenied
                )
            }
        }
    case .executed, .userDenied:
        break
    }

    // Delegation lifecycle: wrap call_agent dispatch with structured events so the
    // UI surfaces "spawned an agent" / "agent returned" distinct from a normal tool call.
    let isDelegation = toolName == "call_agent"
    if isDelegation {
        let task = effectiveArguments["task"]?.stringValue ?? "unknown task"
        continuation.yield(.delegationStarted(task: task))
    }

    // Pre-write snapshot for file-writing tools, from the post-HITL-edit arguments; the timeline's "View changes" diffs
    // against it, since nothing else records the file's prior state.
    let preWriteContent = await preWriteSnapshot(toolName: toolName, arguments: effectiveArguments)

    let dispatchStart = Date()
    let result = await toolMediator.executePreparedTool(
        toolName: toolName,
        arguments: effectiveArguments,
        availableTools: availableTools,
        parentContext: iterationSpan
    )
    let durationMs = Int(Date().timeIntervalSince(dispatchStart) * 1000)

    if isDelegation {
        let summary = result.isSuccess
            ? String(result.llmObservation.prefix(150))
            : "Delegation failed: \(String(result.llmObservation.prefix(120)))"
        continuation.yield(.delegationCompleted(summary: summary))
    }

    // Edit tools' params carry only find/replace strings — read the post-state back so
    // the timeline can diff what actually changed.
    let postWriteContent = await postWriteSnapshot(toolName: toolName, arguments: effectiveArguments, isSuccess: result.isSuccess)

    // Emits structured success/failure; the category drives the negative-constraints policy and UI affordance.
    // `rowParams` is what the timeline row was created from, which a banner edit may have changed.
    let output = ToolOutput(toolName: toolName, params: effectiveParams, output: result.llmObservation, isSuccess: result.isSuccess, preWriteContent: preWriteContent, postWriteContent: postWriteContent, rowParams: effectiveParams == paramsString ? nil : paramsString)
    if let category = result.failureCategory {
        continuation.yield(.toolFailed(output, category: category))
    } else {
        continuation.yield(.toolSucceeded(output, durationMs: durationMs))
    }

    // Emit media artifacts if produced
    for artifact in result.artifacts {
        continuation.yield(.artifactProduced(artifact))
    }

    // Emit Trace Observation
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.reflecting),
        content: result.isSuccess ? "Tool '\(toolName)' succeeded." : "Tool '\(toolName)' failed.",
        metadata: [
            "tool_name": toolName,
            "is_success": "\(result.isSuccess)",
            "tool_params": effectiveParams,
            "tool_output": result.llmObservation
        ]
    ))

    // The model's own turn carries the arguments it sent; the result states what actually ran.
    let observedResult = userEditedParams.map {
        "[The user edited this call's arguments before it ran. It ran with: \($0)]\n\(result.llmObservation)"
    } ?? result.llmObservation

    return ToolObservation(
        stepId: currentIteration,
        toolCallId: toolCallId,
        toolName: toolName,
        result: observedResult,
        summary: result.isSuccess ? "Tool '\(toolName)' executed successfully." : "Tool '\(toolName)' failed: \(result.llmObservation)",
        isSuccess: result.isSuccess,
        params: effectiveParams,
        output: result.llmObservation,
        artifacts: result.artifacts,
        failureCategory: result.failureCategory
    )
}

// MARK: - Testable Helpers

/// Tools whose successful execution mutates a file on disk; each gets a pre-write snapshot for the "View changes" diff.
/// Keep in step with `AgentTimelineView.chipEligibleTools`, or a snapshot goes unrendered or a chip has no data.
private let preSnapshotToolNames: Set<String> = [
    "write_file", "overwrite_file", "create_new_file", "create_file",
    "edit_code_single", "edit_code_batch", "edit_code"
]

/// Tools whose params do not carry the full post-state (`edit_code_*` carry find/replace strings only); these get a
/// post-write read-back after success, since the post-state exists only on disk.
private let postSnapshotToolNames: Set<String> = ["edit_code_single", "edit_code_batch", "edit_code"]

/// Exposes the executor's snapshot sets and the timeline's chip set, two halves of one contract, so a test can assert
/// they stay in step.
enum SnapshotToolContract {
    static var preSnapshot: Set<String> { preSnapshotToolNames }
    static var postSnapshot: Set<String> { postSnapshotToolNames }
}

/// Snapshot cap: source files land far below this; anything bigger isn't worth
/// carrying in a persisted timeline event just to render a diff.
private let preWriteSnapshotByteLimit = 512_000

/// The file-target path of a mutating tool call: native tools take `path`, split tools `file_path`.
/// Resolved through `FilePathResolver`, as the writing tools do, so a relative path anchors identically.
/// Internal (not private) so a test can reach the rule that decides which file the snapshot reads.
func fileTargetPath(in arguments: [String: JSONValue]) -> String? {
    guard let path = arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue,
          !path.isEmpty else { return nil }
    return FilePathResolver.resolve(path)
}

/// Size-capped UTF-8 read of a snapshot target. Nil = unreadable or over the cap.
private func snapshotContents(atPath resolved: String) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
          (attributes[.size] as? Int ?? .max) <= preWriteSnapshotByteLimit,
          let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
        return nil
    }
    return content
}

/// The target file's content just before a file-mutating tool runs. "" means the file does not exist yet; nil means
/// not a file-mutating tool, no path argument, or the file is unreadable or over the cap (logged).
private func preWriteSnapshot(toolName: String, arguments: [String: JSONValue]) async -> String? {
    guard preSnapshotToolNames.contains(toolName),
          let resolved = fileTargetPath(in: arguments) else { return nil }

    // Why: blocking a cooperative thread starves every other concurrent task in the agent run
    // Runs off the cooperative pool: it reads up to `preWriteSnapshotByteLimit` bytes synchronously.
    return await Task.detached(priority: .utility) { () -> String? in
        guard FileManager.default.fileExists(atPath: resolved) else { return "" }
        guard let content = snapshotContents(atPath: resolved) else {
            logger.info("[CodeViewer] Pre-write snapshot skipped for '\(resolved)' — unreadable or over \(preWriteSnapshotByteLimit) bytes; the timeline row will open without a diff.")
            return nil
        }
        return content
    }.value
}

/// The target file's content just after a SUCCESSFUL edit-tool run — the post-state the
/// params can't provide. Nil = tool doesn't need read-back, the call failed, or the file
/// is unreadable/over the cap (row gets no viewer affordance, logged).
private func postWriteSnapshot(toolName: String, arguments: [String: JSONValue], isSuccess: Bool) async -> String? {
    guard isSuccess, postSnapshotToolNames.contains(toolName),
          let resolved = fileTargetPath(in: arguments) else { return nil }

    // Off the cooperative pool — see `preWriteSnapshot`.
    return await Task.detached(priority: .utility) { () -> String? in
        guard let content = snapshotContents(atPath: resolved) else {
            logger.info("[CodeViewer] Post-edit snapshot skipped for '\(resolved)' — unreadable or over \(preWriteSnapshotByteLimit) bytes; the timeline row will open without a diff.")
            return nil
        }
        return content
    }.value
}

/// What one step's tool calls become: the calls that run, and the earlier writes a later call in the
/// same step replaced (each paired with the call that replaced it).
struct ToolCallPlan {
    let run: [PendingToolCall]
    let superseded: [(call: PendingToolCall, by: PendingToolCall)]
}

func deduplicateToolCalls(_ toolCalls: [PendingToolCall]) -> [PendingToolCall] {
    planToolCalls(toolCalls).run
}

/// Exact duplicates collapse to one; of several writes to the same target in one step only the last runs.
/// The target is every path role of the tool (a copy or move is its source and destination); replaced calls are
/// returned in `superseded` so the loop reports that they did not run.
func planToolCalls(_ toolCalls: [PendingToolCall]) -> ToolCallPlan {
    // Exact dedup: removes calls with identical name and serialized params.
    var exactUnique: [PendingToolCall] = []
    var seen = Set<String>()
    for tool in toolCalls {
        let signature = "\(tool.name)|\(serializeToolParams(tool.arguments))"
        if !seen.contains(signature) {
            seen.insert(signature)
            exactUnique.append(tool)
        }
    }

    // Semantic dedup keeps only the last of several writes to the same target, so near-identical write_file
    // calls cannot flood the HITL queue.
    var lastIndexByTarget: [String: Int] = [:]
    for (index, tool) in exactUnique.enumerated() {
        if let target = writeTarget(of: tool) { lastIndexByTarget[target] = index }
    }

    var run: [PendingToolCall] = []
    var superseded: [(call: PendingToolCall, by: PendingToolCall)] = []
    for (index, tool) in exactUnique.enumerated() {
        if let target = writeTarget(of: tool), let last = lastIndexByTarget[target], last != index {
            superseded.append((tool, exactUnique[last]))
        } else {
            run.append(tool)
        }
    }

    if !superseded.isEmpty {
        logger.info("🔀 Semantic dedup: \(superseded.count) earlier write(s) superseded by a later call to the same target in this step, keeping last intent: \(superseded.map { "\($0.call.name) \($0.call.id.prefix(12)) → \($0.by.id.prefix(12))" }.joined(separator: ", ")). CONSEQUENCE: each superseded call is reported to the model as not run.")
    }
    return ToolCallPlan(run: run, superseded: superseded)
}

/// The target a write-like call acts on, as one key: the tool name plus the value of EACH of its
/// path roles, in role order. Nil for tools that are not deduplicated by target, or when no role
/// is present. Role lists are the decoders' own (`ToolPathKeys`).
func writeTarget(of tool: PendingToolCall) -> String? {
    let roles: [[String]]
    switch tool.name {
    case "write_file":  roles = [ToolPathKeys.writeFile]
    case "delete_file": roles = [ToolPathKeys.deleteFile]
    case "move_file":   roles = [ToolPathKeys.moveFileSource, ToolPathKeys.moveFileDestination]
    case "copy_file":   roles = [ToolPathKeys.copyFileSource, ToolPathKeys.copyFileDestination]
    default:            return nil
    }
    let normalized = normalizePathArguments(tool.arguments)
    let values: [String?] = roles.map { keys in
        for key in keys { if case .string(let value)? = normalized[key] { return value } }
        return nil
    }
    guard values.contains(where: { $0 != nil }) else { return nil }
    return ([tool.name] + values.map { $0 ?? "∅" }).joined(separator: "|")
}

/// The observation for a call a later call in the same step replaced; reported `.cancelled`, which outcome
/// accounting treats as a choice rather than evidence.
func supersededObservation(for call: PendingToolCall, by later: PendingToolCall, currentIteration: Int) -> ToolObservation {
    let note = "Not run: a later \(later.name) call in this same step (id \(later.id)) targets the same file(s), and only the last of them runs. Repeat this call in a later step if both were intended."
    return ToolObservation(
        stepId: currentIteration,
        toolCallId: call.id,
        toolName: call.name,
        result: note,
        summary: note,
        isSuccess: false,
        params: serializeToolParams(call.arguments),
        output: note,
        artifacts: [],
        failureCategory: .cancelled
    )
}

/// The observation for a call the parser rejected while its siblings ran.
func rejectedObservation(for rejected: RejectedSiblingCall, currentIteration: Int) -> ToolObservation {
    let note = rejected.modelNote
    return ToolObservation(
        stepId: currentIteration,
        toolCallId: rejected.call.id,
        toolName: rejected.call.name,
        result: note,
        summary: note,
        isSuccess: false,
        params: serializeToolParams(rejected.call.arguments),
        output: note,
        artifacts: [],
        failureCategory: {
            if case .unknownToolName = rejected.reason { return .notFound }
            return .invalidArgs
        }()
    )
}

// MARK: - Same-file ordering

/// Tools that change a file's contents or existence. Two of these on one file must not run at once.
let fileMutatingToolNames: Set<String> = [
    "write_file", "overwrite_file", "create_new_file", "create_file",
    "edit_code_single", "edit_code_batch", "edit_code",
    "delete_file", "move_file", "copy_file",
]

/// Groups autonomous calls into lanes that may run in parallel: calls that mutate a common file share a lane and run
/// in the model's order. Paths are compared after project re-anchoring, so `a.swift` and `/proj/a.swift` are one file.
func executionLanes(for calls: [PendingToolCall], workspaceRoot: String?) -> [[PendingToolCall]] {
    var lanes: [[PendingToolCall]] = []
    var laneByPath: [String: Int] = [:]
    for call in calls {
        guard fileMutatingToolNames.contains(call.name) else {
            lanes.append([call])
            continue
        }
        let anchored = WorkspaceBoundaryDecision.evaluate(toolName: call.name, arguments: call.arguments, workspaceRoot: workspaceRoot).arguments
        let normalized = normalizePathArguments(anchored)
        let paths = ToolPathKeys.pathArguments(forTool: call.name).sorted().compactMap { key -> String? in
            if case .string(let value)? = normalized[key] { return value }
            return nil
        }
        // A call touching files from several lanes joins the first; later lanes' paths are folded in.
        let existing = Set(paths.compactMap { laneByPath[$0] }).sorted()
        let lane: Int
        if let first = existing.first {
            lane = first
            for other in existing.dropFirst() {
                lanes[first].append(contentsOf: lanes[other])
                lanes[other] = []
                for (path, index) in laneByPath where index == other { laneByPath[path] = first }
            }
            lanes[lane].append(call)
        } else {
            lanes.append([call])
            lane = lanes.count - 1
        }
        for path in paths { laneByPath[path] = lane }
    }
    return lanes.filter { !$0.isEmpty }
}

func serializeToolParams(_ params: [String: JSONValue]) -> String {
    let normalized = normalizePathArguments(params)
    // Sorted keys make the serialization deterministic; the repetition fingerprint and denial memory key depend on it.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(normalized), let str = String(data: data, encoding: .utf8) { return str }
    return "{}"
}

// Why: never sniff values for a leading `/`: file content starting with `//` would be rewritten and truncated
/// Normalizes filesystem path arguments to canonical form (trailing and doubled slashes, tilde, `.`/`..`) so equivalent
/// paths produce identical dedup and circuit-breaker signatures. Applies only to arguments chosen by KEY.
private let pathArgumentKeys: Set<String> = [
    "path", "file_path", "filepath", "filePath", "file", "filename", "destination",
    "destination_path", "destinationPath", "source", "source_path", "sourcePath",
    "src", "dest", "target", "target_path", "targetPath", "new_path", "newPath",
    "current_path", "currentPath", "folder", "folderPath", "directory",
    "directoryPath", "dir", "copy_path", "original", "item"
]

func normalizePathArguments(_ params: [String: JSONValue]) -> [String: JSONValue] {
    params.reduce(into: [String: JSONValue]()) { result, entry in
        let (key, value) = entry
        guard pathArgumentKeys.contains(key),
              case .string(let str) = value,
              str.hasPrefix("/") || str.hasPrefix("~") || str.hasPrefix("./") else {
            result[key] = value
            return
        }
        var normalized = str
        // Strip trailing slash (unless root "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        // Expand tilde
        normalized = (normalized as NSString).expandingTildeInPath
        // Resolve . and .. components, collapse double slashes
        normalized = (normalized as NSString).standardizingPath
        result[key] = .string(normalized)
    }
}

struct AskUserInterceptor {
    /// Connector words a truncated question commonly dangles on. Weak local models sometimes stop
    /// generating mid-sentence — emitting a value like "Could you please clarify what you mean by "
    /// (valid JSON, just unfinished). We trim these so the stem can be re-terminated as a real question.
    private static let danglingConnectors: Set<String> = [
        "by", "the", "a", "an", "your", "my", "with", "for", "about",
        "of", "to", "in", "on", "at", "as", "and", "or", "that"
    ]

    static func extractQuestion(toolName: String, arguments: [String: JSONValue]) -> String? {
        guard toolName == "ask_user" else { return nil }
        return sanitizeQuestion(arguments["question"]?.stringValue ?? "")
    }

    /// Repairs an empty or visibly unfinished clarification question so the user never sees a dead-end prompt, trimming
    /// dangling connectors and re-terminating, or substituting a complete fallback.
    static func sanitizeQuestion(_ raw: String) -> String {
        let fallback = "Could you clarify your request so I can continue?"
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallback }

        // Already a well-formed prompt (ends in terminal punctuation) — leave it untouched.
        if let last = text.last, "?.!".contains(last) { return text }

        // No terminal punctuation: strip trailing dangling connector words ("...mean by" → "...mean").
        var repaired = false
        while let lastWord = text.split(separator: " ").last.map(String.init),
              danglingConnectors.contains(lastWord.lowercased()) {
            text = String(text.dropLast(lastWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            repaired = true
            if text.isEmpty { break }
        }

        guard !text.isEmpty else { return fallback }
        // If we removed a dangling tail, the remaining stem is a question — terminate it.
        return repaired ? text + "?" : text
    }

    /// A5: optional one-tap answer choices the agent supplied (nil if none). Blank/whitespace
    /// entries are dropped so they don't render as dead, inert chips.
    static func extractOptions(_ arguments: [String: JSONValue]) -> [String]? {
        let opts = arguments["options"]?.arrayValue?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return opts.isEmpty ? nil : opts
    }

    /// A5: whether the agent expects a long / multi-line answer. Coerces the loose encodings weak
    /// models emit — bool `true`, string `"1"`/`"true"`/`"yes"`, or a non-zero number — not just `.bool`.
    static func extractMultiline(_ arguments: [String: JSONValue]) -> Bool {
        guard let value = arguments["multiline"] else { return false }
        if let b = value.boolValue { return b }
        if let s = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return ["1", "true", "yes", "y"].contains(s)
        }
        if let i = value.intValue { return i != 0 }
        return false
    }
}

// MARK: - final_answer Handling

/// Hard cap on final_answer length. 32K chars ≈ 8K tokens — well beyond any
/// reasonable user-facing response. Longer outputs indicate the model is
/// dumping raw tool output into `answer`, which should be summarized instead.
private let finalAnswerMaxChars = 32_000

/// Builds the terminal observation for a `final_answer` call. Invalid input yields a non-terminal failure observation
/// so the loop continues and the model can retry; success yields a terminal one the executor breaks on.
private func buildFinalAnswerObservation(
    call: PendingToolCall,
    currentIteration: Int,
    iterationSpan: TraceContext,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) throws -> ToolObservation {

    let paramsString = serializeToolParams(call.arguments)

    // Accept common aliases models reach for when they forget the schema.
    let answerAliases = ["answer", "response", "content", "text", "message", "final_answer"]
    var rawAnswer: String = ""
    for key in answerAliases {
        if let value = call.arguments[key]?.stringValue, !value.isEmpty {
            rawAnswer = value
            break
        }
    }

    let trimmed = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)

    // Emit standard UI events so the timeline shows the exit action.
    continuation.yield(.toolCall(name: "final_answer", params: paramsString, stepId: currentIteration))
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .acting(.tool(name: "final_answer")),
        content: "Composing final answer...",
        metadata: ["tool_name": "final_answer"]
    ))

    // Empty or whitespace answer: not terminal, so the model retries (this counts against maxIterations).
    if trimmed.isEmpty {
        let errMsg = "ERROR: final_answer requires a non-empty 'answer' argument. Retry by calling final_answer again with your actual response content."
        let output = ToolOutput(toolName: "final_answer", params: paramsString, output: errMsg, isSuccess: false)
        continuation.yield(.toolFailed(output, category: .invalidArgs))
        logger.warning("final_answer called with empty answer — forcing retry.")
        return ToolObservation(
            stepId: currentIteration,
            toolCallId: call.id,
            toolName: "final_answer",
            result: errMsg,
            summary: "final_answer rejected: empty answer.",
            isSuccess: false,
            params: paramsString,
            output: errMsg,
            artifacts: [],
            isTerminalSignal: false,
            terminalKind: nil,
            failureCategory: .invalidArgs
        )
    }

    // --- Validation: over-long ---
    if trimmed.count > finalAnswerMaxChars {
        let errMsg = "ERROR: final_answer 'answer' exceeds \(finalAnswerMaxChars) chars (\(trimmed.count) received). Summarize instead of dumping raw tool output. Retry with a concise response."
        let output = ToolOutput(toolName: "final_answer", params: paramsString, output: errMsg, isSuccess: false)
        continuation.yield(.toolFailed(output, category: .invalidArgs))
        logger.warning("final_answer rejected — \(trimmed.count) chars exceeds cap of \(finalAnswerMaxChars).")
        return ToolObservation(
            stepId: currentIteration,
            toolCallId: call.id,
            toolName: "final_answer",
            result: errMsg,
            summary: "final_answer rejected: over cap.",
            isSuccess: false,
            params: paramsString,
            output: errMsg,
            artifacts: [],
            isTerminalSignal: false,
            terminalKind: nil,
            failureCategory: .invalidArgs
        )
    }

    // --- Success: terminal signal ---
    let successOutput = ToolOutput(
        toolName: "final_answer",
        params: paramsString,
        output: "Answer composed (\(trimmed.count) chars).",
        isSuccess: true
    )
    continuation.yield(.toolSucceeded(successOutput, durationMs: 0))
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.finalizing),
        content: "Final answer received — terminating loop.",
        metadata: ["tool_name": "final_answer", "answer_chars": "\(trimmed.count)"]
    ))

    logger.info("🏁 final_answer received (\(trimmed.count) chars). Loop will terminate.")

    return ToolObservation(
        stepId: currentIteration,
        toolCallId: call.id,
        toolName: "final_answer",
        result: trimmed,
        summary: "Final answer composed.",
        isSuccess: true,
        params: paramsString,
        output: trimmed,
        artifacts: [],
        isTerminalSignal: true,
        terminalKind: .finalAnswer
    )
}
