//
//  PaceLMStudioModelLoader.swift
//  leanring-buddy
//
//  Auto-load the planner + optional VLM models into LM Studio at app launch so the
//  user doesn't have to manage LM Studio's state manually.
//
//  - **Load (launch)**: fire a tiny native chat request at LM Studio with
//    the configured `model` field. LM Studio's JIT loading takes that
//    as a hint and loads the model if it isn't already. The same
//    request prefills + warms the model so the user's first PTT turn
//    doesn't pay the cold-load tax (which is typically 5-15s on a
//    14B class model).
//
//  Gated on configuration: only models actually served by LM Studio (a planner
//  or screen-analysis endpoint on port 1234) are warmed or kept alive, and the
//  keepalive only runs once LM Studio has answered. With the planner on Ollama
//  and screen analysis off (or LM Studio not running), this sends nothing.
//
//  Failures are non-fatal: if LM Studio is offline at launch, Pace
//  starts anyway and the first voice turn will hit the existing error path.
//  LM Studio remains the owner of model unloading; Pace must not unload a
//  shared model during quit because a quick restart may already be using it.
//

import Foundation

enum PaceLMStudioModelLoader {
    // LM Studio currently binds IPv4 on the dogfood setup. Using the numeric
    // loopback avoids URLSession retrying ::1 several times before falling
    // through to 127.0.0.1, which added seconds to every turn.
    private static let lmStudioBaseURL = URL(string: "http://127.0.0.1:1234")!
    private static let warmupTimeoutSeconds: TimeInterval = 120

    /// How often the keepalive pings each configured model. LM Studio's
    /// idle-auto-unload defaults vary by version and user setting; 60s
    /// is short enough to beat any default we've seen and infrequent
    /// enough to add ~zero perceptible CPU/GPU load. Each ping is a
    /// `max_tokens: 1` chat completion that costs the model less than
    /// a real turn's prefill.
    private static let keepaliveIntervalSeconds: TimeInterval = 60

    /// The running keepalive task. Cancelled on app quit (after the
    /// shutdown unload completes). One task drives pings for every
    /// configured model.
    private static var keepaliveTask: Task<Void, Never>?

    // MARK: - Launch: load + warm models

    /// Kick off warmup for the configured planner (and VLM, if
    /// enabled). Fire-and-forget — returns immediately so the rest of
    /// app launch isn't blocked. Pace deliberately does not warm a separate
    /// LM Studio embedding model because that can evict the conversational
    /// model on single-model runtimes.
    /// After warmup finishes, starts the periodic keepalive heartbeat.
    static func warmUpConfiguredModelsAsync() {
        guard !PaceBundledModelsSettings.isUsingMLXInProcessPlanner() else {
            print(
                "🔥 LM Studio warmup: skipped — in-process MLX owns the planner; optional screen analysis loads on demand"
            )
            return
        }
        guard !configuredWarmupTargets().isEmpty else {
            print("🔥 LM Studio warmup: skipped — neither the planner nor screen analysis is configured for LM Studio")
            return
        }
        Task.detached(priority: .userInitiated) {
            let wasLMStudioReachable = await warmUpConfiguredModels()
            // An unreachable LM Studio gets no recurring pings.
            if shouldStartKeepalive(targets: configuredWarmupTargets(), isLMStudioReachable: wasLMStudioReachable) {
                await startKeepaliveLoopIfNotRunning()
            }
        }
    }

    /// Awaitable version for tests / one-shot scripts. Returns whether LM Studio
    /// was reachable; always false when no configured model is served by LM Studio.
    @discardableResult
    static func warmUpConfiguredModels() async -> Bool {
        guard !PaceBundledModelsSettings.isUsingMLXInProcessPlanner() else {
            return false
        }
        let warmupTargets = configuredWarmupTargets()
        guard !warmupTargets.isEmpty else {
            return false
        }
        print(
            "🔥 LM Studio warmup: starting (planner=\(warmupTargets.plannerModelIdentifier ?? "not on LM Studio"), vlm=\(warmupTargets.vlmModelIdentifier ?? "not on LM Studio"))"
        )

        guard await isLMStudioReachable() else {
            print(
                "⚠️  LM Studio warmup: server unreachable at 127.0.0.1:1234. Start LM Studio and ensure JIT loading is on."
            )
            return false
        }

        // Resolve the planner identifier against what's actually
        // loaded in LM Studio. If the configured model isn't there,
        // the resolver picks the smallest available chat model and
        // caches that for the rest of the session — every subsequent
        // LocalPlannerClient picks it up via PacePlannerModelResolver
        // .resolvedIdentifier instead of 404ing.
        var plannerModelIdentifier: String?
        if let configuredPlannerIdentifier = warmupTargets.plannerModelIdentifier {
            plannerModelIdentifier = await PacePlannerModelResolver.resolveAndCache(
                configuredIdentifier: configuredPlannerIdentifier,
                plannerBaseURL: lmStudioBaseURL.appendingPathComponent("v1")
            )
        }

        // Run independent model warmups concurrently. When one multimodal
        // model serves both roles, warm it only once; duplicate concurrent
        // requests make LM Studio create a wasteful `:2` instance.
        async let plannerWarmup: Void = {
            guard let plannerModelIdentifier else { return }
            await sendChatCompletionWarmup(
                modelIdentifier: plannerModelIdentifier,
                role: "planner"
            )
        }()
        async let vlmWarmup: Void = {
            guard let vlmModelIdentifier = warmupTargets.vlmModelIdentifier,
                  vlmModelIdentifier != plannerModelIdentifier else { return }
            await sendChatCompletionWarmup(
                modelIdentifier: vlmModelIdentifier,
                role: "VLM"
            )
        }()
        _ = await (plannerWarmup, vlmWarmup)
        print("🔥 LM Studio warmup: complete")
        return true
    }

