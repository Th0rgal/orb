import Foundation
import SwiftUI

/// Pure model mirroring `orb/src/cronSchema.ts`, `orb/src/Controller.tsx`, and `orb/src/ProjectSettings.tsx`.
enum OrbControllerModel {
    enum CronState: String, Equatable, Sendable {
        case running
        case paused
        case attention
        case scheduled
    }

    enum TimelineEntry: Identifiable, Equatable {
        case day(key: String, label: String)
        case run(key: String, run: OrbJSON)
        case steer(key: String, steer: OrbJSON)
        case silent(key: String, runs: [OrbJSON])
        case failed(key: String, runs: [OrbJSON], error: String)

        var id: String {
            switch self {
            case .day(let key, _), .run(let key, _), .steer(let key, _), .silent(let key, _), .failed(let key, _, _):
                return key
            }
        }
    }

    static let noProjectLimit = 0

    static func scheduleExpression(_ raw: OrbJSON) -> String {
        if case .string(let s) = raw { return s }
        guard case .object = raw else { return "" }
        let kind = raw["kind"].text
        if kind == "interval", let mins = raw["minutes"].number.map(Int.init), mins > 0 {
            if mins % 1440 == 0 { return "every \(mins / 1440)d" }
            if mins % 60 == 0 { return "every \(mins / 60)h" }
            return "every \(mins)m"
        }
        if kind == "cron" { return raw["expr"].text }
        if kind == "once" { return raw["run_at"].text }
        return raw["display"].text
    }

    static func continuityEnabled(settings: OrbJSON, job: OrbJSON) -> Bool {
        if case .bool(let flag) = settings["continuity"] { return flag }
        if case .bool(let flag) = job["continuity"] { return flag }
        let ctx = job["context_from"]
        if case .string(let s) = ctx { return s.lowercased() == "self" }
        return ctx.items.contains { $0.text.lowercased() == "self" }
    }

