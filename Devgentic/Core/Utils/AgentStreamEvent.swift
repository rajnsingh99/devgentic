// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentStreamEvent.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Structured representation of a single reasoning thought for the UI.
struct AgentThought: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    
    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Represents the distinct types of events emitted during an Agent's execution loop.
/// This structured stream allows the UI to render "Thinking", "Artifacts", and "Text" separately.
enum AgentStreamEvent: Sendable {
    
    /// Generic thinking/narration channel: extended-thinking traces, capability progress and executor status.
    /// The model's visible monologue uses `.reasoning`; `sourceNodeID` identifies the emitting workflow node.
    case thought(_ message: String, id: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// The model's visible monologue (`step.reasoning`) produced alongside its tool calls.
    /// Distinct from `.thought`, which carries thinking traces and system narration.
    /// `sourceNodeID` identifies the emitting workflow node.
    case reasoning(_ message: String, id: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// The agent is about to execute tool `name` with the raw JSON `params` (for debugging and visibility).
    /// `sourceNodeID` identifies the invoking workflow node; `stepId` is the ReAct iteration, persisted so a resumed
    /// run can regroup a flat timeline into per-iteration turns.
    case toolCall(name: String, params: String, sourceNodeID: UUID? = nil, stepId: Int? = nil)
    
    /// The agent pauses to ask the user for permission to run a sensitive tool.
    /// `operationID` identifies this human-in-the-loop operation for multi-surface dedup.

    /// Human-readable name of the raising node, shown as the banner title.
    /// Separate from `sourceNodeID`, the approval-scope key, which can name an inner node of a sub-workflow.
    case requestConfirmation(toolName: String, params: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil, sourceNodeName: String? = nil)

    // Why: new associated values must be defaulted and appended: this event suspends the executor, and a swallowed
    // suspending event is a permanent hang because the sub-workflow forwarder ends in `default:`
    /// A workflow Gate node asks the user to pick one of `options`; the choice routes to the matching output port.
    /// `deadline` is the absolute expiry: at expiry the node fails as "Gate expired" and no option port fires.
    case requestGate(prompt: String, options: [String], operationID: UUID = UUID(), deadline: Date? = nil, sourceNodeID: UUID? = nil, inputText: String? = nil, highlights: [RuleMatchSpan] = [], sourceNodeName: String? = nil)

    /// The tool executed successfully. Carries the observation payload for the LLM + UI.
    /// - durationMs: optional wall-clock execution time (from dispatch to completion)
    /// - sourceNodeID: When emitted from a workflow node, identifies which node produced this output.
    case toolSucceeded(ToolOutput, durationMs: Int? = nil, sourceNodeID: UUID? = nil)

    /// The tool failed. `category` drives negative-constraint policy, episodic-memory weighting and UI affordance;
    /// `suggestion` is an optional human-readable remediation hint.
    case toolFailed(ToolOutput, category: ToolFailureCategory, suggestion: String? = nil, sourceNodeID: UUID? = nil)
    
    /// A chunk of the final text response (streaming token).
    /// This is what populates the main chat bubble.
    case content(String)

    /// Provisional, cumulative text of the model step in flight; an empty value withdraws the draft.
    /// Never persisted and always superseded, by `.draftText("")` or by the first `.content`, which replaces it.
    /// Safe to ignore: consumers that drop it still receive every other event unchanged.
    case draftText(String)
    
    /// The agent needs clarification from the user before it can proceed.
    /// - question: The question to display to the user
    /// - operationID: Unique identifier for this HITL operation (for multi-surface dedup)
    case requestClarification(question: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil, options: [String]? = nil, multiline: Bool = false, sourceNodeName: String? = nil)

    /// A terminal error carrying a `StructuredError` (category, message, optional relatedPath/suggestion).
    /// String-literal call sites still compile through `StructuredError`'s literal conformance (`.executionFailed`).
    case error(StructuredError)

    /// A recoverable system-level warning raised during execution; distinct from `.thought` and the terminal `.error`.
    /// `relatedPath` is an optional tool name, iteration id or context identifier the warning pertains to.
    case warning(category: WarningCategory, message: String, relatedPath: String? = nil, sourceNodeID: UUID? = nil)

    // MARK: - Workflow Orchestration Events

    /// A workflow node started. `index` is its 1-based position in execution order out of `total`.
    /// `nodeID` is the canvas node id; `profileName` is the display name of the profile being executed.
    case workflowNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int)

    /// A workflow node has completed execution successfully.
    case workflowNodeCompleted(nodeID: UUID, profileName: String, summary: String, hasWarnings: Bool = false)

    /// A workflow node has failed. `suggestion` carries an optional actionable
    /// remediation hint (derived from the typed `AgentFailureReason`) that the UI
    /// folds into the node's failure detail.
    case workflowNodeFailed(nodeID: UUID, profileName: String, error: String, suggestion: String? = nil)

    // Why: deliberately non-defaulted so the compiler forces every emit site to say whether the node had started;
    // the executor knows it by control flow, the UI could only guess
    /// A workflow node did not run. Not a failure: see `NodeSkipReason`. Emit this, never `workflowNodeFailed`.
    /// `ranBeforeSkip` is true when the node began executing before the skip settled.
    case workflowNodeSkipped(nodeID: UUID, profileName: String, reason: NodeSkipReason, ranBeforeSkip: Bool)

    /// A workflow node was cancelled mid-flight. Distinct from failure: the user asked for it.
    case workflowNodeCancelled(nodeID: UUID, profileName: String)

    // Why: must be delivered before a Stop can arrive: a cancelled consumer throws before switching on any later event,
    // so what the UI must know about a cancelled retry is recorded while the run is healthy
    /// A failed attempt will be retried; emitted before the retry back-off begins.
    /// Carries no delay: the UI must not render "retrying" from it, only mark the row retry-pending (settled as cancelled).
    case workflowNodeRetryScheduled(nodeID: UUID, profileName: String, attemptsRemaining: Int)

    /// Overall workflow progress update.
    case workflowProgress(completed: Int, total: Int)

    /// The run-level verdict on whether any node genuinely failed, distinct from `.executionFinished`'s `outcome`.
    /// `outcome` drives the chat bubble chip and is unchanged; workflow surfaces (run record, Execution view) use this
    /// to report the failure. Yielded once, alongside `.executionFinished(outcome: .completed)`.
    case workflowRunFinished(hadGenuineFailure: Bool)

    // MARK: - Capability Events (Planning, Self-Reflection, Delegation)

    /// Planning capability: a plan has been generated. Carries the full structured plan
    /// so the UI can render a live plan card (step list + statuses), not just a count.
    case planGenerated(subtasks: [SubTask])

    /// Planning capability: the user approved the plan (possibly edited in review).
    /// Carries the FINAL plan that will execute — the UI replaces its step list with
    /// this, since review edits can add/remove/reword steps.
    case planApproved(subtasks: [SubTask])

    /// Planning capability: a subtask has started execution.
    /// - id: the SubTask.id — stable join key for the plan card's step row.
    case subtaskStarted(id: String, index: Int, total: Int, description: String)

    /// Planning capability: a subtask has finished; `durationMs` is the step's wall-clock time.
    /// `outcome` is the inner run's terminal outcome (nil = clean completion assumed): `.completedWithWarnings` marks a
    /// degraded forced-termination step and `.failed` a hard failure.
    case subtaskCompleted(id: String, index: Int, total: Int, summary: String, outcome: ExecutionOutcome? = nil, durationMs: Int? = nil)

    /// Self-Reflection capability: a new trial has started.
    case reflectionTrialStarted(trial: Int, maxTrials: Int)

    /// Self-Reflection capability: evaluating the current trial's output.
    case reflectionEvaluating(trial: Int)

    /// Self-Reflection capability: trial rejected, retrying with critique.
    case reflectionRetrying(trial: Int, critique: String)

    /// Self-Reflection capability: trial accepted, execution complete.
    case reflectionAccepted(trial: Int)

    /// Agent Delegation: a spawned agent has started working on a delegated task.
    case delegationStarted(task: String)

    /// Agent Delegation: a spawned agent has completed its task.
    case delegationCompleted(summary: String)

    // MARK: - Multimodal Events

    /// Long-running media generation progress (e.g., image generation at 45%).
    case mediaProgress(toolName: String, percent: Double, status: String)

    /// A completed media artifact ready for UI rendering.
    case artifactProduced(MediaArtifact)

    // MARK: - Token Usage

    /// Accumulated token usage for the current generation cycle.
    /// Emitted by executors after LLM calls complete.
    case tokenUsage(TokenUsage)

    // MARK: - Plan Review HITL

    /// Planning capability: the generated plan is ready for user review and editing before execution.
    /// Execution is suspended until the user approves, edits or rejects the plan; `operationID` identifies the
    /// human-in-the-loop operation for multi-surface dedup.
    case requestPlanReview(subtasks: [SubTask], operationID: UUID = UUID(), sourceNodeID: UUID? = nil, sourceNodeName: String? = nil)

    // MARK: - History Compaction

    // Why: there is no `compactionStarted` counterpart: a started chip could persist with no terminal row
    /// Background history compaction completed: `turnsCompacted` turns were summarized; `summaryPreview` is ~120 chars.
    /// `checkpoint` is the synthetic `.checkpoint` message, carried across the stream boundary because the backend layer
    /// cannot persist; the UI layer saves it and inserts it into the live history.
    case compactionCompleted(turnsCompacted: Int, summaryPreview: String, checkpoint: ChatMessage)

    /// History compaction failed or timed out; the run continues with uncompacted history.
    /// `reason` is a short, user-facing cause (timeout, empty summary, model unavailable).
    case compactionFailed(reason: String)

    // MARK: - Terminal Outcome

    /// Signals the executor finished with a known outcome; the last meaningful event before `continuation.finish()`.
    /// Lets the final-status indicator distinguish an authoritative answer from a best-effort synthesis or a cancellation.
    case executionFinished(outcome: ExecutionOutcome, reason: String? = nil)
}

// Why: `CaseIterable` cannot be synthesized with an associated-value case; `allCases` is hand-written, excluding `.other`
/// Classification for `.warning` events; drives UI affordance, negative constraints and episodic-memory retrieval.
/// Codable and hand-written `RawRepresentable` so an unrecognised category is preserved, not rejected.
enum WarningCategory: RawRepresentable, Sendable, Codable, Equatable, CaseIterable {
    case retry             // transient network / backend blip — retry in progress
    case throttle          // rate limit hit — backing off
    case memoryPressure    // scratchpad budget utilization high
    case parseFailure      // malformed JSON / XML from model
    case formatCorrection  // model described tool in prose instead of structured call
    case contextPressure   // nearing iteration / compaction threshold
    case circuitBreaker    // repetitive-action / loop safeguard tripping (imminent or already aborted)
    case resourceUnavailable // an attached/upstream file couldn't be read (report-and-skip)
    case midRunError       // a failure the run survived (failed workflow node / planning subtask) — demoted from an `.error` card when prose streamed after it (ASM-1)

