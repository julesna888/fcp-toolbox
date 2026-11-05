import AppKit
import FCPCore
import SwiftUI
import UniformTypeIdentifiers

/// Health score of a library, how the Mac behaves while editing.
struct HealthView: View {
    @EnvironmentObject var model: Model
    @State private var index = 0
    @State private var report: HealthReport?
    @State private var forecast: String?
    @State private var perf: PerfSummary?
    @State private var loading = false
    @State private var perfOn = AutomationRunner.perfMonitorEnabled

    var body: some View {
        if model.realLibraries.isEmpty {
            ContentUnavailableView(L("Nessuna libreria"), systemImage: "heart.text.square",
                description: Text(L("Aggiungi il disco con le tue librerie Final Cut: poi qui vedi quanto sono in salute.")))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let report { indicators(report) }
                    if let forecast { Text(L(forecast)).foregroundStyle(.secondary).card() }
                    perfCard
                }
                .padding(16)
            }
            .navigationTitle(L("Salute libreria"))
            .onAppear { load() }
            .onChange(of: index) { _, _ in load() }
            .toolbar { Button { load() } label: { Label(L("Ricontrolla"), systemImage: "arrow.clockwise") } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.realLibraries.count > 1 {
                Picker(L("Libreria"), selection: $index) {
                    ForEach(Array(model.realLibraries.enumerated()), id: \.offset) { Text(L($0.element.name)).tag($0.offset) }
                }
                .frame(maxWidth: 360)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(loading ? "…" : report.map { "\($0.score)" } ?? "–")
                    .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color(report?.score))
                VStack(alignment: .leading) {
                    Text(loading ? L("Controllo…") : L(report?.label ?? "")).font(.title2.bold())
                    Text(L("voto complessivo su 100")).foregroundStyle(.secondary)
                }
            }
            if let report { Text(L(report.note)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func indicators(_ r: HealthReport) -> some View {
        VStack(spacing: 0) {
            ForEach(r.indicators) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(i.score)).foregroundStyle(color(i.score))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(L(i.name)).font(.headline)
                            Text(LF("peso %@%", i.weight)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L(i.detail)).foregroundStyle(.secondary)
                        if let a = i.advice { Text(L(a)) }
                        if let (tool, label) = fix(for: i) { Button(L(label)) { model.requestedTool = tool } }
                    }
                    Spacer()
                    Text(i.score.map { "\($0)" } ?? "n.d.").font(.title3.bold()).monospacedDigit().foregroundStyle(color(i.score))
                }
                .padding(.vertical, 8)
                if i.id != r.indicators.last?.id { Divider() }
            }
        }
        .card()
    }

    private var perfCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Come va il Mac mentre monti")).font(.headline)
                Spacer()
                Button(L("Misura ora")) {
                    Task {
                        await Task.detached(priority: .utility) { _ = Doctor.sample() }.value
                        load()
                    }
                }
            }
            if let p = perf {
                ForEach(p.findings, id: \.self) { Text("• " + L($0)) }
                if p.findings.isEmpty { Text(LF("Nessun problema ricorrente su %@ misure.", p.samples)).foregroundStyle(.secondary) }
            } else {
                Text(L("Nessuna misura ancora.")).foregroundStyle(.secondary)
            }
            Toggle(L("Misura da sola ogni 5 minuti, solo mentre Final Cut è aperto"), isOn: $perfOn)
                .onChange(of: perfOn) { _, v in AutomationRunner.perfMonitorEnabled = v }
            Text(L("Sono misure del Mac in uso, non un test di velocità di Final Cut.")).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    /// Where to go to fix a problem. Only offered when the indicator is not perfect.
    private func fix(for i: HealthIndicator) -> (Tool, String)? {
        guard let s = i.score, s < 100 else { return nil }
        switch i.name {
        case "Media collegati": return (.missing, "Vedi i media mancanti")
        case "Backup": return (.backup, "Fai un backup")
        case "Spazio libero": return (.cleanup, "Libera spazio")
        case "File rigenerabili": return (.cleanup, "Apri Cache e render")
        default: return nil
        }
    }

    private func color(_ s: Int?) -> Color {
        guard let s else { return .secondary }
        return s >= 85 ? Theme.green : (s >= 60 ? Theme.orange : .red)
    }

    private func icon(_ s: Int?) -> String {
        guard let s else { return "questionmark.circle" }
        return s >= 85 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func load() {
        let libs = model.realLibraries
        guard index < libs.count else { index = 0; return }
        let lib = libs[index]
        loading = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> (HealthReport, String?, PerfSummary?) in
                let r = Doctor.health(of: lib)
                let free = Doctor.probe([lib.url]).free
                let g = Doctor.growth(of: lib.url.path)
                let f = [g.map { LF("Crescita misurata: %@.", L($0.text)) }, free.flatMap { Doctor.predictSpace(free: $0, growth: g) }]
                    .compactMap { $0 }.joined(separator: " ")
                let forecast: String? = f.isEmpty ? nil : f
                let samples = Doctor.perfHistory()
                let p = samples.isEmpty ? nil : Doctor.summarize(samples)
                return (r, forecast, p)
            }.value
            report = result.0; forecast = result.1; perf = result.2
            loading = false
        }
    }
}