    // MARK: - Which models LM Studio actually serves

    /// The models this loader may warm and keep alive. A nil identifier means
    /// that role is not served by LM Studio, so it gets no warmup and no pings.
    struct WarmupTargets: Equatable {
        let plannerModelIdentifier: String?
        let vlmModelIdentifier: String?

        var isEmpty: Bool { plannerModelIdentifier == nil && vlmModelIdentifier == nil }
    }

    /// Pure decision: a role is an LM Studio target only when its resolved endpoint
    /// is LM Studio (port 1234) and it is not served in-process. The VLM is dropped
    /// when it is the same model as the planner target (one model, one warmup).
    nonisolated static func warmupTargets(
        plannerBaseURL: URL,
        plannerModelIdentifier: String,
        isPlannerServedInProcess: Bool,
        isScreenAnalysisEnabled: Bool,
        vlmBaseURL: URL,
        vlmModelIdentifier: String,
        isVLMServedInProcess: Bool
    ) -> WarmupTargets {
        let isPlannerOnLMStudio = !isPlannerServedInProcess
            && PaceLocalPlannerBackendSettings.isLMStudioBackend(url: plannerBaseURL)
        let plannerTarget = isPlannerOnLMStudio ? plannerModelIdentifier : nil

        let isVLMOnLMStudio = isScreenAnalysisEnabled
            && !isVLMServedInProcess
            && PaceLocalPlannerBackendSettings.isLMStudioBackend(url: vlmBaseURL)
        let vlmTarget = isVLMOnLMStudio && vlmModelIdentifier != plannerTarget ? vlmModelIdentifier : nil

        return WarmupTargets(plannerModelIdentifier: plannerTarget, vlmModelIdentifier: vlmTarget)
    }

    /// The keepalive only makes sense for models LM Studio serves, and only once
    /// LM Studio has answered; otherwise it would post to a closed port every minute.
    nonisolated static func shouldStartKeepalive(targets: WarmupTargets, isLMStudioReachable: Bool) -> Bool {
        !targets.isEmpty && isLMStudioReachable
    }

