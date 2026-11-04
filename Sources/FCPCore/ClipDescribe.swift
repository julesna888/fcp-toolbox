import Foundation

/// Automatic description of what a clip shows, in Italian, by zero-shot labelling with the CLIP model already installed for
/// «Cerca nei filmati»: a curated vocabulary of short phrases is compared with the frame vectors stored in the index.
/// Everything runs on this Mac. Nothing is written next to the user's clips.
extension Doctor {
    public enum DescribeGroup: String, CaseIterable, Sendable {
        case soggetti, oggetti, luoghi, momento, inquadratura, atmosfera

        /// Words put in front of the phrase for the text encoder only (the description shows the bare phrase).
        var prefix: String {
            switch self {
            case .inquadratura: return "una ripresa video in "
            case .atmosfera: return "una scena con "
            default: return "una foto di "
            }
        }
        /// How many phrases of this group can appear in one description.
        var maxPerClip: Int {
            switch self {
            case .soggetti, .oggetti, .luoghi: return 2
            default: return 1
            }
        }
    }

    public struct DescribeLabel: Equatable, Sendable {
        public let group: DescribeGroup
        public let text: String
        public var prompt: String { group.prefix + text }
    }

    /// The curated Italian vocabulary. Changing it (any character) invalidates the cached text vectors.
    public static let describeVocabulary: [DescribeLabel] = {
        let table: [(DescribeGroup, String)] = [
            (.soggetti, "persona,due persone,gruppo di persone,folla,persona che cammina,persona che corre,persona che parla alla camera,intervista,persona seduta,persona che sorride,persona che balla,persona che cucina,persona al telefono,persona che lavora al computer,persona che guida,persona che scrive,persona che legge,persona che applaude,donna,uomo,bambino,bambini che giocano,ragazzi,anziano,coppia,famiglia,persona di spalle,mani,volto,sagoma di una persona,pubblico,musicista,cantante,chitarrista,batterista,DJ,concerto,band sul palco,atleta,calciatore,ciclista,nuotatore,persona che fa yoga,persona che fa surf,persona che scia,cane,gatto,cavallo,uccello,pesce,animale,mucche,insetto,persona con la mascherina,commessa o cassiere,cameriere,cuoco,medico,operaio,studente,insegnante,sposi,matrimonio,festa,persone a tavola,persone che brindano,manifestazione,fotografo,persona con la videocamera,persone in riunione,presentatore,persona che gioca ai videogiochi,ballerino,persona che fa shopping"),
            (.oggetti, "automobile,moto,bicicletta,autobus,treno,aereo,elicottero,barca,nave,camion,taxi,monopattino,strada con traffico,telefono,computer portatile,schermo di computer,televisione,schermata di un'app,pagina web,testo sullo schermo,titolo scritto,scritta,logo,cartello stradale,insegna di un negozio,libro,documento,lavagna,fotocamera,microfono,cuffie,strumenti musicali,chitarra,pianoforte,batteria,altoparlanti,luci colorate,palco con luci,proiettore,orologio,gioiello,vestiti,scarpe,borsa,prodotto su sfondo bianco,confezione di un prodotto,bottiglia,bicchiere,tazza di caffè,cibo,piatto di pasta,pizza,dolci,frutta,verdura,carne,pane,colazione,hamburger,vino,birra,cocktail,tavola apparecchiata,cucina,fiori,albero,pianta,fuoco,fumo,candele,palloncini,regali,giocattoli,pallone,attrezzi,macchinario,fabbrica,computer e cavi,telecamera sul treppiede,set cinematografico,sfondo verde,mappa,grafico,tabella,monitor con codice,cartellone pubblicitario,bandiera,specchio,finestra,porta,scale,tetto,ponte,edificio,grattacielo,monumento,chiesa,castello,statua"),
            (.luoghi, "interno di una casa,salotto,camera da letto,cucina di casa,bagno,ufficio,sala riunioni,studio televisivo,studio di registrazione,negozio,supermercato,ristorante,bar,palestra,scuola,università,ospedale,teatro,cinema,stadio,garage,magazzino,laboratorio,stazione,aeroporto,metropolitana,albergo,museo,discoteca,sala concerti,spiaggia,mare,oceano,onde,lago,fiume,cascata,montagna,collina,bosco,foresta,prato,campagna,campo di grano,vigneto,deserto,neve,ghiaccio,cielo,nuvole,grotta,isola,costa con scogliere,porto,città,centro storico,vicolo,piazza,strada,autostrada,quartiere residenziale,periferia,parco,giardino,cortile,terrazza,tetto di un palazzo,skyline di una città,paesaggio,parcheggio,cantiere,campo sportivo,pista da sci,piscina,spazio vuoto,sfondo nero,schermo nero,sfondo di un colore uniforme,sfondo sfocato,sfondo astratto,ambiente interno,ambiente esterno,sotto l'acqua,spazio"),
            (.momento, "alba,giorno,mezzogiorno con sole,pomeriggio,tramonto,crepuscolo,notte,città di notte,luci notturne,cielo stellato,pioggia,temporale,nebbia,cielo nuvoloso,cielo sereno,neve che cade,vento,controluce,sole che sorge,sole che tramonta,luce naturale,luce artificiale,estate,inverno,autunno,primavera"),
            (.inquadratura, "primo piano,primissimo piano,piano medio,campo medio,campo lungo,campo lunghissimo,dettaglio ravvicinato,macro,ripresa dall'alto,ripresa dal drone,ripresa aerea,inquadratura dal basso,inquadratura dall'alto,inquadratura soggettiva,selfie,ripresa fissa con cavalletto,ripresa a mano,ripresa in movimento,movimento di macchina,panoramica,carrellata,ripresa dall'auto,ripresa sott'acqua,ripresa con grandangolo,time-lapse,slow motion,schermo diviso,sfondo sfocato con soggetto a fuoco,inquadratura simmetrica,inquadratura sfocata,ripresa di uno schermo,ripresa di una registrazione dello schermo,ripresa con luce bassa,immagine molto luminosa,immagine molto scura"),
            (.atmosfera, "atmosfera tranquilla,atmosfera rilassata,atmosfera allegra,atmosfera festosa,atmosfera romantica,atmosfera drammatica,atmosfera misteriosa,atmosfera cupa,atmosfera energica,atmosfera elegante,atmosfera industriale,atmosfera professionale,atmosfera familiare,atmosfera sportiva,atmosfera avventurosa,atmosfera malinconica,atmosfera di lusso,atmosfera tecnologica,atmosfera vintage,colori caldi,colori freddi,colori vivaci,colori spenti,bianco e nero,immagine ben illuminata,scena affollata,scena vuota,scena caotica,scena ordinata"),
        ]
        return table.flatMap { g, list in list.split(separator: ",").map { DescribeLabel(group: g, text: String($0)) } }
    }()