    /// A category written by a newer build, carried verbatim.
    case other(String)

    static var allCases: [WarningCategory] {
        [.retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection,
         .contextPressure, .circuitBreaker, .resourceUnavailable, .midRunError]
    }

    init?(rawValue: String) {
        switch rawValue {
        case "retry": self = .retry
        case "throttle": self = .throttle
        case "memoryPressure": self = .memoryPressure
        case "parseFailure": self = .parseFailure
        case "formatCorrection": self = .formatCorrection
        case "contextPressure": self = .contextPressure
        case "circuitBreaker": self = .circuitBreaker
        case "resourceUnavailable": self = .resourceUnavailable
        case "midRunError": self = .midRunError
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .retry: return "retry"
        case .throttle: return "throttle"
        case .memoryPressure: return "memoryPressure"
        case .parseFailure: return "parseFailure"
        case .formatCorrection: return "formatCorrection"
        case .contextPressure: return "contextPressure"
        case .circuitBreaker: return "circuitBreaker"
        case .resourceUnavailable: return "resourceUnavailable"
        case .midRunError: return "midRunError"
        case .other(let raw): return raw
        }
    }

    var displayName: String {
        switch self {
        case .retry:            return "Retry"
        case .throttle:         return "Throttled"
        case .memoryPressure:   return "Memory"
        case .parseFailure:     return "Parse"
        case .formatCorrection: return "Format"
        case .contextPressure:  return "Context"
        case .circuitBreaker:   return "Loop Guard"
        case .resourceUnavailable: return "Attachment"
        case .midRunError:      return "Error"
        // The raw value is the only truthful thing this build knows about the category, and
        // `WarningRow` uppercases whatever it gets — so it reads as a label, not a leak.
        case .other(let raw):   return raw
        }
    }

