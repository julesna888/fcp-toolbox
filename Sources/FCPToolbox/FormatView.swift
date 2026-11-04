import FCPCore
import SwiftUI

/// Erases a new external disk and sets it up the way Final Cut likes it.
struct FormatDiskSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [EraseTarget] = []
    @State private var loaded = false
    @State private var selected: String?
    @State private var format: DiskFormat = .apfs
    @State private var name = "Montaggio"
    @State private var confirm = ""
    @State private var working = false
    @State private var result: String?
    @State private var failed = false

    private var target: EraseTarget? { targets.first { $0.id == selected } }
    private var canErase: Bool {
        target != nil && confirm == "CANCELLA" && !Doctor.sanitizedVolumeName(name).isEmpty && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Formatta un disco nuovo").font(.title2.bold())
            if !loaded {
                ProgressView()
            } else if targets.isEmpty {
                Text("Non vedo dischi esterni. Collega l'SSD o l'hard disk e riapri questa finestra. I dischi interni e quello di avvio non compaiono mai qui.")
                    .foregroundStyle(.secondary)
            } else {
                content
            }
            if let result {
                Text(result).foregroundStyle(failed ? Theme.orange : Theme.green).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
        .task { await reload() }
        .onChange(of: selected) { _ in format = target?.recommended ?? .apfs }
    }

    @ViewBuilder private var content: some View {
        Picker("Disco", selection: $selected) {
            ForEach(targets) { t in
                Text("\(t.name) · \(formatBytes(t.size)) · \(t.solidState ? "SSD" : "HDD")").tag(Optional(t.id))
            }
        }
        if let t = target {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.volumes.isEmpty ? "Nessun volume montato." : "Volumi: \(t.volumes.joined(separator: ", "))")
                if t.used > 100_000_000 {
                    Text("Contiene già \(formatBytes(t.used)) di dati. Verranno cancellati per sempre.")
                        .foregroundStyle(Theme.orange).bold()
                } else {
                    Text("Il disco sembra vuoto.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        Picker("Formato", selection: $format) {
            ForEach(DiskFormat.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Text(format.advice).font(.callout).foregroundStyle(.secondary)
        TextField("Nome del disco", text: $name).textFieldStyle(.roundedBorder)
        VStack(alignment: .leading, spacing: 6) {
            Text("Questo cancella TUTTO sul disco e non si può annullare. Il Cestino non c'entra.")
                .foregroundStyle(Theme.orange)
            TextField("Scrivi CANCELLA per confermare", text: $confirm).textFieldStyle(.roundedBorder)
        }
        HStack {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancella e formatta", role: .destructive) { run() }
                .buttonStyle(.borderedProminent).tint(Theme.orange)
                .disabled(!canErase)
        }
    }

    private func reload() async {
        targets = await Task.detached(priority: .userInitiated) { Doctor.eraseCandidates() }.value
        loaded = true
        if !targets.contains(where: { $0.id == selected }) { selected = targets.first?.id }
        format = target?.recommended ?? .apfs
    }

    private func run() {
        guard let t = target else { return }
        let fmt = format, n = name
        working = true
        result = nil
        Task {
            let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                Result { try Doctor.erase(t, as: fmt, name: n) }
            }.value
            working = false
            switch outcome {
            case .success:
                failed = false
                result = "Fatto: “\(Doctor.sanitizedVolumeName(n))” è pronto in \(fmt.title). Puoi usarlo con Final Cut."
                confirm = ""
            case .failure(let e):
                failed = true
                result = e.localizedDescription
            }
            model.refreshVolumes()
            await reload()
        }
    }
}