    /// JSON given to `clipsearch.py describe`; the script hashes this file to know if its cached text vectors are still valid.
    static func describeVocabularyJSON(_ vocab: [DescribeLabel]) -> Data {
        let arr = vocab.map { ["label": $0.text, "prompt": $0.prompt] }
        return (try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])) ?? Data()
    }

    /// Tuning knobs (see `describeLine`). Scores are CLIP cosines minus the average score of the whole vocabulary for that clip.
    struct DescribeRules: Sendable {
        /// A phrase needs at least this much more than the vocabulary average to count at all.
        var minAboveAverage: Float = 0.035
        /// ...and must stay within this distance of the best phrase of its group.
        var maxBelowGroupBest: Float = 0.012
        /// Absolute floor on the raw CLIP cosine (about 0.2 means unrelated).
        var minRaw: Float = 0.2
        var maxPhrases = 6
    }

    /// Builds the description line from one clip's raw scores (aligned with `vocab`): the best phrase or two of each group,
    /// in the order people, objects, places, time, shot, mood. Nothing convincing gives an empty string.
    static func describeLine(scores: [Float], vocab: [DescribeLabel] = describeVocabulary, rules: DescribeRules = DescribeRules()) -> String {
        guard !scores.isEmpty, scores.count == vocab.count else { return "" }
        let mean = scores.reduce(0, +) / Float(scores.count)
        var parts: [String] = []
        for g in DescribeGroup.allCases {
            let ranked = zip(vocab, scores).filter { $0.0.group == g }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first?.1 else { continue }
            parts += ranked.prefix(g.maxPerClip).filter {
                $0.1 - mean >= rules.minAboveAverage && $0.1 >= rules.minRaw && best - $0.1 <= rules.maxBelowGroupBest
            }.map(\.0.text)
        }
        return parts.prefix(rules.maxPhrases).joined(separator: ", ")
    }

    static func describeCacheURL(_ dir: URL = clipDir) -> URL { dir.appendingPathComponent("vocab_cache.npz") }

    /// Raw scores per clip path, and whether the cached vocabulary vectors were reused. Only for clips that are in the index.
    static func describeScores(paths: [String], indexURL: URL, vocab: [DescribeLabel] = describeVocabulary,
                               cacheURL: URL = describeCacheURL()) -> (scores: [String: [Float]], cached: Bool, problem: String?) {
        guard clipInstalled else { return ([:], false, "La ricerca per contenuto non è ancora installata.") }
        writeClipScript()
        let id = UUID().uuidString
        let vocabFile = fm.temporaryDirectory.appendingPathComponent("fcp-vocab-\(id).json")
        let listFile = fm.temporaryDirectory.appendingPathComponent("fcp-descr-\(id).txt")
        defer { try? fm.removeItem(at: vocabFile); try? fm.removeItem(at: listFile) }  // our own scratch files
        do {
            try describeVocabularyJSON(vocab).write(to: vocabFile)
            try paths.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)
        } catch { return ([:], false, "Non riesco a preparare i file di lavoro.") }
        let r = run(clipPython, [clipDir.appendingPathComponent("clipsearch.py").path, "describe", indexURL.path, vocabFile.path, cacheURL.path, listFile.path])
        guard r.status == 0 else { return ([:], false, "Descrizione non riuscita: \(r.out.suffix(300))") }
        var scores: [String: [Float]] = [:]
        var cached = false
        for line in r.out.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let c = o["cached"] as? Bool { cached = c }
            if let p = o["path"] as? String, let s = o["scores"] as? [Double] { scores[p] = s.map(Float.init) }
        }
        return (scores, cached, nil)
    }

    /// Describes each clip in Italian ("persona, interno di un negozio, primo piano"). Clips not yet in the index are looked at first
    /// (that takes a few seconds per clip). The clips are only read, never modified. Clips that cannot be read are missing from the result.
    public static func clipDescribe(_ clips: [URL], indexURL: URL = clipIndexURL, control: ProxyControl = ProxyControl(),
                                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) -> (descriptions: [URL: String], problem: String?) {
        guard clipInstalled else { return ([:], "La ricerca per contenuto non è ancora installata: installala dallo strumento «Cerca nei filmati».") }
        guard !clips.isEmpty else { return ([:], nil) }
        let idx = clipIndex(files: clips, indexURL: indexURL, control: control, progress: progress)  // skips clips already seen and unchanged
        if let p = idx.problem { return ([:], p) }
        let r = describeScores(paths: clips.map(\.path), indexURL: indexURL)
        if let p = r.problem { return ([:], p) }
        var out: [URL: String] = [:]
        for c in clips { if let s = r.scores[c.path] { out[c] = describeLine(scores: s) } }
        return (out, nil)
    }
}