    /// SF Symbol name for rendering in the timeline.
    var icon: String {
        switch self {
        case .retry:            return "arrow.clockwise"
        case .throttle:         return "hourglass"
        case .memoryPressure:   return "memorychip"
        case .parseFailure:     return "exclamationmark.bubble"
        case .formatCorrection: return "text.badge.xmark"
        case .contextPressure:  return "gauge.with.dots.needle.67percent"
        case .circuitBreaker:   return "arrow.triangle.2.circlepath.circle"
        case .resourceUnavailable: return "doc.badge.exclamationmark"
        case .midRunError:      return "exclamationmark.triangle"
        case .other:            return "exclamationmark.triangle"
        }
    }

    /// Whether a warning of this category raised in a workflow node also bubbles to the workflow-level bubble.
    /// Reserved for categories that put the whole run at risk; transient node-local signals (retries, throttling,
    /// memory pressure) stay on the node timeline.
    var bubblesToWorkflowLevel: Bool {
        switch self {
        case .circuitBreaker, .contextPressure, .midRunError:
            return true
        case .retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection, .resourceUnavailable:
            return false
        // Not promoted: bubbling asserts the whole run is at risk, which cannot be known for an unrecognised category.
        // The warning still renders in the node's own timeline.
        case .other:
            return false
        }
    }
}

/// Terminal outcome of an agent execution, emitted last via `.executionFinished`: `.completed` is an authoritative
/// response, `.failed` a best-effort synthesis after the agent gave up, `.cancelled` the stream stopping mid-flight.
enum ExecutionOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    case completed
    /// Degraded success: the run stopped early (circuit-breaker abort, iteration budget) but
    /// synthesized a usable best-effort answer. Chat shows the answer + an amber chip; a workflow
    /// node COMPLETES (output flows downstream, joins satisfied) instead of hard-failing the run.
    case completedWithWarnings
    case failed
    case cancelled
    /// A time limit ended the run (chat/Code turn, scheduled run); its own status, not `.failed` or cancelled-by-user.
    /// Only ever set on the run's own message; executors and workflow nodes never emit it.
    case timedOut

