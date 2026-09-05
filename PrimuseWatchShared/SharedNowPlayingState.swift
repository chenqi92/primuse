import Foundation

/// Watch app 与 Watch Widget Extension 共享的本地化取串。
///
/// PrimuseKit 不为 watchOS 编译 (`SUPPORTED_PLATFORMS` 不含 watchos)，Watch
/// 端无法走 iOS / tvOS 扩展用的 `PMString`。这里用一张内置 Swift 表覆盖同样的
/// 16 种语言，按系统偏好语言选行，
/// 缺失回退英文，键与 PrimuseKit `Localizable.strings` 里的 `ext.watch.*` 保持
/// 一致，便于将来两边对照。
func WatchString(_ key: String, _ args: CVarArg...) -> String {
    let table = WatchLoc.table(for: WatchLoc.preferredCode)
    let value = table[key] ?? WatchLoc.english[key] ?? key
    guard !args.isEmpty else { return value }
    return String(format: value, arguments: args)
}

enum WatchLoc {
    static var preferredCode: String {
        languageCode(preferredLanguages: Locale.preferredLanguages)
    }

    static func languageCode(preferredLanguages: [String]) -> String {
        for raw in preferredLanguages {
            let components = raw
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
                .split(separator: "-")
            guard let language = components.first else { continue }
            if language == "zh" {
                if components.contains("hant") { return "zh-Hant" }
                if components.contains("hans") { return "zh-Hans" }
                return components.contains(where: { ["tw", "hk", "mo"].contains($0) })
                    ? "zh-Hant" : "zh-Hans"
            }
            switch language {
            case "es": return "es-MX"
            case "pt": return "pt-BR"
            case "de", "fr", "ja", "ko", "en", "ru", "uk", "ar", "hi", "th", "tr", "pl":
                return String(language)
            default: continue
            }
        }
        return "en"
    }

    static func table(for code: String) -> [String: String] {
        switch code {
        case "zh-Hans": return zhHans
        case "zh-Hant": return zhHant
        case "de": return de
        case "fr": return fr
        case "ja": return ja
        case "ko": return ko
        case "ru": return ru
        case "uk": return uk
        case "ar": return ar
        case "es-MX": return esMX
        case "pt-BR": return ptBR
        case "hi": return hi
        case "th": return th
        case "tr": return tr
        case "pl": return pl
        default: return english
        }
    }

