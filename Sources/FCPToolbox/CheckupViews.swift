import AppKit
import FCPCore
import SwiftUI

/// "Is this Mac ready for a long edit?": space, memory, power, heat, and apps worth closing.
struct PreflightView: View {
    @EnvironmentObject var model: Model
    @State private var checks: [PreflightCheck] = []
    @State private var closable: [RunningProcess] = []
    @State private var finalCutRunning = false
    @State private var loading = false
    @State private var asking: RunningProcess?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(spacing: 0) {
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: c.level == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.level == .ok ? Theme.green : Theme.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(c.title)).font(.headline)
                                Text(L(c.detail)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if c.id != checks.last?.id { Divider() }
                    }
                }
                .card()
                if !closable.isEmpty { appsCard }
            }
            .padding(16)
        }
        .navigationTitle(L("Controllo prima di montare"))
        .onAppear { refresh() }
        .toolbar { Button { refresh() } label: { Label(L("Ricontrolla"), systemImage: "arrow.clockwise") } }
        .confirmationDialog(LF("Chiudere %@?", asking?.name ?? ""), isPresented: Binding(
            get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
            Button(LF("Chiudi %@", asking?.name ?? "")) {
                if let p = asking { NSRunningApplication(processIdentifier: p.pid)?.terminate() }
                asking = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
            }
        } message: {
            Text(L("È una chiusura normale: se c'è lavoro non salvato, l'app te lo chiede."))
        }
    }

    private var header: some View {
        let warns = checks.filter { $0.level == .warn }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(loading ? L("Controllo…") : warns == 0 ? L("Pronto per montare") : "\(warns) \(warns == 1 ? L("cosa da sistemare") : L("cose da sistemare"))")
                .font(.title2.bold())
            Text(finalCutRunning ? L("Final Cut Pro è aperto.") : L("Final Cut Pro è chiuso.")).foregroundStyle(.secondary)
        }
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("App che occupano memoria")).font(.headline)
            ForEach(closable) { p in
                HStack {
                    Text(L(p.name))
                    Spacer()
                    Text(formatBytes(p.rssBytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button(L("Chiudi…")) { asking = p }
                }
            }
            Text(L("Le app di sistema e Final Cut non compaiono qui.")).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func refresh() {
        loading = true
        model.refreshVolumes()
        let low = model.lowSpaceGB
        Task {
            let procs = await Task.detached(priority: .utility) { Doctor.processes() }.value
            let info = ProcessInfo.processInfo
            checks = Doctor.preflight(volumes: model.volumes, lowSpaceGB: low, procs: procs,
                                      totalRAM: info.physicalMemory, lowPower: info.isLowPowerModeEnabled,
                                      thermalSerious: info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
            closable = Doctor.closable(procs)
            finalCutRunning = procs.contains { $0.name == "Final Cut Pro" }
            loading = false
        }
    }
}

/// Final Cut crash reports, grouped: ten crashes with the same cause are one problem, not ten.
struct CrashView: View {
    @State private var groups: [CrashGroup] = []
    @State private var loaded = false
    @State private var copied = false
    @State private var importing = false
    @State private var importNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !loaded {
                    ProgressView()
                } else if groups.isEmpty {
                    ContentUnavailableView(L("Nessun crash di Final Cut"), systemImage: "checkmark.shield",
                        description: Text(L("Buone notizie: Final Cut non si è chiuso da solo. Se succede, i problemi compaiono qui.")))
                } else {
                    Text("\(groups.reduce(0) { $0 + $1.reports.count }) crash, \(groups.count) \(groups.count == 1 ? L("causa") : L("cause"))")
                        .font(.title2.bold())
                    ForEach(Array(groups.enumerated()), id: \.element.id) { card($0.element, previous: $0.offset > 0 ? groups[$0.offset - 1] : nil) }
                }
                if let importNote { Text(L(importNote)).foregroundStyle(.secondary) }
            }
            .padding(16)
        }
        .navigationTitle(L("Diagnosi crash Final Cut"))
        .toolbar { Button { importing = true } label: { Label(L("Importa report…"), systemImage: "square.and.arrow.down") } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { r in
            guard case .success(let u) = r else { return }
            _ = u.startAccessingSecurityScopedResource()
            if let g = Doctor.importCrash(u) {
                if groups.contains(where: { $0.signature == g.signature }) { importNote = "Questo tipo di crash c'è già nell'elenco." }
                else { groups.insert(g, at: 0); loaded = true; importNote = LF("Report importato: %@.", u.lastPathComponent) }
            } else { importNote = LF("Non riesco a leggere %@ come report di crash (.ips).", u.lastPathComponent) }
        }
        .onAppear {
            Task {
                groups = await Task.detached(priority: .utility) { Doctor.crashes() }.value
                loaded = true
            }
        }
    }

    private func card(_ g: CrashGroup, previous: CrashGroup?) -> some View {
        let last = g.reports[0]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(g.signature)).font(.headline)
                Spacer()
                Text("×\(g.reports.count)").font(.title3.bold()).foregroundStyle(Theme.orange)
            }
            Text(LF("Final Cut Pro %@ · %@ · ultimo %@", last.appVersion, last.osVersion, last.date))
                .font(.caption).foregroundStyle(.secondary)
            Text(L(g.note))
            DisclosureGroup(L("Dove è successo")) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(last.topFrames, id: \.self) { Text(L($0)).font(.system(.caption, design: .monospaced)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let previous {
                DisclosureGroup(LF("Differenze rispetto a “%@”", previous.signature)) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Doctor.compare(previous, g), id: \.self) { Text(L($0)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button(L("Copia report tecnico")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Doctor.technicalReport(g, perf: Doctor.perfHistory()), forType: .string)
                }
                .help(L("Include le misure del Mac vicine all'ora del crash, se ci sono"))
                Button(copied ? L("Copiato") : L("Copia testo per l'assistenza")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Doctor.supportText(g), forType: .string)
                    copied = true
                }
                Button(L("Mostra report nel Finder")) { reveal([last.url]) }
                Button(L("Final Cut nell'App Store")) {
                    if let u = URL(string: "macappstore://apps.apple.com/app/id424389933") { NSWorkspace.shared.open(u) }
                }
            }
        }
        .card()
    }
}