    var displayName: String {
        switch self {
        case .completed:             return "Completed"
        case .completedWithWarnings: return "Completed with warnings"
        case .failed:                return "Failed"
        case .cancelled:             return "Cancelled"
        case .timedOut:              return "Timed out"
        }
    }

    /// The run did not produce its answer: `.failed` or `.timedOut`. Use this — never `== .failed`
    /// — wherever a failure is rendered, or a timed-out run slips through as a success.
    var isFailureLike: Bool { self == .failed || self == .timedOut }
}

/// Classification for `.toolFailed` events; drives negative-constraint policy, episodic-memory weight and UI affordance.
/// Codable and hand-written `RawRepresentable` so a category written by a newer build is preserved and legible.
/// Encoded as the plain rawValue, so the wire format is the same as a String-raw enum.
enum ToolFailureCategory: RawRepresentable, Sendable, Codable, Equatable, CaseIterable {
    case userDenied          // Ghost Protocol — user explicitly rejected the call
    case permissionRejected  // sandbox / OS-level permission missing
    case executionThrew      // tool's run closure threw (or returned semantic error)
    case timeout             // per-tool timeout deadline exceeded
    case invalidArgs         // preflight argument validation rejected the call
    case notFound            // tool name hallucinated / not in registry
    case cancelled           // user skipped ask_user or task was cancelled mid-flight
    /// A category written by a newer build, carried verbatim.
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "userDenied":         self = .userDenied
        case "permissionRejected": self = .permissionRejected
        case "executionThrew":     self = .executionThrew
        case "timeout":            self = .timeout
        case "invalidArgs":        self = .invalidArgs
        case "notFound":           self = .notFound
        case "cancelled":          self = .cancelled
        default:                   self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .userDenied:         return "userDenied"
        case .permissionRejected: return "permissionRejected"
        case .executionThrew:     return "executionThrew"
        case .timeout:            return "timeout"
        case .invalidArgs:        return "invalidArgs"
        case .notFound:           return "notFound"
        case .cancelled:          return "cancelled"
        case .other(let raw):     return raw
        }
    }

    // Why: `CaseIterable` synthesis breaks once a case carries an associated value, so `allCases` is hand-written
    /// The categories this build knows; `.other` is excluded because it is unbounded.
    static var allCases: [ToolFailureCategory] {
        [.userDenied, .permissionRejected, .executionThrew, .timeout, .invalidArgs, .notFound, .cancelled]
    }

    var displayName: String {
        switch self {
        case .userDenied:         return "Denied"
        case .permissionRejected: return "Permission"
        case .executionThrew:     return "Error"
        case .timeout:            return "Timeout"
        case .invalidArgs:        return "Invalid Args"
        case .notFound:           return "Not Found"
        case .cancelled:          return "Cancelled"
        case .other:              return "Unknown"
        }
    }

    /// SF Symbol name for rendering in the timeline.
    var icon: String {
        switch self {
        case .userDenied:         return "hand.raised.fill"
        case .permissionRejected: return "lock.shield"
        case .executionThrew:     return "exclamationmark.triangle.fill"
        case .timeout:            return "clock.badge.exclamationmark"
        case .invalidArgs:        return "text.badge.xmark"
        case .notFound:           return "questionmark.circle"
        case .cancelled:          return "xmark.circle"
        case .other:              return "exclamationmark.circle"
        }
    }

    // Why: `.other` is soft: a check that cannot answer must not block, and a hard ban on an unrecognised category
    // would be a permanent restriction
    /// Whether failures of this category produce a hard negative constraint (a ban on the tool name).
    /// Soft failures are transient: the agent may retry with different args.
    var producesHardConstraint: Bool {
        switch self {
        case .userDenied, .permissionRejected, .notFound:
            return true
        case .executionThrew, .timeout, .invalidArgs, .cancelled, .other:
            return false
        }
    }

    /// Typed projection into the `ActionStatus` vocabulary used by `MemoryAction` and the episodic XML emitters.
    /// Each case maps 1:1 to an `ActionStatus` failure case; render it for prompts via `actionStatus.xmlValue`.
    var actionStatus: ActionStatus {
        switch self {
        case .userDenied:         return .denied
        case .permissionRejected: return .permissionDenied
        case .executionThrew:     return .failed
        case .timeout:            return .timeout
        case .invalidArgs:        return .invalidArgs
        case .notFound:           return .notFound
        case .cancelled:          return .cancelled
        // Honest generic: it IS a failure, we just cannot say which kind. `.failed` is the
        // vocabulary's own catch-all and is what reaches the episodic XML.
        case .other:              return .failed
        }
    }
}