/// Switches for the background checks. Everything is off until the master switch is on.
struct AutomationsView: View {
    @State private var config = Doctor.loadAutomationConfig()
    @State private var events: [AutomationEvent] = []
    @State private var checked = false
    @State private var picking = false
    private let profiles = (Doctor.deliveryProfiles + Doctor.loadCustomSpecs()).map(\.name)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Avvisi automatici attivi"), isOn: $config.enabled).font(.title3.bold())
                    Text(L("Ogni 10 minuti controllo le regole accese e ti avviso con una notifica. Gli avvisi non cambiano e non cancellano nessun file. Spente, non faccio niente."))
                        .foregroundStyle(.secondary)
                }
                .card()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L("Avvisami se lo spazio libero scende sotto"), isOn: $config.lowSpace)
                    Stepper(LF("%@ GB", config.lowSpaceGB), value: $config.lowSpaceGB, in: 5...500, step: 5).padding(.leading, 22).disabled(!config.lowSpace)
                    Divider()
                    Toggle(L("Ricordami il backup quando è vecchio di"), isOn: $config.backupReminder)
                    Stepper(LF("%@ giorni", config.backupDays), value: $config.backupDays, in: 1...90).padding(.leading, 22).disabled(!config.backupReminder)
                    Divider()
                    Toggle(L("Avvisami se Final Cut va in crash"), isOn: $config.crashWatch)
                    Divider()
                    Toggle(L("Scrivi un report di salute una volta a settimana"), isOn: $config.weeklyReport)
                    Divider()
                    Toggle(L("Controlla i nuovi export in una cartella"), isOn: Binding(
                        get: { config.deliveryFolder != nil }, set: { on in if on { picking = true } else { config.deliveryFolder = nil } }))
                    if let f = config.deliveryFolder {
                        HStack {
                            Text(L(f)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Picker(L("Profilo"), selection: $config.deliveryProfile) { ForEach(profiles, id: \.self) { Text(L($0)) } }.fixedSize()
                        }
                    }
                }
                .card()
                .disabled(!config.enabled)
                HStack {
                    Button(L("Controlla adesso")) {
                        Task { events = await AutomationRunner.tick(); checked = true }
                    }
                    .disabled(!config.enabled)
                    if checked { Text(events.isEmpty ? L("Tutto a posto.") : LF("%@ avvisi.", events.count)).foregroundStyle(.secondary) }
                }
                ForEach(events, id: \.key) { e in
                    VStack(alignment: .leading, spacing: 2) { Text(L(e.title)).font(.headline); Text(L(e.body)).foregroundStyle(.secondary) }.card()
                }
                // one-time setup, so it lives with the other settings and not under the tools
                QuickActionsCard()
            }
            .padding(16)
        }
        .navigationTitle(L("Avvisi automatici"))
        .onChange(of: config) { old, new in
            Doctor.saveAutomationConfig(new)
            if new.enabled && !old.enabled { AutomationRunner.askPermission() }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { config.deliveryFolder = u.path }
        }
    }
}
