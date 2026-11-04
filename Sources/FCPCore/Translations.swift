import Foundation

/// App language. Italian is the source language: the text in the code is the Italian one and
/// `Translations.en` maps it to English, so a missing entry falls back to Italian, never to a blank.
public enum Lang: String, CaseIterable {
    case it, en

    public static let key = "appLanguage"

    /// What the user picked; before any choice, Italian on an Italian Mac and English everywhere else.
    public static var current: Lang {
        get {
            if let s = UserDefaults.standard.string(forKey: key), let l = Lang(rawValue: s) { return l }
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("it") ? .it : .en
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    public var flag: String { self == .it ? "🇮🇹" : "🇬🇧" }
    public var other: Lang { self == .it ? .en : .it }

    /// The text in the current language.
    public static func tr(_ italian: String) -> String {
        current == .en ? (Translations.en[italian] ?? italian) : italian
    }
}

public enum Translations {
    public static let en: [String: String] = [
        // sidebar pages and groups
        "Libera spazio": "Free up space", "Strumenti": "Tools", "Scarica da link": "Download from link",
        "Ordina cartelle clienti": "Sort client folders", "Controllo prima di montare": "Pre-edit check",
        "Diagnosi crash Final Cut": "Final Cut crash diagnosis", "Librerie e progetti": "Libraries and projects",
        "Mappa spazio": "Space map", "Dischi": "Disks", "Backup verificato": "Verified backup",
        "Media mancanti": "Missing media", "Media orfani": "Orphan media", "Cache e render": "Cache and renders",
        "Salute libreria": "Library health", "Avvisi automatici": "Automatic alerts",
        "Controlla il video finito": "Check the finished video", "Gestione media": "Media management",
        "Lavoro": "Work", "Libreria": "Library", "Spazio": "Space", "Media": "Media",
        // tools page
        "Scegli uno strumento, o trascina un file qui sotto e ti propongo cosa fare. Il risultato è sempre un file nuovo accanto all'originale: l'originale non viene toccato.":
            "Pick a tool, or drop a file below and I'll suggest what to do. The result is always a new file next to the original: the original is never touched.",
        "Usati di recente": "Recently used", "Tutti gli strumenti": "All tools",
        "Converti e comprimi": "Convert and compress", "Trasforma un file in un altro: formato, peso, audio, volume.": "Turn a file into another: format, size, audio, volume.",
        "Analizza e cerca": "Analyse and search", "Capire cosa c'è nei filmati, trovare clip e doppioni.": "See what is in your footage, find clips and duplicates.",
        "Prepara e modifica": "Prepare and edit", "Piccoli lavori di emergenza su clip e file.": "Small quick fixes on clips and files.",
        "Automatizza": "Automate", "Tanti file in una volta, con ricette salvate.": "Many files at once, with saved recipes.",
        // tool cards
        "Info file": "File info", "Rinomina in blocco": "Batch rename", "Calcolatore proporzioni": "Aspect ratio calculator",
        "Cambi di inquadratura": "Shot changes", "Foglio provini": "Contact sheet", "Taglia clip": "Trim clip",
        "Pulisci metadata": "Clean metadata", "Colori e palette": "Colours and palette", "Aree sicure social": "Social safe areas",
        "Doppioni": "Duplicates", "Cerca nei filmati": "Search your footage", "Coda di lavori": "Job queue",
        "Preset di lavoro": "Work presets", "Descrivi clip": "Describe clips",
        "Ti dice tutto di un file: quanto dura, che qualità ha, se è adatto a Final Cut.": "Tells you everything about a file: how long it is, its quality, whether it suits Final Cut.",
        "Cambia il nome a tanti file insieme (es. Clip_001, Clip_002…).": "Renames many files at once (e.g. Clip_001, Clip_002…).",
        "Ti dà le misure giuste per Instagram, TikTok, YouTube, senza deformare l'immagine.": "Gives you the right sizes for Instagram, TikTok, YouTube without stretching the picture.",
        "Trova i punti dove cambia l'inquadratura e ti dà l'elenco dei tempi.": "Finds where the shot changes and gives you the list of times.",
        "Crea un'immagine con tanti fotogrammi del video, per vedere tutto in un colpo d'occhio.": "Makes one image with many frames of the video, to see everything at a glance.",
        "Taglia l'inizio e la fine di una clip, senza aprire Final Cut.": "Cuts the start and end of a clip without opening Final Cut.",
        "Toglie da foto e video i dati personali (posizione GPS, telefono usato, autore).": "Removes personal data from photos and videos (GPS position, phone used, author).",
        "Ti dice quali sono i colori principali di un'immagine o di un punto dello schermo.": "Tells you the main colours of an image or of any point on the screen.",
        "Ti mostra le zone dove Instagram, TikTok e YouTube coprono il video con scritte e bottoni.": "Shows where Instagram, TikTok and YouTube cover the video with text and buttons.",
        "Trova i file uguali anche se hanno nomi diversi, così puoi liberare spazio.": "Finds identical files even with different names, so you can free up space.",
        "Scrivi cosa cerchi (es. «persona sulla spiaggia») e trova le clip giuste. Gratis, resta sul Mac.": "Type what you are looking for (e.g. “person on the beach”) and find the right clips. Free, stays on your Mac.",
        "Metti più lavori in fila: li fa uno dopo l'altro, mentre tu fai altro.": "Line up several jobs: it does them one after another while you do something else.",
        "Salva un procedimento (es. «Prepara per Instagram») e applicalo a tanti file in un click.": "Save a procedure (e.g. “Prepare for Instagram”) and apply it to many files in one click.",
        "Scrive in italiano cosa si vede in ogni clip, così le ritrovi. Gratis, resta sul Mac.": "Writes in Italian what is seen in each clip, so you can find them again. Free, stays on your Mac.",
        // conversions
        "Prepara il video per montare": "Prepare the video for editing", "Estrai o converti l'audio": "Extract or convert audio",
        "Sistema il volume per i social": "Fix the volume for social media", "Rimpicciolisci per inviare": "Shrink to send",
        "Copertina da un video": "Cover image from a video",
        "Per i video del telefono che in Final Cut vanno fuori sincro. L'originale resta com'è.": "For phone videos that go out of sync in Final Cut. The original stays as it is.",
        "Prende l'audio da un video, o cambia formato a un file audio (MP3, WAV, AAC).": "Takes the audio from a video, or changes the format of an audio file (MP3, WAV, AAC).",
        "Volume giusto per Instagram e YouTube, né troppo basso né troppo alto. L'immagine non cambia.": "The right volume for Instagram and YouTube, not too quiet or too loud. The picture does not change.",
        "Fa pesare meno il file per mandarlo su WhatsApp, Telegram o email. Scegli tu quanti MB al massimo.": "Makes the file smaller to send on WhatsApp, Telegram or email. You choose the maximum MB.",
        "Salva un'immagine JPG presa a metà del video, per usarla come copertina.": "Saves a JPG taken halfway through the video, to use as a cover.",
        // drop zone and footer
        "Trascina qui qualsiasi file": "Drop any file here",
        "Riconosco il tipo (video, audio, immagine, sottotitoli, cartella) e ti propongo cosa si può fare.": "I recognise the type (video, audio, image, subtitles, folder) and suggest what can be done.",
        "Scegli file o cartelle…": "Choose files or folders…", "Svuota": "Clear",
        "Per questo tipo di file non ho strumenti.": "I have no tools for this type of file.",
        "Altre azioni": "More actions", "Mostra meno": "Show less", "solo per alcuni file": "only for some files",
        "I file non vengono modificati: ogni strumento salva un risultato nuovo. Gli strumenti per un solo file usano il primo.": "Your files are never modified: every tool saves a new result. Tools that work on one file use the first.",
        "Versione": "Version", "Controlla aggiornamenti": "Check for updates", "Controllo…": "Checking…",
        "Cerca strumento": "Search tools", "Guida": "Help",
    ]
}