/// Structured output from a tool execution.
/// Used to render "Artifacts" in the UI (e.g., a file list card).
struct ToolOutput: Sendable, Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let params: String
    let output: String
    let isSuccess: Bool
    /// For file-writing tools: the target file's content captured just before the write ("" if the file did not exist;
    /// nil when not captured: non-file tool, or the file was unreadable or over the snapshot cap).
    /// Powers the timeline's "View changes" diff in the Code Viewer.
    let preWriteContent: String?
    /// For EDIT tools (whose params carry only find/replace strings): the file's content
    /// read back JUST AFTER a successful edit — the post-state the params can't provide.
    /// Nil for full-content writers (their params ARE the post-state) and failures.
    let postWriteContent: String?
    // Why: in-flight only and deliberately not encoded: it joins a live result to a live row; persisted output is already placed
    /// The params the call's timeline row was created with, when they differ from `params` (e.g. edited in the banner).
    /// `ToolRowMatcher` matches on this so the result lands on its own row, never a parallel same-name one.
    let rowParams: String?

    init(id: UUID = UUID(), toolName: String, params: String = "", output: String, isSuccess: Bool, preWriteContent: String? = nil, postWriteContent: String? = nil, rowParams: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.output = output
        self.isSuccess = isSuccess
        self.preWriteContent = preWriteContent
        self.postWriteContent = postWriteContent
        self.rowParams = rowParams
    }

    /// The params that identify this output's timeline row.
    var matchingParams: String { rowParams ?? params }
}