    static let english: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "Glance at what's playing now.",
        "ext.watch.demo.track": "Track Name",
        "ext.watch.demo.artist": "Artist",
        "ext.watch.nowPlaying.none": "Nothing playing",
        "ext.watch.nowPlaying.empty.title": "Nothing playing yet",
        "ext.watch.nowPlaying.empty.reachable": "Pick a song on your iPhone to start playing",
        "ext.watch.nowPlaying.empty.unreachable": "Make sure your iPhone is unlocked with Primuse open",
        "ext.watch.queue.title": "Up Next",
        "ext.watch.queue.empty.title": "Queue is empty",
        "ext.watch.queue.empty.subtitle": "Play a song on your iPhone and the queue shows up here",
        "ext.watch.queue.truncationNotice": "Showing first %d of %d songs",
        "ext.watch.radio.live": "LIVE",
        "ext.watch.radio.stop": "Stop",
    ]

    static let zhHans: [String: String] = [
        "ext.watch.appName": "猿音",
        "ext.watch.complication.description": "快速看到正在播放的曲目",
        "ext.watch.demo.track": "曲目名",
        "ext.watch.demo.artist": "艺术家",
        "ext.watch.nowPlaying.none": "暂无播放",
        "ext.watch.nowPlaying.empty.title": "还没有播放",
        "ext.watch.nowPlaying.empty.reachable": "在 iPhone 上选一首歌开始播放",
        "ext.watch.nowPlaying.empty.unreachable": "请确认 iPhone 已解锁并打开猿音",
        "ext.watch.queue.title": "播放列表",
        "ext.watch.queue.empty.title": "队列为空",
        "ext.watch.queue.empty.subtitle": "在 iPhone 上选歌播放后这里会显示队列",
        "ext.watch.queue.truncationNotice": "仅显示前 %d 首，共 %d 首",
        "ext.watch.radio.live": "直播",
        "ext.watch.radio.stop": "停止",
    ]

    static let zhHant: [String: String] = [
        "ext.watch.appName": "猿音",
        "ext.watch.complication.description": "快速看到正在播放的曲目",
        "ext.watch.demo.track": "曲目名",
        "ext.watch.demo.artist": "演出者",
        "ext.watch.nowPlaying.none": "暫無播放",
        "ext.watch.nowPlaying.empty.title": "還沒有播放",
        "ext.watch.nowPlaying.empty.reachable": "在 iPhone 上選一首歌開始播放",
        "ext.watch.nowPlaying.empty.unreachable": "請確認 iPhone 已解鎖並開啟猿音",
        "ext.watch.queue.title": "播放清單",
        "ext.watch.queue.empty.title": "佇列為空",
        "ext.watch.queue.empty.subtitle": "在 iPhone 上選歌播放後這裡會顯示佇列",
        "ext.watch.queue.truncationNotice": "僅顯示前 %d 首，共 %d 首",
        "ext.watch.radio.live": "直播",
        "ext.watch.radio.stop": "停止",
    ]

    static let de: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "Sieh auf einen Blick, was gerade läuft.",
        "ext.watch.demo.track": "Titelname",
        "ext.watch.demo.artist": "Interpret",
        "ext.watch.nowPlaying.none": "Nichts in Wiedergabe",
        "ext.watch.nowPlaying.empty.title": "Noch keine Wiedergabe",
        "ext.watch.nowPlaying.empty.reachable": "Wähle auf dem iPhone einen Titel, um zu starten",
        "ext.watch.nowPlaying.empty.unreachable": "Stelle sicher, dass dein iPhone entsperrt und Primuse geöffnet ist",
        "ext.watch.queue.title": "Als Nächstes",
        "ext.watch.queue.empty.title": "Warteschlange leer",
        "ext.watch.queue.empty.subtitle": "Spiele auf dem iPhone einen Titel, dann erscheint die Warteschlange hier",
        "ext.watch.queue.truncationNotice": "Erste %d von %d Titeln",
        "ext.watch.radio.live": "LIVE",
        "ext.watch.radio.stop": "Stoppen",
    ]

    static let fr: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "Voyez d'un coup d'œil ce qui joue.",
        "ext.watch.demo.track": "Titre du morceau",
        "ext.watch.demo.artist": "Artiste",
        "ext.watch.nowPlaying.none": "Aucune lecture",
        "ext.watch.nowPlaying.empty.title": "Aucune lecture pour l'instant",
        "ext.watch.nowPlaying.empty.reachable": "Choisissez un morceau sur votre iPhone pour commencer",
        "ext.watch.nowPlaying.empty.unreachable": "Assurez-vous que votre iPhone est déverrouillé et Primuse ouvert",
        "ext.watch.queue.title": "À suivre",
        "ext.watch.queue.empty.title": "File d'attente vide",
        "ext.watch.queue.empty.subtitle": "Lancez un morceau sur votre iPhone et la file s'affichera ici",
        "ext.watch.queue.truncationNotice": "%d premiers titres sur %d",
        "ext.watch.radio.live": "EN DIRECT",
        "ext.watch.radio.stop": "Arrêter",
    ]

    static let ja: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "再生中の曲をすばやく確認できます。",
        "ext.watch.demo.track": "曲名",
        "ext.watch.demo.artist": "アーティスト",
        "ext.watch.nowPlaying.none": "再生していません",
        "ext.watch.nowPlaying.empty.title": "まだ再生していません",
        "ext.watch.nowPlaying.empty.reachable": "iPhone で曲を選んで再生を始めましょう",
        "ext.watch.nowPlaying.empty.unreachable": "iPhone のロックを解除し Primuse を開いてください",
        "ext.watch.queue.title": "再生キュー",
        "ext.watch.queue.empty.title": "キューが空です",
        "ext.watch.queue.empty.subtitle": "iPhone で曲を再生するとここにキューが表示されます",
        "ext.watch.queue.truncationNotice": "全 %2$d 曲中、先頭の %1$d 曲を表示",
        "ext.watch.radio.live": "LIVE",
        "ext.watch.radio.stop": "停止",
    ]

    static let ko: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "지금 재생 중인 곡을 한눈에 확인하세요.",
        "ext.watch.demo.track": "곡 제목",
        "ext.watch.demo.artist": "아티스트",
        "ext.watch.nowPlaying.none": "재생 중인 곡 없음",
        "ext.watch.nowPlaying.empty.title": "아직 재생 중인 곡이 없습니다",
        "ext.watch.nowPlaying.empty.reachable": "iPhone에서 곡을 선택해 재생을 시작하세요",
        "ext.watch.nowPlaying.empty.unreachable": "iPhone 잠금을 해제하고 Primuse를 열어 주세요",
        "ext.watch.queue.title": "다음 재생",
        "ext.watch.queue.empty.title": "대기열이 비어 있음",
        "ext.watch.queue.empty.subtitle": "iPhone에서 곡을 재생하면 여기에 대기열이 표시됩니다",
        "ext.watch.queue.truncationNotice": "전체 %2$d곡 중 처음 %1$d곡 표시",
        "ext.watch.radio.live": "라이브",
        "ext.watch.radio.stop": "정지",
    ]

    static let ru: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "Выберите песню на своем iPhone, чтобы начать воспроизведение.",
        "ext.watch.nowPlaying.none": "Ничего не воспроизводится",
        "ext.watch.demo.track": "Название трека",
        "ext.watch.queue.empty.title": "Очередь пуста",
        "ext.watch.nowPlaying.empty.unreachable": "Убедитесь, что ваш iPhone разблокирован, а Primuse открыт.",
        "ext.watch.demo.artist": "Исполнитель",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "Показаны первые %d из %d песен",
        "ext.watch.complication.description": "Посмотрите, что сейчас играет.",
        "ext.watch.nowPlaying.empty.title": "Пока ничего не воспроизводится",
        "ext.watch.queue.empty.subtitle": "Включите песню на своем iPhone, и здесь появится очередь.",
        "ext.watch.queue.title": "Далее",
        "ext.watch.radio.live": "ПРЯМОЙ ЭФИР",
        "ext.watch.radio.stop": "Стоп",
    ]

    static let uk: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "Виберіть пісню на своєму iPhone, щоб почати відтворення",
        "ext.watch.nowPlaying.none": "Нічого не грає",
        "ext.watch.demo.track": "Назва треку",
        "ext.watch.queue.empty.title": "Черга порожня",
        "ext.watch.nowPlaying.empty.unreachable": "Переконайтеся, що iPhone розблоковано, а Primuse відкрито",
        "ext.watch.demo.artist": "Виконавець",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "Показано перші %d із %d пісень",
        "ext.watch.complication.description": "Подивіться, що зараз грає.",
        "ext.watch.nowPlaying.empty.title": "Ще нічого не грає",
        "ext.watch.queue.empty.subtitle": "Відтворіть пісню на iPhone, і тут з’явиться черга",
        "ext.watch.queue.title": "Далі",
        "ext.watch.radio.live": "НАЖИВО",
        "ext.watch.radio.stop": "Стоп",
    ]

    static let ar: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "اختر أغنية على iPhone لبدء التشغيل",
        "ext.watch.nowPlaying.none": "لا توجد موسيقى قيد التشغيل",
        "ext.watch.demo.track": "اسم المسار",
        "ext.watch.queue.empty.title": "قائمة الانتظار فارغة",
        "ext.watch.nowPlaying.empty.unreachable": "تأكد من أن iPhone غير مقفل وأن Primuse مفتوح",
        "ext.watch.demo.artist": "الفنان",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "عرض أول %d من %d أغنية",
        "ext.watch.complication.description": "نظرة سريعة على ما يتم تشغيله الآن.",
        "ext.watch.nowPlaying.empty.title": "لا شيء يشغّل بعد",
        "ext.watch.queue.empty.subtitle": "قم بتشغيل أغنية على iPhone وتظهر قائمة الانتظار هنا",
        "ext.watch.queue.title": "التالي",
        "ext.watch.radio.live": "مباشر",
        "ext.watch.radio.stop": "إيقاف",
    ]

    static let esMX: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "Elige una canción en tu iPhone para comenzar a reproducirla",
        "ext.watch.nowPlaying.none": "No se reproduce nada",
        "ext.watch.demo.track": "Nombre de la pista",
        "ext.watch.queue.empty.title": "La cola está vacía",
        "ext.watch.nowPlaying.empty.unreachable": "Asegúrese de que su iPhone esté desbloqueado con Primuse abierto",
        "ext.watch.demo.artist": "Artista",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "Se muestran las primeras %d de %d canciones",
        "ext.watch.complication.description": "Eche un vistazo a lo que se está reproduciendo ahora.",
        "ext.watch.nowPlaying.empty.title": "Aún no se reproduce nada",
        "ext.watch.queue.empty.subtitle": "Reproduce una canción en tu iPhone y la cola aparece aquí",
        "ext.watch.queue.title": "A continuación",
        "ext.watch.radio.live": "EN VIVO",
        "ext.watch.radio.stop": "Detener",
    ]

    static let ptBR: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "Escolha uma música no seu iPhone para começar a tocar",
        "ext.watch.nowPlaying.none": "Nada tocando",
        "ext.watch.demo.track": "Nome da faixa",
        "ext.watch.queue.empty.title": "A fila está vazia",
        "ext.watch.nowPlaying.empty.unreachable": "Certifique-se de que seu iPhone esteja desbloqueado com o Primuse aberto",
        "ext.watch.demo.artist": "Artista",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "Exibindo as primeiras %d de %d músicas",
        "ext.watch.complication.description": "Dê uma olhada no que está tocando agora.",
        "ext.watch.nowPlaying.empty.title": "Nada tocando ainda",
        "ext.watch.queue.empty.subtitle": "Toque uma música no seu iPhone e a fila aparece aqui",
        "ext.watch.queue.title": "Próximo",
        "ext.watch.radio.live": "AO VIVO",
        "ext.watch.radio.stop": "Parar",
    ]

    static let hi: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "बजाना शुरू करने के लिए अपने iPhone पर एक गाना चुनें",
        "ext.watch.nowPlaying.none": "कुछ नहीं चल रहा",
        "ext.watch.demo.track": "ट्रैक का नाम",
        "ext.watch.queue.empty.title": "कतार खाली है",
        "ext.watch.nowPlaying.empty.unreachable": "सुनिश्चित करें कि आपका iPhone अनलॉक है और Primuse खुला है",
        "ext.watch.demo.artist": "कलाकार",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "%2$d में से पहले %1$d गाने दिखाए जा रहे हैं",
        "ext.watch.complication.description": "अब जो चल रहा है उस पर एक नज़र डालें।",
        "ext.watch.nowPlaying.empty.title": "अभी तक कुछ भी नहीं चल रहा है",
        "ext.watch.queue.empty.subtitle": "अपने iPhone पर एक गाना बजाएं और कतार यहां दिखाई देगी",
        "ext.watch.queue.title": "अगला",
        "ext.watch.radio.live": "लाइव",
        "ext.watch.radio.stop": "बंद करें",
    ]

    static let th: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "เลือกเพลงใน iPhone ของคุณเพื่อเริ่มเล่น",
        "ext.watch.nowPlaying.none": "ยังไม่ได้เล่นเพลง",
        "ext.watch.demo.track": "ชื่อแทร็ก",
        "ext.watch.queue.empty.title": "คิวว่างเปล่า",
        "ext.watch.nowPlaying.empty.unreachable": "ตรวจสอบว่า iPhone ปลดล็อกอยู่และเปิด Primuse ไว้",
        "ext.watch.demo.artist": "ศิลปิน",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "กำลังแสดง %d เพลงแรกจาก %d เพลง",
        "ext.watch.complication.description": "ดูสิ่งที่กำลังเล่นอยู่ตอนนี้",
        "ext.watch.nowPlaying.empty.title": "ยังไม่มีการเล่นเลย",
        "ext.watch.queue.empty.subtitle": "เล่นเพลงบน iPhone ของคุณ แล้วคิวจะแสดงที่นี่",
        "ext.watch.queue.title": "ถัดไป",
        "ext.watch.radio.live": "สด",
        "ext.watch.radio.stop": "หยุด",
    ]

    static let tr: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "iPhone cihazınızdan bir şarkı seçerek çalmaya başlayın",
        "ext.watch.nowPlaying.none": "Hiçbir şey oynatılmıyor",
        "ext.watch.demo.track": "Parça Adı",
        "ext.watch.queue.empty.title": "Sıra boş",
        "ext.watch.nowPlaying.empty.unreachable": "iPhone cihazınızın kilidinin Primuse açıkken açıldığından emin olun",
        "ext.watch.demo.artist": "Sanatçı",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "%2$d şarkının ilk %1$d tanesi gösteriliyor",
        "ext.watch.complication.description": "Şu anda oynanan şeye bir göz atın.",
        "ext.watch.nowPlaying.empty.title": "Henüz oynatılan bir şey yok",
        "ext.watch.queue.empty.subtitle": "iPhone cihazınızda bir şarkı çaldığınızda sıra burada görünür",
        "ext.watch.queue.title": "Sıradaki",
        "ext.watch.radio.live": "CANLI",
        "ext.watch.radio.stop": "Durdur",
    ]

    static let pl: [String: String] = [
        "ext.watch.nowPlaying.empty.reachable": "Wybierz utwór na iPhone, aby rozpocząć odtwarzanie",
        "ext.watch.nowPlaying.none": "Nic nie jest odtwarzane",
        "ext.watch.demo.track": "Nazwa utworu",
        "ext.watch.queue.empty.title": "Kolejka jest pusta",
        "ext.watch.nowPlaying.empty.unreachable": "Upewnij się, że Twój iPhone jest odblokowany przy otwartym Primuse",
        "ext.watch.demo.artist": "Wykonawca",
        "ext.watch.appName": "Primuse",
        "ext.watch.queue.truncationNotice": "Wyświetlono pierwsze %d z %d utworów",
        "ext.watch.complication.description": "Rzuć okiem na to, co jest teraz odtwarzane.",
        "ext.watch.nowPlaying.empty.title": "Jeszcze nic nie jest odtwarzane",
        "ext.watch.queue.empty.subtitle": "Odtwórz utwór na swoim iPhone, a kolejka pojawi się tutaj",
        "ext.watch.queue.title": "Dalej",
        "ext.watch.radio.live": "NA ŻYWO",
        "ext.watch.radio.stop": "Zatrzymaj",
    ]

}