    /// `warmupTargets` for the live configuration: the planner endpoint the planner
    /// client resolves, and the screen-analysis endpoint `LocalVLMClient` resolves.
    /// (`InProcessVLMClient` is never available, so only bundled MLX serves the VLM in-process.)
    static func configuredWarmupTargets() -> WarmupTargets {
        warmupTargets(
            plannerBaseURL: PaceLocalPlannerBackendSettings.effectiveBaseURL(),
            plannerModelIdentifier: PaceLocalPlannerBackendSettings.effectiveModelIdentifier(),
            isPlannerServedInProcess: PaceBundledModelsSettings.isUsingMLXInProcessPlanner(),
            isScreenAnalysisEnabled: AppBundleConfiguration
                .stringValue(forKey: "UseLocalVLMForScreenContext")?
                .lowercased() == "true",
            vlmBaseURL: PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL"),
                settingName: "LocalVLMBaseURL"
            ),
            vlmModelIdentifier: AppBundleConfiguration.stringValue(forKey: "LocalVLMModelIdentifier")
                ?? "ui-venus-1.5-2b",
            isVLMServedInProcess: PaceBundledModelsSettings.isUsingMLXInProcessVLM()
        )
    }

    /// Quick reachability check: hit `/v1/models` with a 2-second
    /// timeout. Avoids burning 120 seconds on a `chat/completions`
    /// call to a server that isn't running.
    private static func isLMStudioReachable() async -> Bool {
        let probeURL = lmStudioBaseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let probeSession = URLSession(configuration: probeURLSessionConfiguration())
        defer { probeSession.invalidateAndCancel() }

        do {
            try QEgressBroker.shared.authorize(url: probeURL)
            let (_, response) = try await probeSession.data(for: request, delegate: QEgressRedirectGuard())
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    /// Send a tiny native chat request to load + warm the model. We ask
    /// for a single-token response (`max_tokens: 1`) so the model has
    /// to do its full warm-up cycle but we don't waste time on generation.
    /// The native endpoint's explicit `reasoning: off` contract matters:
    /// the OpenAI-compatible endpoint ignored equivalent template arguments
    /// for Qwen and made this one-token probe take more than ten seconds.
    private static func sendChatCompletionWarmup(modelIdentifier: String, role: String) async {
        let startedAt = Date()
        let warmupURL = nativeChatURL()
        var request = URLRequest(url: warmupURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = warmupTimeoutSeconds

        let requestBody = nativeChatProbeRequestBody(
            modelIdentifier: modelIdentifier,
            input: "ok"
        )

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print(
                "⚠️  LM Studio warmup (\(role)/\(modelIdentifier)): could not encode warmup body: \(error.localizedDescription)"
            )
            return
        }

        let warmupSession = URLSession(configuration: warmupURLSessionConfiguration())
        defer { warmupSession.invalidateAndCancel() }

        do {
            try QEgressBroker.shared.authorize(url: warmupURL)
            let (responseData, urlResponse) = try await warmupSession.data(for: request, delegate: QEgressRedirectGuard())
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                print("⚠️  LM Studio warmup (\(role)/\(modelIdentifier)): non-HTTP response after \(elapsedMs)ms")
                return
            }
            if (200...299).contains(httpResponse.statusCode) {
                print("✅ LM Studio warmup (\(role)/\(modelIdentifier)): ready in \(elapsedMs)ms")
            } else {
                let responseBody =
                    String(data: responseData, encoding: .utf8)?
                    .prefix(200) ?? "<binary>"
                print(
                    "⚠️  LM Studio warmup (\(role)/\(modelIdentifier)) → HTTP \(httpResponse.statusCode) after \(elapsedMs)ms. Body: \(responseBody)"
                )
                if httpResponse.statusCode == 404 {
                    print(
                        "    → Either the model isn't downloaded in LM Studio, or JIT loading is disabled. In LM Studio: Developer → JIT Loading → enable; or pre-load the model in Chat."
                    )
                }
            }
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            print(
                "⚠️  LM Studio warmup (\(role)/\(modelIdentifier)) failed after \(elapsedMs)ms: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Keepalive: prevent idle auto-unload

    /// Start a recurring background task that pings each configured
    /// model every `keepaliveIntervalSeconds`. The ping is a
    /// one-token native chat request — minimal real cost, but enough
    /// activity that LM Studio's idle-unload timer never fires. Without
    /// this, eval runs showed the model state degrading turn-over-turn
    /// because LM Studio was partial-unloading between calls.
    @MainActor
    static func startKeepaliveLoopIfNotRunning() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(keepaliveIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await sendKeepalivePings()
            }
        }
        print("💓 LM Studio keepalive: pings every \(Int(keepaliveIntervalSeconds))s")
    }

    @MainActor
    static func stopKeepaliveLoop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// Issue one keepalive ping per configured model, in parallel.
    /// Failures are silent — the model is either temporarily busy or
    /// has been unloaded by another agent; either way the next ping
    /// will catch it.
    /// Re-checks configuration and reachability every tick, so a role moved off
    /// LM Studio (or an LM Studio that quit) stops receiving pings.
    private static func sendKeepalivePings() async {
        let warmupTargets = configuredWarmupTargets()
        guard !warmupTargets.isEmpty, await isLMStudioReachable() else { return }

        let plannerIdentifier = warmupTargets.plannerModelIdentifier.map { configuredPlannerIdentifier in
            PacePlannerModelResolver.resolvedIdentifier ?? configuredPlannerIdentifier
        }

        async let plannerPing: Void = {
            guard let plannerIdentifier else { return }
            await sendSingleKeepalivePing(modelIdentifier: plannerIdentifier)
        }()
        async let vlmPing: Void = {
            guard let vlmIdentifier = warmupTargets.vlmModelIdentifier,
                  vlmIdentifier != plannerIdentifier else { return }
            await sendSingleKeepalivePing(modelIdentifier: vlmIdentifier)
        }()
        _ = await (plannerPing, vlmPing)
    }

    private static func sendSingleKeepalivePing(modelIdentifier: String) async {
        let keepaliveURL = nativeChatURL()
        var request = URLRequest(url: keepaliveURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let requestBody = nativeChatProbeRequestBody(
            modelIdentifier: modelIdentifier,
            input: "."
        )
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return
        }

        let keepaliveSession = URLSession(configuration: warmupURLSessionConfiguration())
        defer { keepaliveSession.invalidateAndCancel() }
        guard (try? QEgressBroker.shared.authorize(url: keepaliveURL)) != nil else { return }
        _ = try? await keepaliveSession.data(for: request, delegate: QEgressRedirectGuard())
        // Intentionally don't log per-ping — at 1/min for two models
        // that's 2,880 lines a day of console spam for normal idle.
    }

    nonisolated static func nativeChatProbeRequestBody(
        modelIdentifier: String,
        input: String
    ) -> [String: Any] {
        [
            "model": modelIdentifier,
            "input": input,
            "reasoning": "off",
            "store": false,
            "stream": false,
            "max_output_tokens": 1,
            "temperature": 0,
        ]
    }

    private static func nativeChatURL() -> URL {
        lmStudioBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
    }

    // MARK: - URLSession config

    private static func probeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }

    private static func warmupURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = warmupTimeoutSeconds
        configuration.timeoutIntervalForResource = warmupTimeoutSeconds + 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }
}