// Backward-compatible Codable: legacy persisted data may lack the `params`,
// `preWriteContent`, and `postWriteContent` fields.
extension ToolOutput: Codable {
    enum CodingKeys: String, CodingKey {
        case id, toolName, params, output, isSuccess, preWriteContent, postWriteContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        toolName = try c.decode(String.self, forKey: .toolName)
        params = try c.decodeIfPresent(String.self, forKey: .params) ?? ""
        output = try c.decode(String.self, forKey: .output)
        isSuccess = try c.decode(Bool.self, forKey: .isSuccess)
        preWriteContent = try c.decodeIfPresent(String.self, forKey: .preWriteContent)
        postWriteContent = try c.decodeIfPresent(String.self, forKey: .postWriteContent)
        rowParams = nil   // in-flight only — see the property
    }
}

/// Severity classification for a tool-confirmation request; drives the banner accent and icon.
enum HITLRiskTier: String, Sendable, Codable, Equatable, CaseIterable {
    case safe        // read-only / idempotent — no state change
    case moderate    // mutates state, generally recoverable
    case destructive // irreversible or high-impact (delete, shell, applescript)

    /// Short banner label.
    var label: String {
        switch self {
        case .safe:        return "Read-only"
        case .moderate:    return "Modifies"
        case .destructive: return "Destructive"
        }
    }

    /// SF Symbol for the risk badge.
    var icon: String {
        switch self {
        case .safe:        return "eye"
        case .moderate:    return "pencil"
        case .destructive: return "exclamationmark.triangle.fill"
        }
    }