/// Watch app 与 Watch Widget Extension 共享的 Now Playing 快照。
///
/// 通过 App Group `group.com.welape.yuanyin` 共享 ── Watch app 收到 iPhone
/// 推来的状态后写一份到这个 UserDefaults; Widget Provider 读这份生成
/// timeline entry。
///
/// 注意 watchOS 上 Widget 跟 iOS Widget 一样必须经过 App Group 才能跨进程
/// 读到 Watch app 写入的数据 ── 各自的标准 UserDefaults 是隔离的。
enum SharedNowPlayingState {
    static let appGroup = "group.com.welape.yuanyin"
    static let widgetKind = "PrimuseWatchNowPlaying"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func write(
        songID: String,
        title: String,
        artist: String,
        isPlaying: Bool,
        isLiveStream: Bool = false
    ) {
        guard let d = defaults else { return }
        d.set(songID, forKey: "wnp.songID")
        d.set(title, forKey: "wnp.title")
        d.set(artist, forKey: "wnp.artist")
        d.set(isPlaying, forKey: "wnp.isPlaying")
        d.set(isLiveStream, forKey: "wnp.isLiveStream")
        d.set(Date().timeIntervalSince1970, forKey: "wnp.updatedAt")
    }

    static func read() -> Snapshot {
        guard let d = defaults else { return .empty }
        return Snapshot(
            songID: d.string(forKey: "wnp.songID") ?? "",
            title: d.string(forKey: "wnp.title") ?? "",
            artist: d.string(forKey: "wnp.artist") ?? "",
            isPlaying: d.bool(forKey: "wnp.isPlaying"),
            isLiveStream: d.bool(forKey: "wnp.isLiveStream"),
            updatedAt: Date(timeIntervalSince1970: d.double(forKey: "wnp.updatedAt"))
        )
    }

    struct Snapshot: Sendable {
        let songID: String
        let title: String
        let artist: String
        let isPlaying: Bool
        let isLiveStream: Bool
        let updatedAt: Date

        static let empty = Snapshot(
            songID: "", title: "", artist: "", isPlaying: false,
            isLiveStream: false, updatedAt: .distantPast
        )
        var hasSong: Bool { !songID.isEmpty }
    }
}