    /// Normalizes `skills` array or legacy singular `skill` string from `settings` then `job` (`orb/src/cronSchema.ts`).
    static func skillsOf(settings: OrbJSON?, job: OrbJSON?) -> [String] {
        for source in [settings, job].compactMap({ $0 }) {
            if case .array(let arr) = source["skills"] {
                return arr.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            let single = source["skill"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !single.isEmpty { return [single] }
        }
        return []
    }

    /// Builds either a full cron creation payload or a changed-fields edit patch (`orb/src/ControllerSettings.tsx`).
    /// Omitting unchanged fields prevents script-only controllers (`prompt == ""`) from failing Core's `prompt cannot be empty` check.
    static func buildCronPatch(
        existingView: OrbJSON?,
        defaultDeliver: String,
        name: String,
        schedule: String,
        prompt: String,
        skills: [String],
        deliver: String,
        model: String,
        reasoningEffort: String,
        continuity: Bool
    ) -> [String: OrbJSON] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeliver = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let view = existingView, view["job"] != .null else {
            var create: [String: OrbJSON] = [
                "name": .string(trimmedName),
                "schedule": .string(trimmedSchedule),
                "prompt": .string(prompt),
                "skills": .array(skills.map(OrbJSON.string)),
                "deliver": .string(trimmedDeliver.isEmpty ? defaultDeliver : trimmedDeliver)
            ]
            if !trimmedModel.isEmpty { create["model"] = .string(trimmedModel) }
            if !trimmedEffort.isEmpty { create["reasoning_effort"] = .string(trimmedEffort) }
            if continuity { create["continuity"] = .bool(true) }
            return create
        }

        let j = view["job"]
        let s = view["settings"] == .null ? j : view["settings"]
        let baseName = j["name"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSchedule = scheduleExpression(j["schedule"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSchedule = rawSchedule.isEmpty ? "every 30m" : rawSchedule
        let basePrompt = s["prompt"].text
        let baseSkills = skillsOf(settings: s, job: j)
        let baseDeliver = (s["deliver"].text.isEmpty ? j["deliver"].text : s["deliver"].text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseModel = s["model"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseEffort = s["reasoning_effort"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseContinuity = continuityEnabled(settings: s, job: j)

        var out: [String: OrbJSON] = [:]
        if trimmedName != baseName { out["name"] = .string(trimmedName) }
        if trimmedSchedule != baseSchedule { out["schedule"] = .string(trimmedSchedule) }
        if prompt != basePrompt { out["prompt"] = .string(prompt) }
        if skills != baseSkills { out["skills"] = .array(skills.map(OrbJSON.string)) }
        if trimmedDeliver != baseDeliver { out["deliver"] = .string(trimmedDeliver) }
        if trimmedModel != baseModel { out["model"] = .string(trimmedModel) }
        if trimmedEffort != baseEffort { out["reasoning_effort"] = .string(trimmedEffort) }
        if continuity != baseContinuity { out["continuity"] = .bool(continuity) }
        return out
    }

    /// Translates `continuity` into Hermes `context_from` without dropping sibling context refs.
    static func hermesPatch(_ patch: [String: OrbJSON], existingJob: OrbJSON? = nil) -> OrbJSON {
        var out = patch
        guard let contVal = out.removeValue(forKey: "continuity"), case .bool(let cont) = contVal else {
            return .object(out)
        }
        var refs: [String] = []
        if let job = existingJob {
            let raw = job["context_from"]
            if case .string(let s) = raw, !s.isEmpty {
                refs = [s]
            } else {
                refs = raw.items.map(\.text).filter { !$0.isEmpty }
            }
        }
        refs.removeAll { $0.lowercased() == "self" }
        if cont { refs.append("self") }
        out["context_from"] = .array(refs.map(OrbJSON.string))
        return .object(out)
    }

    private static let hermesOverrideKeys = [
        "model", "provider", "reasoning_effort", "workdir", "failure_deliver", "continuity"
    ]

    /// Older Hermes REST handlers silently filter execution overrides; detect unretained fields (`orb/src/cronSchema.ts`).
    static func ignoredCronFields(patch: [String: OrbJSON], savedView: OrbJSON) -> [String] {
        let j = savedView["job"]
        let s = savedView["settings"] == .null ? j : savedView["settings"]
        return hermesOverrideKeys.filter { key in
            guard let requestedValue = patch[key] else { return false }
            if key == "continuity" {
                return requestedValue.flag != continuityEnabled(settings: s, job: j)
            }
            let requested = requestedValue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = (s[key].text.isEmpty ? j[key].text : s[key].text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return requested != actual
        }
    }

    static func ignoredCronWarning(patch: [String: OrbJSON], savedView: OrbJSON) -> String? {
        let ignored = ignoredCronFields(patch: patch, savedView: savedView)
        guard !ignored.isEmpty else { return nil }
        return "Hermes did not retain: \(ignored.joined(separator: ", ")). Its cron API needs support for these settings."
    }

    static func cronState(job: OrbJSON?, running: Bool = false) -> CronState {
        guard let job, job != .null else { return .scheduled }
        let enabled = (job["enabled"] == .null) ? true : job["enabled"].flag
        let state = job["state"].text
        if !enabled || state == "paused" { return .paused }
        if running || state == "running" { return .running }
        let streak = Int(job["failure_streak"].number ?? 0)
        let lastStatus = job["last_status"].text
        if streak > 0 || (!lastStatus.isEmpty && lastStatus != "ok") { return .attention }
        return .scheduled
    }

    static func untilLabel(_ iso: String, now: Date = Date()) -> String {
        guard !iso.isEmpty, let target = OrbStyle.parseDate(iso) else { return "" }
        let delta = target.timeIntervalSince(now)
        if delta <= 0 { return "due" }
        let mins = Int((delta / 60.0).rounded())
        if mins < 1 { return "in <1m" }
        if mins < 60 { return "in \(mins)m" }
        return "in \(mins / 60)h \(mins % 60)m"
    }

    static func durationLabel(_ secs: Double?) -> String {
        guard let secs else { return "" }
        let total = max(0, Int(secs.rounded()))
        if total < 60 { return "\(total)s" }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Builds newest-first controller timeline entries, folding consecutive silent or identical failed ticks.
    static func buildEntries(
        runs: [OrbJSON],
        steers: [OrbJSON] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TimelineEntry] {
        struct RawItem {
            let at: String
            let epoch: TimeInterval
            let run: OrbJSON?
            let steer: OrbJSON?
        }
        var items: [RawItem] = []
        for run in runs {
            let at = run["at"].text
            let epoch = OrbStyle.parseDate(at)?.timeIntervalSince1970 ?? 0
            items.append(RawItem(at: at, epoch: epoch, run: run, steer: nil))
        }
        for steer in steers {
            let consumed = steer["consumed_at"].text
            guard !consumed.isEmpty else { continue }
            let epoch = OrbStyle.parseDate(consumed)?.timeIntervalSince1970 ?? 0
            items.append(RawItem(at: consumed, epoch: epoch, run: nil, steer: steer))
        }
        items.sort { $0.epoch > $1.epoch }

        var out: [TimelineEntry] = []
        var currentDay = ""
        for item in items {
            if let d = OrbStyle.parseDate(item.at) {
                let label = dayLabel(for: d, now: now, calendar: calendar)
                if !label.isEmpty && label != currentDay {
                    currentDay = label
                    out.append(.day(key: "day:\(label)", label: label))
                }
            }
            if let steer = item.steer {
                let sid = steer["id"].text.isEmpty ? item.at : steer["id"].text
                out.append(.steer(key: "steer:\(sid)", steer: steer))
                continue
            }
            guard let run = item.run else { continue }
            let rid = run["id"].text.isEmpty ? item.at : run["id"].text
            let status = run["status"].text
            let running = status == "running" || status == "claimed"
            let errText = run["error"].text
            let isFailed = status == "failed" || !errText.isEmpty
            let report = run["report"].text
            if isFailed && !running && report.isEmpty {
                let err = errText.isEmpty ? "failed" : errText
                if case .failed(let key, let prevRuns, let prevErr) = out.last, prevErr == err {
                    out[out.count - 1] = .failed(key: key, runs: prevRuns + [run], error: err)
                } else {
                    out.append(.failed(key: "f:\(rid)", runs: [run], error: err))
                }
            } else if run["silent"].flag && !running && errText.isEmpty {
                if case .silent(let key, let prevRuns) = out.last {
                    out[out.count - 1] = .silent(key: key, runs: prevRuns + [run])
                } else {
                    out.append(.silent(key: "s:\(rid)", runs: [run]))
                }
            } else {
                out.append(.run(key: rid, run: run))
            }
        }
        return out
    }

    static func projectLimitOf(_ grant: OrbJSON?) -> Int? {
        guard let grant, let n = grant["parallel_missions"].number.map(Int.init), n > 0 else {
            return nil
        }
        return n
    }

    static func parseProjectLimit(_ raw: String) -> Result<Int, OrbHTTPError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(noProjectLimit) }
        guard trimmed.allSatisfy(\.isNumber), let n = Int(trimmed), n >= 1 else {
            return .failure(OrbHTTPError(status: 0, detail: "Enter 1 or more, or leave empty for no limit."))
        }
        return .success(n)
    }

    static func steerRunFailureMessage(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = trimmed.isEmpty ? "unknown error" : trimmed
        return "Steer saved, but the controller could not start: \(reason). Use Run now to retry."
    }
}

/// Mobile Project Controller, Scheduled Crons, and Standing Grant page (`OrbProjectPage` → `Controller & crons`).
struct OrbProjectAutomationView: View {
    let project: OrbRow
    enum Tab: String, CaseIterable, Identifiable {
        case controller = "Controller"
        case crons = "Crons"
        case grant = "Grant"
        var id: String { rawValue }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .controller
    @State private var controllerView: OrbJSON?
    @State private var steers: OrbJSON?
    @State private var crons: [OrbJSON] = []
    @State private var cronDefaults: OrbJSON?
    @State private var grant: OrbJSON?
    @State private var limitDraft = ""
    @State private var limitDirty = false
    @State private var limitSaving = false
    @State private var limitSaved = false
    @State private var steerText = ""
    @State private var steerRunNow = true
    @State private var steerSending = false
    @State private var steerError: String?
    @State private var actionBusy: String?
    @State private var editingController = false
    @State private var creatingCron = false
    @State private var expandedSilentKeys: Set<String> = []
    @State private var error: String?

    private var slug: String { project.id }
    private let api = OrbCore.shared

    var body: some View {
        List {
            Section {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if let error, !error.isEmpty {
                Section { OrbNotice(message: error) }
            }

            switch tab {
            case .controller:
                controllerSections
            case .crons:
                cronsSections
            case .grant:
                grantSections
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle("Controller & crons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch tab {
                case .controller:
                    if controllerJob != nil {
                        Button { editingController = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Controller settings")
                    }
                case .crons:
                    Button { creatingCron = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New scheduled cron")
                case .grant:
                    EmptyView()
                }
            }
        }
        .sheet(isPresented: $editingController) {
            OrbCronEditorSheet(
                title: controllerJob == nil ? "Set up controller" : "Controller settings",
                slug: slug,
                existingView: controllerView,
                defaultDeliver: "project:\(slug)",
                allowDelete: controllerJob != nil,
                onSave: { patch in
                    let next = try await api.call(
                        "/api/projects/\(OrbCore.escape(slug))/controller",
                        method: "PUT",
                        body: .object(patch)
                    )
                    controllerView = next
                    return next
                },
                onDelete: {
                    let next = try await api.call(
                        "/api/projects/\(OrbCore.escape(slug))/controller",
                        method: "DELETE"
                    )
                    controllerView = next
                },
                onWarning: { self.error = $0?.isEmpty == true ? nil : $0 }
            )
        }
        .sheet(isPresented: $creatingCron) {
            OrbCronEditorSheet(
                title: "New scheduled cron",
                slug: slug,
                existingView: nil,
                defaultDeliver: (cronDefaults?["deliver"].text.isEmpty == false) ? cronDefaults!["deliver"].text : "local",
                allowDelete: false,
                onSave: { patch in
                    let body = OrbControllerModel.hermesPatch(patch)
                    let created = try await api.call(
                        "/api/projects/\(OrbCore.escape(slug))/crons",
                        method: "POST",
                        body: body
                    )
                    await loadCrons()
                    let cJob = created["job"] == .null ? created : created["job"]
                    return .object(["job": cJob, "settings": cJob])
                },
                onDelete: nil,
                onWarning: { self.error = $0?.isEmpty == true ? nil : $0 }
            )
        }
        .refreshable { _ = await loadAll() }
        .task(id: slug) {
            await Poller.run(every: .seconds(15), while: { scenePhase == .active }) {
                await loadAll()
            }
        }
    }

    private var controllerJob: OrbJSON? {
        guard let view = controllerView, view["job"] != .null else { return nil }
        return view["job"]
    }

    private var controllerRunning: Bool {
        (controllerView?["runs"].items ?? []).contains {
            let st = $0["status"].text
            return st == "running" || st == "claimed"
        }
    }

    @ViewBuilder
    private var controllerSections: some View {
        if controllerView == nil {
            Section {
                HStack(spacing: 8) {
                    OrbRunningDots(size: 10)
                    Text("Loading controller…").foregroundStyle(.secondary)
                }
            }
        } else if let job = controllerJob {
            let state = OrbControllerModel.cronState(job: job, running: controllerRunning)
            Section("Controller") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stateColor(state))
                            .frame(width: 8, height: 8)
                        Text(job["name"].text.isEmpty ? "Project controller" : job["name"].text)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(state.rawValue.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stateColor(state))
                    }
                    let sched = OrbControllerModel.scheduleExpression(job["schedule"])
                    let next = OrbControllerModel.untilLabel(job["next_run_at"].text)
                    Text([sched.isEmpty ? "scheduled" : sched, next.isEmpty ? nil : "next \(next)"]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if Int(job["failure_streak"].number ?? 0) > 0 {
                        Text("\(Int(job["failure_streak"].number ?? 0)) failed in a row")
                            .font(.caption)
                            .foregroundStyle(OrbStyle.warning)
                    }
                    HStack(spacing: 10) {
                        if state == .paused {
                            Button(actionBusy == "resume" ? "Resuming…" : "Resume") {
                                Task { await runControllerAction("resume") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(actionBusy != nil || job["archived"].flag)
                        } else {
                            Button(actionBusy == "pause" ? "Pausing…" : "Pause") {
                                Task { await runControllerAction("pause") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(actionBusy != nil)
                        }
                        Button(actionBusy == "run" ? "Starting…" : "Run now") {
                            Task { await runControllerAction("run") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(actionBusy != nil || controllerRunning || job["archived"].flag)

                        Spacer()
                        Button("Configure") { editingController = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            steerSection
            timelineSection(
                runs: controllerView?["runs"].items ?? [],
                consumedSteers: steers?["recent"].items ?? []
            )
        } else {
            Section("Controller") {
                Text("This project has no controller cron in Hermes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("New scheduled cron…") { creatingCron = true }
            }
            steerSection
        }
    }

    @ViewBuilder
    private var steerSection: some View {
        Section {
            let pending = steers?["pending"].items ?? []
            ForEach(Array(pending.enumerated()), id: \.offset) { _, steer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(controllerRunning ? "Awaiting pickup" : "Next tick")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OrbStyle.warning)
                    Text(steer["body"].text)
                        .font(.footnote)
                }
            }
            TextField("Steer the next tick…", text: $steerText, axis: .vertical)
                .lineLimit(1...5)
                .accessibilityIdentifier("controller.steer-input")
            Toggle("Run controller immediately", isOn: $steerRunNow)
                .font(.subheadline)
            Button(steerSending ? "Sending…" : "Send steer") {
                Task { await sendSteer() }
            }
            .disabled(steerSending || steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let steerError, !steerError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(steerError)
                        .font(.footnote)
                        .foregroundStyle(OrbStyle.error)
                    HStack(spacing: 12) {
                        if controllerJob != nil {
                            Button(actionBusy == "run" ? "Starting…" : "Retry run now") {
                                Task { await runControllerAction("run") }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(actionBusy != nil || controllerRunning)
                        }
                        Button("Dismiss") { self.steerError = nil }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Steer")
        } footer: {
            Text("One-off instructions consumed on the next controller tick.")
        }
    }

    @ViewBuilder
    private func timelineSection(runs: [OrbJSON], consumedSteers: [OrbJSON]) -> some View {
        let entries = OrbControllerModel.buildEntries(runs: runs, steers: consumedSteers)
        Section("Recent ticks") {
            if entries.isEmpty {
                Text("No controller ticks recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                switch entry {
                case .day(_, let label):
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                case .steer(_, let steer):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steer consumed")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(steer["body"].text)
                            .font(.footnote)
                    }
                case .silent(let key, let silentRuns):
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            if !expandedSilentKeys.insert(key).inserted {
                                expandedSilentKeys.remove(key)
                            }
                        } label: {
                            HStack {
                                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                                Text("\(silentRuns.count) silent tick\(silentRuns.count == 1 ? "" : "s")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: expandedSilentKeys.contains(key) ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        if expandedSilentKeys.contains(key) {
                            ForEach(Array(silentRuns.enumerated()), id: \.offset) { _, r in
                                HStack {
                                    Text(shortTime(r["at"].text)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(OrbControllerModel.durationLabel(r["duration_secs"].number)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(r["ctrl"].text.isEmpty ? "nothing new" : r["ctrl"].text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .failed(_, let failedRuns, let err):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(failedRuns.count == 1 ? "Tick failed" : "\(failedRuns.count) ticks failed")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(OrbStyle.error)
                            Spacer()
                            Text(shortTime(failedRuns.first?["at"].text ?? ""))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(err).font(.caption).foregroundStyle(OrbStyle.error)
                    }
                case .run(_, let run):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(shortTime(run["at"].text))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            let dur = OrbControllerModel.durationLabel(run["duration_secs"].number)
                            if !dur.isEmpty {
                                Text("· \(dur)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if run["status"].text == "running" || run["status"].text == "claimed" {
                                Text("Ticking…").font(.caption.weight(.semibold)).foregroundStyle(OrbStyle.success)
                            }
                        }
                        if !run["report"].text.isEmpty {
                            OrbRichText(source: run["report"].text)
                        }
                        if !run["error"].text.isEmpty {
                            Text(run["error"].text).font(.caption).foregroundStyle(OrbStyle.error)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var cronsSections: some View {
        Section {
            if crons.isEmpty {
                Text("No additional scheduled crons bound to \(project.name).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(crons, id: \.selfID) { job in
                NavigationLink {
                    OrbProjectCronDetailView(slug: slug, cronID: job["id"].text, initialJob: job) {
                        Task { await loadCrons() }
                    }
                } label: {
                    let state = OrbControllerModel.cronState(job: job)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(stateColor(state)).frame(width: 7, height: 7)
                            Text(job["name"].text.isEmpty ? job["id"].text : job["name"].text)
                                .font(.subheadline.weight(.medium))
                        }
                        let sched = OrbControllerModel.scheduleExpression(job["schedule"])
                        let next = OrbControllerModel.untilLabel(job["next_run_at"].text)
                        Text([sched.isEmpty ? "scheduled" : sched, state == .paused ? "paused" : (next.isEmpty ? nil : "next \(next)")]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("New scheduled cron…") { creatingCron = true }
        } header: {
            Text("Scheduled crons")
        } footer: {
            Text("Recurring or one-shot Hermes jobs bound to this project.")
        }
    }

    @ViewBuilder
    private var grantSections: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent limit").font(.subheadline)
                    Text("Maximum unfinished missions in \(project.name). Empty for no limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                TextField("No limit", text: Binding(
                    get: { limitDraft },
                    set: { limitDraft = $0; limitDirty = true; limitSaved = false }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
            }
            Button(limitSaving ? "Saving…" : "Save agent limit") {
                Task { await saveProjectLimit() }
            }
            .disabled(limitSaving || !limitDirty)
            if limitSaved {
                Text("Saved.").font(.footnote).foregroundStyle(OrbStyle.success)
            }
        } header: {
            Text("Project concurrency")
        }

        let readOnlyPairs: [(String, String)] = [
            ("Autonomy level", grant?["autonomy_level"].text ?? ""),
            ("Merge authority", grant?["merge_authority"].text ?? ""),
            ("Budget per run", grant?["budget_per_tick"].text ?? ""),
            ("Material bar", grant?["material_bar"].text ?? ""),
            ("Pause reason", grant?["pause_reason"].text ?? ""),
            ("Resume condition", grant?["resume_condition"].text ?? "")
        ].filter { !$0.1.isEmpty }

        if !readOnlyPairs.isEmpty {
            Section("Standing authority") {
                ForEach(readOnlyPairs, id: \.0) { label, value in
                    LabeledContent(label, value: value)
                }
            }
        }
    }

    private func stateColor(_ state: OrbControllerModel.CronState) -> Color {
        switch state {
        case .running: return OrbStyle.success
        case .paused: return .secondary
        case .attention: return OrbStyle.warning
        case .scheduled: return .blue
        }
    }

    private func shortTime(_ iso: String) -> String {
        guard let date = OrbStyle.parseDate(iso) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    @discardableResult
    private func loadAll() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await loadController() }
            group.addTask { await loadCrons(); return true }
            group.addTask { await loadGrant(); return true }
            var ok = true
            for await r in group where !r { ok = false }
            return ok
        }
    }

    @discardableResult
    private func loadController() async -> Bool {
        do {
            controllerView = try await api.call("/api/projects/\(OrbCore.escape(slug))/controller?limit=40")
            steers = try? await api.call("/api/projects/\(OrbCore.escape(slug))/steers")
            error = nil
            return true
        } catch is CancellationError {
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func loadCrons() async {
        if let raw = try? await api.call("/api/projects/\(OrbCore.escape(slug))/crons") {
            crons = raw["jobs"].items
        }
        cronDefaults = try? await api.call("/api/projects/\(OrbCore.escape(slug))/crons/defaults")
    }

    private func loadGrant() async {
        guard let raw = try? await api.call("/api/projects/\(OrbCore.escape(slug))/grant") else { return }
        let g = raw["grant"]
        grant = g
        if !limitDirty {
            limitDraft = OrbControllerModel.projectLimitOf(g).map(String.init) ?? ""
        }
    }

    private func runControllerAction(_ action: String) async {
        guard actionBusy == nil else { return }
        actionBusy = action
        defer { actionBusy = nil }
        do {
            let next = try await api.call(
                "/api/projects/\(OrbCore.escape(slug))/controller/action",
                method: "POST",
                body: .object(["action": .string(action)])
            )
            controllerView = next
            error = nil
            if action == "run" { steerError = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendSteer() async {
        let body = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !steerSending else { return }
        steerSending = true
        steerError = nil
        defer { steerSending = false }
        do {
            let next = try await api.call(
                "/api/projects/\(OrbCore.escape(slug))/steers",
                method: "POST",
                body: .object(["body": .string(body), "origin": .string("orb")]),
                headers: ["Idempotency-Key": UUID().uuidString]
            )
            steers = next
            steerText = ""
            if steerRunNow && !controllerRunning && controllerJob != nil {
                do {
                    let updated = try await api.call(
                        "/api/projects/\(OrbCore.escape(slug))/controller/action",
                        method: "POST",
                        body: .object(["action": .string("run")])
                    )
                    if updated["job"] != .null || !updated["runs"].items.isEmpty {
                        controllerView = updated
                    } else {
                        _ = await loadController()
                    }
                } catch {
                    self.steerError = OrbControllerModel.steerRunFailureMessage(error.localizedDescription)
                    _ = await loadController()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveProjectLimit() async {
        switch OrbControllerModel.parseProjectLimit(limitDraft) {
        case .failure(let err):
            self.error = err.localizedDescription
        case .success(let value):
            limitSaving = true
            defer { limitSaving = false }
            do {
                let res = try await api.call(
                    "/api/projects/\(OrbCore.escape(slug))/grant",
                    method: "POST",
                    body: .object(["parallel_missions": .number(Double(value))])
                )
                grant = res["grant"]
                limitDraft = OrbControllerModel.projectLimitOf(grant).map(String.init) ?? ""
                limitDirty = false
                limitSaved = true
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Detail screen for an individual additional scheduled cron (`/api/projects/:slug/crons/:id`).
struct OrbProjectCronDetailView: View {
    let slug: String
    let cronID: String
    let initialJob: OrbJSON
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var job: OrbJSON
    @State private var runs: [OrbJSON] = []
    @State private var busy: String?
    @State private var editing = false
    @State private var error: String?

    init(slug: String, cronID: String, initialJob: OrbJSON, onChanged: @escaping () -> Void) {
        self.slug = slug
        self.cronID = cronID
        self.initialJob = initialJob
        self.onChanged = onChanged
        _job = State(initialValue: initialJob)
    }

    var body: some View {
        let running = runs.contains {
            let st = $0["status"].text
            return st == "running" || st == "claimed"
        }
        let state = OrbControllerModel.cronState(job: job, running: running)
        List {
            if let error {
                Section { OrbNotice(message: error) }
            }
            Section("Schedule") {
                LabeledContent("Schedule", value: OrbControllerModel.scheduleExpression(job["schedule"]).isEmpty ? "scheduled" : OrbControllerModel.scheduleExpression(job["schedule"]))
                LabeledContent("State", value: state.rawValue.capitalized)
                if !job["deliver"].text.isEmpty {
                    LabeledContent("Deliver to", value: job["deliver"].text)
                }
                HStack(spacing: 10) {
                    Button(state == .paused ? "Resume" : "Pause") {
                        Task { await act(state == .paused ? "resume" : "pause") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy != nil)

                    Button("Run now") {
                        Task { await act("run") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy != nil)
                }
            }
            if !job["prompt"].text.isEmpty {
                Section("Instruction") {
                    Text(job["prompt"].text)
                        .font(.system(.footnote, design: .monospaced))
                }
            }
            Section("Recent runs") {
                if runs.isEmpty {
                    Text("No runs recorded yet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(r["at"].text) · \(r["status"].text.isEmpty ? "ok" : r["status"].text)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !r["report"].text.isEmpty {
                            OrbRichText(source: r["report"].text)
                        }
                        if !r["error"].text.isEmpty {
                            Text(r["error"].text).font(.caption).foregroundStyle(OrbStyle.error)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle(job["name"].text.isEmpty ? cronID : job["name"].text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            OrbCronEditorSheet(
                title: "Edit cron",
                slug: slug,
                existingView: .object(["job": job, "settings": job, "runs": .array(runs)]),
                defaultDeliver: job["deliver"].text.isEmpty ? "local" : job["deliver"].text,
                allowDelete: true,
                onSave: { patch in
                    let body = OrbControllerModel.hermesPatch(patch, existingJob: job)
                    let updated = try await OrbCore.shared.call(
                        "/api/projects/\(OrbCore.escape(slug))/crons/\(OrbCore.escape(cronID))",
                        method: "PATCH",
                        body: body
                    )
                    let savedJob = updated["job"] == .null ? job : updated["job"]
                    job = savedJob
                    if !updated["runs"].items.isEmpty { runs = updated["runs"].items }
                    onChanged()
                    return .object(["job": savedJob, "settings": savedJob, "runs": .array(runs)])
                },
                onDelete: {
                    _ = try await OrbCore.shared.call(
                        "/api/projects/\(OrbCore.escape(slug))/crons/\(OrbCore.escape(cronID))",
                        method: "DELETE"
                    )
                    onChanged()
                    dismiss()
                },
                onWarning: { self.error = $0?.isEmpty == true ? nil : $0 }
            )
        }
        .refreshable { _ = await load() }
        .task(id: cronID) {
            await Poller.run(every: .seconds(15), while: { scenePhase == .active }) {
                await load()
            }
        }
    }

    @discardableResult
    private func load() async -> Bool {
        do {
            let data = try await OrbCore.shared.call("/api/projects/\(OrbCore.escape(slug))/crons/\(OrbCore.escape(cronID))")
            if data["job"] != .null { job = data["job"] }
            runs = data["runs"].items
            error = nil
            return true
        } catch is CancellationError {
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func act(_ action: String) async {
        busy = action
        defer { busy = nil }
        do {
            _ = try await OrbCore.shared.call(
                "/api/projects/\(OrbCore.escape(slug))/crons/\(OrbCore.escape(cronID))/action",
                method: "POST",
                body: .object(["action": .string(action)])
            )
            await load()
            onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shared create/edit sheet for a project controller or additional scheduled cron.
struct OrbCronEditorSheet: View {
    let title: String
    let slug: String
    let existingView: OrbJSON?
    let defaultDeliver: String
    let allowDelete: Bool
    let onSave: ([String: OrbJSON]) async throws -> OrbJSON
    let onDelete: (() async throws -> Void)?
    var onWarning: ((String?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var baseView: OrbJSON?
    @State private var didPopulate = false
    @State private var name = ""
    @State private var schedule = "every 30m"
    @State private var prompt = ""
    @State private var deliver = ""
    @State private var skillsText = ""
    @State private var model = ""
    @State private var reasoningEffort = ""
    @State private var continuity = false
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var error: String?

    private static let presets = ["every 15m", "every 30m", "every 1h", "every 6h", "every 1d", "0 9 * * *"]

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(OrbStyle.error) }
                }
                Section("Schedule") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("every 30m or 0 9 * * *", text: $schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.self) { preset in
                                Button(preset) { schedule = preset }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                            }
                        }
                    }
                    TextField("Deliver to (e.g. local or project:\(slug))", text: $deliver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Instruction") {
                    TextEditor(text: $prompt)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 160)
                }
                Section("Skills & overrides") {
                    TextField("Skills (comma-separated)", text: $skillsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model override (optional)", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Reasoning", selection: $reasoningEffort) {
                        Text("Hermes default").tag("")
                        ForEach(["minimal", "low", "medium", "high", "xhigh"], id: \.self) { eff in
                            Text(eff).tag(eff)
                        }
                    }
                    Toggle("Keep context across runs", isOn: $continuity)
                }
                if allowDelete, onDelete != nil {
                    Section {
                        Button("Delete cron…", role: .destructive) { confirmDelete = true }
                            .disabled(saving)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving)
                }
            }
            .alert("Delete this cron?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        guard let onDelete else { return }
                        saving = true
                        defer { saving = false }
                        do {
                            try await onDelete()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the job from Hermes immediately.")
            }
            .onAppear { populate() }
        }
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        baseView = existingView
        guard let view = existingView, view["job"] != .null else {
            if name.isEmpty { name = "\(slug) controller" }
            if deliver.isEmpty { deliver = defaultDeliver }
            return
        }
        applyFields(from: view, keepRejectedOverrides: [])
    }

    private func applyFields(from view: OrbJSON, keepRejectedOverrides ignored: Set<String>) {
        guard view["job"] != .null else { return }
        let j = view["job"]
        let s = view["settings"] == .null ? j : view["settings"]
        name = j["name"].text
        let sched = OrbControllerModel.scheduleExpression(j["schedule"])
        schedule = sched.isEmpty ? "every 30m" : sched
        prompt = s["prompt"].text
        deliver = s["deliver"].text.isEmpty ? j["deliver"].text : s["deliver"].text
        skillsText = OrbControllerModel.skillsOf(settings: s, job: j).joined(separator: ", ")
        if !ignored.contains("model") { model = s["model"].text }
        if !ignored.contains("reasoning_effort") { reasoningEffort = s["reasoning_effort"].text }
        if !ignored.contains("continuity") {
            continuity = OrbControllerModel.continuityEnabled(settings: s, job: j)
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeBase = baseView ?? existingView
        let isEditing = activeBase != nil && activeBase?["job"] != .null
        let existingSettings: OrbJSON? = {
            guard let view = activeBase else { return nil }
            return view["settings"] == .null ? view["job"] : view["settings"]
        }()
        let hasScript = !(existingSettings?["script"].text ?? "").isEmpty
        let basePrompt = existingSettings?["prompt"].text ?? ""
        if trimmedName.isEmpty
            || trimmedSchedule.isEmpty
            || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!hasScript || prompt != basePrompt))
        {
            error = "Name, schedule, and instruction are required."
            return
        }
        let skills = skillsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let patch = OrbControllerModel.buildCronPatch(
            existingView: activeBase,
            defaultDeliver: defaultDeliver,
            name: trimmedName,
            schedule: trimmedSchedule,
            prompt: prompt,
            skills: skills,
            deliver: deliver,
            model: model,
            reasoningEffort: reasoningEffort,
            continuity: continuity
        )
        if isEditing && patch.isEmpty {
            dismiss()
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let savedView = try await onSave(patch)
            let ignored = OrbControllerModel.ignoredCronFields(patch: patch, savedView: savedView)
            if savedView["job"] != .null {
                baseView = savedView
            }
            if let warning = OrbControllerModel.ignoredCronWarning(patch: patch, savedView: savedView) {
                if isEditing {
                    applyFields(from: savedView, keepRejectedOverrides: Set(ignored))
                    self.error = warning
                    return
                }
                onWarning?(warning)
            } else {
                onWarning?(nil)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