    /// Classifies a NATIVE tool name; callers must not pass non-native names.
    /// The HITL enqueue path goes through `ToolRiskResolver.resolve`, which checks `NativeToolCatalog` membership first
    /// and MCP `ToolAnnotations` for server tools. Arbitrary-code tools are derived from `ToolCapability`, not listed here.
    static func classify(toolName: String) -> HITLRiskTier {
        if ToolCapability.executesArbitraryCode(toolName) { return .destructive }

        switch toolName {
        case "delete_file", "batch_move_files",
             // Each of these removes something with no undo: an event, a reminder, a process (SIGKILL), or every tag on a file.
             "delete_calendar_event", "delete_reminder", "kill_process", "replace_finder_tags",
             // Writes instructions injected into every future run of every profile linked to the skill, with no undo.
             // `.destructive` makes `SessionToolApprovals.allow` refuse a durable "allow for this chat" grant.
             "update_skill":
            return .destructive
        case "write_file", "move_file", "copy_file", "create_folder", "watch_folder":
            return .moderate
        case "read_file", "list_directory", "spotlight_search", "read_file_metadata",
             "get_system_stats", "web_search",
             // Read-only tools; `LocalToolManager` defaults them to no confirmation. `git` is read-only by construction:
             // mutating arguments are refused before dispatch.
             "project_tree", "glob_files", "find_definition", "file_overview",
             "code_search_text", "code_search_symbol", "code_search_files",
             "diff_files", "git", "get_task_output":
            return .safe
        default:
            return .moderate
        }
    }
}

/// [HITL] Data Model for the Permission Card
struct PendingToolConfirmation: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let toolName: String
    let params: String
    /// A1: severity tier driving the banner's colour/icon.
    let risk: HITLRiskTier
    /// A1: structured arguments for an expandable, pretty-printed view (nil if `params` wasn't JSON).
    let arguments: JSONValue?
    /// True when `risk` rests on the MCP server's own `ToolAnnotations` claims; the banner appends "(server-declared)".
    /// Optional so persisted confirmations written without it decode as nil.
    var riskIsServerDeclared: Bool?

    init(
        id: UUID = UUID(),
        toolName: String,
        params: String,
        risk: HITLRiskTier = .moderate,
        arguments: JSONValue? = nil,
        riskIsServerDeclared: Bool? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.risk = risk
        self.arguments = arguments
        self.riskIsServerDeclared = riskIsServerDeclared
    }
}

/// Data Model for Agent Clarification Requests
struct PendingClarification: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let question: String
    /// A5: optional suggested answers rendered as one-tap choice buttons (nil/empty = free text).
    let options: [String]?
    /// A5: render a multi-line editor instead of a single-line field.
    let multiline: Bool

    init(id: UUID = UUID(), question: String, options: [String]? = nil, multiline: Bool = false) {
        self.id = id
        self.question = question
        self.options = options
        self.multiline = multiline
    }
}

/// Data Model for Plan Review HITL — the user can edit subtasks before approving.
struct PendingPlanReview: Sendable, Identifiable, Codable, Equatable {
    let id: UUID                // operationID for suspension correlation
    var subtasks: [SubTask]     // mutable — user can edit before approving

    init(id: UUID = UUID(), subtasks: [SubTask]) {
        self.id = id
        self.subtasks = subtasks
    }
}

// Why: offsets are characters against the exact `inputText` carried alongside them; the UI's own joined input differs
// in separator width and in which upstreams it contains
/// A span of the arbitration input that a specific rule matched, so the banner can paint it in that rule's colour.
struct RuleMatchSpan: Sendable, Codable, Equatable, Hashable {
    /// The rule label — matches one of `PendingGate.options`, which is also the button title.
    let label: String
    let start: Int
    let end: Int
}

struct PendingGate: Sendable, Identifiable, Codable, Equatable {
    let id: UUID                // operationID for suspension correlation
    let prompt: String
    let options: [String]       // the choices; each maps to an output port of the same label
    let deadline: Date?         // absolute expiry time for the live countdown (nil = indefinite); expiry fails the node, it never rejects

    /// The text the decision is about: a Router's arbitration input, or a Gate node's upstream input (capped, see
    /// `WorkflowExecutor.gateReviewText`). Carried in the payload rather than re-read anywhere, because `highlights` is
    /// measured against exactly this string. `nil` when there is no input to show.
    let inputText: String?

    /// Which rule matched which part of `inputText`. Empty for a Gate node, and empty for
    /// operators that have no locatable span (`equals` gives only the whole field; `does not
    /// contain` / `is empty` / `always` match by absence or unconditionally).
    let highlights: [RuleMatchSpan]

