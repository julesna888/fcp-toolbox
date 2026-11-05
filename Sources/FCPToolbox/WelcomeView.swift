import SwiftUI

/// Short guided tour shown on the first launch, and again from the "Guida" button.
struct WelcomeView: View {
    static let seenKey = "welcomeSeen"

    struct Point: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let text: String
    }

    struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let lead: String
        let points: [Point]
    }

    static let slides: [Slide] = [
        Slide(icon: "film.stack", tint: Theme.blue, title: "Benvenuto in FCP Toolbox",
              lead: "Pochi strumenti, tutti per il lavoro di tutti i giorni con Final Cut Pro.",
              points: [
                Point(icon: "eye", title: "Prima guarda", text: "Legge dischi e file senza modificarli."),
                Point(icon: "hand.raised", title: "Poi chiede", text: "Ogni eliminazione ha una conferma e va nel Cestino, recuperabile."),
                Point(icon: "lock.shield", title: "Tutto sul tuo Mac", text: "Niente online, niente account, niente chiavi: gratuito e locale.")]),
        Slide(icon: "sparkles", tint: Theme.green, title: "Libera spazio",
              lead: "Scegli un disco e togli solo i file inutili di Final Cut.",
              points: [
                Point(icon: "checkmark.circle", title: "Sicuro", text: "Render e proxy che Final Cut rigenera, e i backup automatici vecchi (restano gli ultimi 3)."),
                Point(icon: "eye.circle", title: "Da rivedere tu", text: "File di analisi e media che nessuna libreria usa: non selezionati, decidi tu."),
                Point(icon: "trash", title: "Sempre recuperabile", text: "Va nel Cestino. Su un disco esterno lo spazio torna quando lo svuoti.")]),
        Slide(icon: "wrench.and.screwdriver", tint: Theme.green, title: "Strumenti",
              lead: "Trascina un file, premi, ottieni un file nuovo accanto all'originale.",
              points: [
                Point(icon: "film.stack", title: "Prepara il video per montare", text: "I video del telefono non vanno più fuori sincro in Final Cut."),
                Point(icon: "music.note", title: "Estrai o converti l'audio", text: "Prendi l'audio da un video, o cambia formato (MP3, WAV, AAC)."),
                Point(icon: "speaker.wave.2.fill", title: "Sistema il volume per i social", text: "Volume giusto per Instagram e YouTube, l'immagine non cambia."),
                Point(icon: "arrow.down.right.and.arrow.up.left", title: "Rimpicciolisci per inviare", text: "Fa pesare il file meno di 16, 25, 50 o 100 MB per WhatsApp e Telegram."),
                Point(icon: "photo", title: "Copertina", text: "Un fotogramma come JPG per la copertina.")]),
        Slide(icon: "briefcase.fill", tint: Theme.blue, title: "Lavoro",
              lead: "Prima, durante e dopo una sessione di montaggio.",
              points: [
                Point(icon: "tray.and.arrow.down.fill", title: "Ordina cartelle clienti", text: "Trascini la cartella scaricata: la mette in ordine per CLIENTE e video. Final Cut è facoltativo. Le clip puoi farle cancellare dopo 30 giorni (ti avviso prima) o tenerle per sempre."),
                Point(icon: "gauge.with.dots.needle.67percent", title: "Controllo prima di montare", text: "Controlla spazio, memoria e app pesanti. Le chiudi con un clic."),
                Point(icon: "bolt.trianglebadge.exclamationmark", title: "Diagnosi crash Final Cut", text: "Se Final Cut si chiude da solo: raggruppa i problemi, spiega la causa e prepara un messaggio per l'assistenza."),
                Point(icon: "bell.badge", title: "Avvisi automatici", text: "Avvisi su poco spazio, backup vecchio, nuovi crash. Sono spenti finché non li accendi.")]),
        Slide(icon: "film", tint: Theme.orange, title: "Controlla il video finito",
              lead: "Dopo l'export, controlla che il video vada bene prima di pubblicarlo o mandarlo al cliente.",
              points: [
                Point(icon: "checkmark.seal", title: "Controllo consegna", text: "Guarda il file vero e ti dice se va bene per YouTube, Instagram Reels e simili (formato, durata, qualità)."),
                Point(icon: "speaker.wave.2.fill", title: "Volume e silenzi", text: "Ti dice se il volume è giusto per i social e trova i buchi di silenzio all'inizio, alla fine o in mezzo."),
                Point(icon: "play.rectangle", title: "Copie leggere per montare", text: "Crea versioni più leggere dei video, così Final Cut non rallenta su un disco lento.")]),
        Slide(icon: "tray.full", tint: Theme.blue, title: "Il Cesto",
              lead: "L'icona nella barra dei menu in alto.",
              points: [
                Point(icon: "arrow.down.doc", title: "Trascina file sull'icona", text: "Li tieni a portata di mano e li ritrascini fuori quando servono."),
                Point(icon: "bolt.slash", title: "Leggero", text: "A finestra chiusa l'app resta in background senza consumare.")]),
        Slide(icon: "checkmark.seal", tint: Theme.green, title: "Cosa sapere",
              lead: "Limiti onesti.",
              points: [
                Point(icon: "play.rectangle", title: "Copie leggere e file di progetto", text: "L'app li prepara e li controlla, ma solo Final Cut può dirti se li accetta davvero."),
                Point(icon: "questionmark.circle", title: "Primo avvio", text: "Se macOS blocca l'app: tasto destro sull'icona, poi Apri. Puoi rivedere questa guida col pulsante Guida.")])
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var slide: Slide { Self.slides[index] }
    private var last: Bool { index == Self.slides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: slide.icon)
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(slide.tint.gradient, in: RoundedRectangle(cornerRadius: 12))
                Text(L(slide.title)).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(L(slide.lead)).font(.title3).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(slide.points) { p in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: p.icon).font(.title3).foregroundStyle(slide.tint).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(p.title)).font(.headline)
                                Text(L(p.text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        if p.id != slide.points.last?.id { Divider() }
                    }
                }
                .card()
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(index)
            .transition(.opacity)

            Divider()
            HStack {
                Button(L("Salta")) { finish() }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(last ? 0 : 1)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<Self.slides.count, id: \.self) { i in
                        Circle().fill(i == index ? slide.tint : Color.white.opacity(0.2)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel(LF("Slide %@ di %@", index + 1, Self.slides.count))
                Spacer()
                Button(L("Indietro")) { go(-1) }.disabled(index == 0)
                Button(last ? L("Inizia") : L("Avanti")) { last ? finish() : go(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onKeyPress(.rightArrow) { if !last { go(1) }; return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
    }

    private func go(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { index = max(0, min(Self.slides.count - 1, index + d)) }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }
}