    init(id: UUID = UUID(), prompt: String, options: [String], deadline: Date? = nil,
         inputText: String? = nil, highlights: [RuleMatchSpan] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.deadline = deadline
        self.inputText = inputText
        self.highlights = highlights
    }
}

// MARK: - Unified HITL Interaction Enum

/// All Human-in-the-Loop interaction types; only one interaction is pending at a time per message.
/// Adding a type means adding a case here; exhaustive switches enforce handling in every consumer.
enum PendingInteraction: Sendable, Codable, Equatable, Identifiable {
    case toolConfirmation(PendingToolConfirmation)
    case clarification(PendingClarification)
    case planReview(PendingPlanReview)
    case gate(PendingGate)

    var id: UUID {
        switch self {
        case .toolConfirmation(let c): return c.id
        case .clarification(let c): return c.id
        case .planReview(let p): return p.id
        case .gate(let g): return g.id
        }
    }

    /// The operation ID used by ExecutionSuspensionService for resume correlation.
    var operationID: UUID { id }

    /// The tool name, if this interaction is a tool confirmation.
    var toolName: String? {
        if case .toolConfirmation(let c) = self { return c.toolName }
        return nil
    }
}

// MARK: - Source-Attributed HITL (InteractionCenter model)

/// Describes WHERE a HITL request originated so a single shared surface can title and route
/// it correctly across the chat, code, and workflow interfaces. Minted at the stream-bridge
/// boundary (`ActiveStreamManager`) where interface mode + workflow node identity are in scope.
struct HITLOrigin: Sendable, Equatable, Codable {
    enum Interface: String, Sendable, Codable {
        case chat, code, workflow, scheduled
    }

    /// Which interface raised the request.
    let interface: Interface
    /// The conversation the request belongs to (filtering + cancel-by-conversation).
    let conversationID: UUID
    /// Workflow node identifier, when `interface == .workflow`; nil otherwise.
    let nodeID: UUID?
    /// Human-readable node / agent name for the banner subtitle (e.g. "Security Agent").
    let nodeName: String?
    /// Banner header text (e.g. "Security Agent · Question" or "Permission required").
    let title: String
    /// The originating agent profile id — lets "Always allow" (A4) flip the tool to auto-approve
    /// in the right profile. nil when unknown.
    let profileID: UUID?

    // Why: `conversationID` says where a banner belongs, not who is asking: a conversation-keyed lookup could post a
    // locally started run's confirmation to a remote chat; this is the agent message id the mirror already holds
    /// The id of the agent message whose run raised this request, i.e. which run is asking.
    /// Nil means raised outside a run (e.g. MCP elicitation); the remote mirror treats it as not attributable and posts it.
    let runMessageID: UUID?

    init(
        interface: Interface,
        conversationID: UUID,
        nodeID: UUID? = nil,
        nodeName: String? = nil,
        title: String,
        profileID: UUID? = nil,
        runMessageID: UUID? = nil
    ) {
        self.interface = interface
        self.conversationID = conversationID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.title = title
        self.profileID = profileID
        self.runMessageID = runMessageID
    }
}

/// A single pending Human-in-the-Loop request, source-attributed and queued by `InteractionCenter`.
/// `id` is the suspension `operationID` that resumes it.
struct PendingHITL: Identifiable, Sendable, Equatable, Codable {
    let id: UUID                  // == operationID
    let origin: HITLOrigin
    let kind: PendingInteraction  // reuses the existing 3-case interaction vocabulary
    let timestamp: Date
    let upstreamNodeNames: [String]   // workflow context; empty for chat / code

    init(
        id: UUID,
        origin: HITLOrigin,
        kind: PendingInteraction,
        timestamp: Date = Date(),
        upstreamNodeNames: [String] = []
    ) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.timestamp = timestamp
        self.upstreamNodeNames = upstreamNodeNames
    }
}
