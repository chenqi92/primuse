import Foundation
import UIKit

/// Watch app 与 Watch Widget Extension 共享的本地化取串。
///
/// PrimuseKit 不为 watchOS 编译 (`SUPPORTED_PLATFORMS` 不含 watchos)，Watch
/// 端无法走 iOS / tvOS 扩展用的 `PMString`。这里用一张内置 Swift 表覆盖同样的
/// 16 种语言，按系统偏好语言选行，
/// 缺失回退英文，键与 PrimuseKit `Localizable.strings` 里的 `ext.watch.*` 保持
/// 一致，便于将来两边对照。
func WatchString(_ key: String, _ args: CVarArg...) -> String {
    let table = WatchLoc.table(for: WatchLoc.preferredCode)
    let value = WatchOfflineLocalization.string(key, language: WatchLoc.preferredCode) ?? table[key] ?? WatchLoc.english[key] ?? key
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
        "ext.watch.more.title": "More",
        "ext.watch.like": "Like",
        "ext.watch.liked": "Liked",
        "ext.watch.mode.title": "Playback Mode",
        "ext.watch.mode.sequential": "Play in Order",
        "ext.watch.mode.repeatAll": "Repeat All",
        "ext.watch.mode.repeatOne": "Repeat One",
        "ext.watch.mode.shuffle": "Shuffle",
        "ext.watch.seek.title": "Playback Position",
        "ext.watch.seek.hint": "Turn the Digital Crown; playback jumps there when you stop.",
        "ext.watch.output.title": "Playing On",
        "ext.watch.volume.hint": "On Now Playing, turn the Digital Crown to change the iPhone volume.",
        "ext.watch.transport.play": "Play",
        "ext.watch.transport.pause": "Pause",
        "ext.watch.transport.previous": "Previous",
        "ext.watch.transport.next": "Next",
        "ext.watch.transport.previousStation": "Previous Station",
        "ext.watch.transport.nextStation": "Next Station",
        "ext.watch.transport.skipBackward": "Back %d Seconds",
        "ext.watch.transport.skipForward": "Forward %d Seconds",
        "ext.watch.lyrics.show": "Show Lyrics",
        "ext.watch.lyrics.hide": "Show Artwork",
        "ext.watch.unreachable.badge": "iPhone Not Connected",
        "ext.watch.retry": "Retry",
        "ext.watch.nowPlaying.empty.unreachableTitle": "Can't Reach iPhone",
    ]

    static let zhHans: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "快速看到正在播放的曲目",
        "ext.watch.demo.track": "曲目名",
        "ext.watch.demo.artist": "艺术家",
        "ext.watch.nowPlaying.none": "暂无播放",
        "ext.watch.nowPlaying.empty.title": "还没有播放",
        "ext.watch.nowPlaying.empty.reachable": "在 iPhone 上选一首歌开始播放",
        "ext.watch.nowPlaying.empty.unreachable": "请确认 iPhone 已解锁并打开 Primuse",
        "ext.watch.queue.title": "播放列表",
        "ext.watch.queue.empty.title": "队列为空",
        "ext.watch.queue.empty.subtitle": "在 iPhone 上选歌播放后这里会显示队列",
        "ext.watch.queue.truncationNotice": "仅显示前 %d 首，共 %d 首",
        "ext.watch.radio.live": "直播",
        "ext.watch.radio.stop": "停止",
        "ext.watch.more.title": "更多",
        "ext.watch.like": "喜欢",
        "ext.watch.liked": "已喜欢",
        "ext.watch.mode.title": "播放方式",
        "ext.watch.mode.sequential": "顺序播放",
        "ext.watch.mode.repeatAll": "列表循环",
        "ext.watch.mode.repeatOne": "单曲循环",
        "ext.watch.mode.shuffle": "随机播放",
        "ext.watch.seek.title": "调整进度",
        "ext.watch.seek.hint": "转动表冠调整，停下后跳转",
        "ext.watch.output.title": "声音输出到",
        "ext.watch.volume.hint": "在正在播放页转动数码表冠，可调节 iPhone 的音量",
        "ext.watch.transport.play": "播放",
        "ext.watch.transport.pause": "暂停",
        "ext.watch.transport.previous": "上一首",
        "ext.watch.transport.next": "下一首",
        "ext.watch.transport.previousStation": "上一个电台",
        "ext.watch.transport.nextStation": "下一个电台",
        "ext.watch.transport.skipBackward": "后退 %d 秒",
        "ext.watch.transport.skipForward": "前进 %d 秒",
        "ext.watch.lyrics.show": "显示歌词",
        "ext.watch.lyrics.hide": "显示封面",
        "ext.watch.unreachable.badge": "iPhone 未连接",
        "ext.watch.retry": "重试",
        "ext.watch.nowPlaying.empty.unreachableTitle": "连不上 iPhone",
    ]

    static let zhHant: [String: String] = [
        "ext.watch.appName": "Primuse",
        "ext.watch.complication.description": "快速看到正在播放的曲目",
        "ext.watch.demo.track": "曲目名",
        "ext.watch.demo.artist": "演出者",
        "ext.watch.nowPlaying.none": "暫無播放",
        "ext.watch.nowPlaying.empty.title": "還沒有播放",
        "ext.watch.nowPlaying.empty.reachable": "在 iPhone 上選一首歌開始播放",
        "ext.watch.nowPlaying.empty.unreachable": "請確認 iPhone 已解鎖並開啟 Primuse",
        "ext.watch.queue.title": "播放清單",
        "ext.watch.queue.empty.title": "佇列為空",
        "ext.watch.queue.empty.subtitle": "在 iPhone 上選歌播放後這裡會顯示佇列",
        "ext.watch.queue.truncationNotice": "僅顯示前 %d 首，共 %d 首",
        "ext.watch.radio.live": "直播",
        "ext.watch.radio.stop": "停止",
        "ext.watch.more.title": "更多",
        "ext.watch.like": "加入最愛",
        "ext.watch.liked": "已加入最愛",
        "ext.watch.mode.title": "播放方式",
        "ext.watch.mode.sequential": "順序播放",
        "ext.watch.mode.repeatAll": "列表循環",
        "ext.watch.mode.repeatOne": "單曲循環",
        "ext.watch.mode.shuffle": "隨機播放",
        "ext.watch.seek.title": "調整進度",
        "ext.watch.seek.hint": "轉動錶冠調整，停下後跳轉",
        "ext.watch.output.title": "聲音輸出到",
        "ext.watch.volume.hint": "在正在播放頁轉動數位錶冠，可調整 iPhone 的音量",
        "ext.watch.transport.play": "播放",
        "ext.watch.transport.pause": "暫停",
        "ext.watch.transport.previous": "上一首",
        "ext.watch.transport.next": "下一首",
        "ext.watch.transport.previousStation": "上一個電台",
        "ext.watch.transport.nextStation": "下一個電台",
        "ext.watch.transport.skipBackward": "倒轉 %d 秒",
        "ext.watch.transport.skipForward": "快轉 %d 秒",
        "ext.watch.lyrics.show": "顯示歌詞",
        "ext.watch.lyrics.hide": "顯示封面",
        "ext.watch.unreachable.badge": "iPhone 未連線",
        "ext.watch.retry": "重試",
        "ext.watch.nowPlaying.empty.unreachableTitle": "連不上 iPhone",
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
        "ext.watch.more.title": "Mehr",
        "ext.watch.like": "Zu Lieblingssongs",
        "ext.watch.liked": "In Lieblingssongs",
        "ext.watch.mode.title": "Wiedergabemodus",
        "ext.watch.mode.sequential": "Der Reihe nach",
        "ext.watch.mode.repeatAll": "Alle wiederholen",
        "ext.watch.mode.repeatOne": "Titel wiederholen",
        "ext.watch.mode.shuffle": "Zufällig",
        "ext.watch.seek.title": "Position ändern",
        "ext.watch.seek.hint": "Drehe die Digital Crown – beim Anhalten springt die Wiedergabe dorthin.",
        "ext.watch.output.title": "Wiedergabe auf",
        "ext.watch.volume.hint": "Drehe auf „Jetzt läuft“ die Digital Crown, um die Lautstärke des iPhone zu ändern.",
        "ext.watch.transport.play": "Wiedergabe",
        "ext.watch.transport.pause": "Pause",
        "ext.watch.transport.previous": "Zurück",
        "ext.watch.transport.next": "Weiter",
        "ext.watch.transport.previousStation": "Vorheriger Sender",
        "ext.watch.transport.nextStation": "Nächster Sender",
        "ext.watch.transport.skipBackward": "%d Sekunden zurück",
        "ext.watch.transport.skipForward": "%d Sekunden vor",
        "ext.watch.lyrics.show": "Liedtext anzeigen",
        "ext.watch.lyrics.hide": "Cover anzeigen",
        "ext.watch.unreachable.badge": "iPhone nicht verbunden",
        "ext.watch.retry": "Wiederholen",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhone nicht erreichbar",
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
        "ext.watch.more.title": "Plus",
        "ext.watch.like": "J’aime",
        "ext.watch.liked": "Aimé",
        "ext.watch.mode.title": "Mode de lecture",
        "ext.watch.mode.sequential": "Lecture dans l’ordre",
        "ext.watch.mode.repeatAll": "Tout répéter",
        "ext.watch.mode.repeatOne": "Répéter le morceau",
        "ext.watch.mode.shuffle": "Aléatoire",
        "ext.watch.seek.title": "Position de lecture",
        "ext.watch.seek.hint": "Tournez la Digital Crown ; la lecture saute à cet endroit quand vous vous arrêtez.",
        "ext.watch.output.title": "Lecture sur",
        "ext.watch.volume.hint": "Sur « À l’écoute », tournez la Digital Crown pour régler le volume de l’iPhone.",
        "ext.watch.transport.play": "Lecture",
        "ext.watch.transport.pause": "Pause",
        "ext.watch.transport.previous": "Précédent",
        "ext.watch.transport.next": "Suivant",
        "ext.watch.transport.previousStation": "Station précédente",
        "ext.watch.transport.nextStation": "Station suivante",
        "ext.watch.transport.skipBackward": "Reculer de %d secondes",
        "ext.watch.transport.skipForward": "Avancer de %d secondes",
        "ext.watch.lyrics.show": "Afficher les paroles",
        "ext.watch.lyrics.hide": "Afficher la pochette",
        "ext.watch.unreachable.badge": "iPhone non connecté",
        "ext.watch.retry": "Réessayer",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhone injoignable",
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
        "ext.watch.more.title": "その他",
        "ext.watch.like": "好きな曲に追加",
        "ext.watch.liked": "好きな曲に追加済み",
        "ext.watch.mode.title": "再生モード",
        "ext.watch.mode.sequential": "順番に再生",
        "ext.watch.mode.repeatAll": "全曲リピート",
        "ext.watch.mode.repeatOne": "1曲リピート",
        "ext.watch.mode.shuffle": "シャッフル",
        "ext.watch.seek.title": "再生位置",
        "ext.watch.seek.hint": "Digital Crownを回して調整し、止めるとその位置に移動します",
        "ext.watch.output.title": "再生先",
        "ext.watch.volume.hint": "再生中の画面でDigital Crownを回すと、iPhoneの音量を変えられます",
        "ext.watch.transport.play": "再生",
        "ext.watch.transport.pause": "一時停止",
        "ext.watch.transport.previous": "前へ",
        "ext.watch.transport.next": "次へ",
        "ext.watch.transport.previousStation": "前の局",
        "ext.watch.transport.nextStation": "次の局",
        "ext.watch.transport.skipBackward": "%d秒戻る",
        "ext.watch.transport.skipForward": "%d秒進む",
        "ext.watch.lyrics.show": "歌詞を表示",
        "ext.watch.lyrics.hide": "アートワークを表示",
        "ext.watch.unreachable.badge": "iPhoneに未接続",
        "ext.watch.retry": "再試行",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhoneに接続できません",
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
        "ext.watch.more.title": "더 보기",
        "ext.watch.like": "좋아요",
        "ext.watch.liked": "좋아요 함",
        "ext.watch.mode.title": "재생 방식",
        "ext.watch.mode.sequential": "순서대로 재생",
        "ext.watch.mode.repeatAll": "전체 반복",
        "ext.watch.mode.repeatOne": "한 곡 반복",
        "ext.watch.mode.shuffle": "셔플",
        "ext.watch.seek.title": "재생 위치",
        "ext.watch.seek.hint": "Digital Crown을 돌려 조정하고, 멈추면 그 위치로 이동합니다",
        "ext.watch.output.title": "재생 기기",
        "ext.watch.volume.hint": "재생 중 화면에서 Digital Crown을 돌리면 iPhone 음량을 조절할 수 있습니다",
        "ext.watch.transport.play": "재생",
        "ext.watch.transport.pause": "일시 정지",
        "ext.watch.transport.previous": "이전",
        "ext.watch.transport.next": "다음",
        "ext.watch.transport.previousStation": "이전 방송국",
        "ext.watch.transport.nextStation": "다음 방송국",
        "ext.watch.transport.skipBackward": "%d초 뒤로",
        "ext.watch.transport.skipForward": "%d초 앞으로",
        "ext.watch.lyrics.show": "가사 보기",
        "ext.watch.lyrics.hide": "앨범 아트 보기",
        "ext.watch.unreachable.badge": "iPhone 연결 안 됨",
        "ext.watch.retry": "다시 시도",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhone에 연결할 수 없음",
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
        "ext.watch.more.title": "Ещё",
        "ext.watch.like": "Нравится",
        "ext.watch.liked": "В избранном",
        "ext.watch.mode.title": "Режим воспроизведения",
        "ext.watch.mode.sequential": "По порядку",
        "ext.watch.mode.repeatAll": "Повтор всех",
        "ext.watch.mode.repeatOne": "Повтор трека",
        "ext.watch.mode.shuffle": "Перемешать",
        "ext.watch.seek.title": "Позиция",
        "ext.watch.seek.hint": "Поверните Digital Crown — после остановки воспроизведение перейдёт туда.",
        "ext.watch.output.title": "Воспроизведение на",
        "ext.watch.volume.hint": "На экране «Исполняется» поверните Digital Crown, чтобы изменить громкость iPhone.",
        "ext.watch.transport.play": "Воспроизвести",
        "ext.watch.transport.pause": "Пауза",
        "ext.watch.transport.previous": "Назад",
        "ext.watch.transport.next": "Далее",
        "ext.watch.transport.previousStation": "Предыдущая станция",
        "ext.watch.transport.nextStation": "Следующая станция",
        "ext.watch.transport.skipBackward": "Назад на %d с",
        "ext.watch.transport.skipForward": "Вперёд на %d с",
        "ext.watch.lyrics.show": "Показать текст",
        "ext.watch.lyrics.hide": "Показать обложку",
        "ext.watch.unreachable.badge": "iPhone не подключен",
        "ext.watch.retry": "Повторить попытку",
        "ext.watch.nowPlaying.empty.unreachableTitle": "Нет связи с iPhone",
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
        "ext.watch.more.title": "Більше",
        "ext.watch.like": "Подобається",
        "ext.watch.liked": "Сподобалося",
        "ext.watch.mode.title": "Режим відтворення",
        "ext.watch.mode.sequential": "По порядку",
        "ext.watch.mode.repeatAll": "Повтор усіх",
        "ext.watch.mode.repeatOne": "Повтор треку",
        "ext.watch.mode.shuffle": "Перемішати",
        "ext.watch.seek.title": "Позиція",
        "ext.watch.seek.hint": "Поверніть Digital Crown — після зупинки відтворення перейде туди.",
        "ext.watch.output.title": "Відтворення на",
        "ext.watch.volume.hint": "На екрані «Відтворюється» поверніть Digital Crown, щоб змінити гучність iPhone.",
        "ext.watch.transport.play": "Відтворити",
        "ext.watch.transport.pause": "Пауза",
        "ext.watch.transport.previous": "Назад",
        "ext.watch.transport.next": "Далі",
        "ext.watch.transport.previousStation": "Попередня станція",
        "ext.watch.transport.nextStation": "Наступна станція",
        "ext.watch.transport.skipBackward": "Назад на %d с",
        "ext.watch.transport.skipForward": "Уперед на %d с",
        "ext.watch.lyrics.show": "Показати текст",
        "ext.watch.lyrics.hide": "Показати обкладинку",
        "ext.watch.unreachable.badge": "iPhone не підключено",
        "ext.watch.retry": "Повторіть спробу",
        "ext.watch.nowPlaying.empty.unreachableTitle": "Немає зв’язку з iPhone",
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
        "ext.watch.more.title": "المزيد",
        "ext.watch.like": "أعجبني",
        "ext.watch.liked": "تم الإعجاب",
        "ext.watch.mode.title": "طريقة التشغيل",
        "ext.watch.mode.sequential": "التشغيل بالترتيب",
        "ext.watch.mode.repeatAll": "تكرار الكل",
        "ext.watch.mode.repeatOne": "تكرار الأغنية",
        "ext.watch.mode.shuffle": "تشغيل عشوائي",
        "ext.watch.seek.title": "موضع التشغيل",
        "ext.watch.seek.hint": "أدر Digital Crown، وينتقل التشغيل إلى الموضع عند التوقف.",
        "ext.watch.output.title": "التشغيل على",
        "ext.watch.volume.hint": "في شاشة قيد التشغيل، أدر Digital Crown لتغيير مستوى صوت iPhone.",
        "ext.watch.transport.play": "تشغيل",
        "ext.watch.transport.pause": "إيقاف مؤقت",
        "ext.watch.transport.previous": "السابق",
        "ext.watch.transport.next": "التالي",
        "ext.watch.transport.previousStation": "المحطة السابقة",
        "ext.watch.transport.nextStation": "المحطة التالية",
        "ext.watch.transport.skipBackward": "رجوع %d ثانية",
        "ext.watch.transport.skipForward": "تقدم %d ثانية",
        "ext.watch.lyrics.show": "إظهار الكلمات",
        "ext.watch.lyrics.hide": "إظهار الغلاف",
        "ext.watch.unreachable.badge": "iPhone غير متصل",
        "ext.watch.retry": "إعادة المحاولة",
        "ext.watch.nowPlaying.empty.unreachableTitle": "تعذّر الوصول إلى iPhone",
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
        "ext.watch.more.title": "Más",
        "ext.watch.like": "Me gusta",
        "ext.watch.liked": "Te gusta",
        "ext.watch.mode.title": "Modo de reproducción",
        "ext.watch.mode.sequential": "En orden",
        "ext.watch.mode.repeatAll": "Repetir todo",
        "ext.watch.mode.repeatOne": "Repetir canción",
        "ext.watch.mode.shuffle": "Aleatorio",
        "ext.watch.seek.title": "Posición",
        "ext.watch.seek.hint": "Gira la Digital Crown; la reproducción salta ahí cuando te detienes.",
        "ext.watch.output.title": "Reproduciendo en",
        "ext.watch.volume.hint": "En Reproduciendo, gira la Digital Crown para cambiar el volumen del iPhone.",
        "ext.watch.transport.play": "Reproducir",
        "ext.watch.transport.pause": "Pausar",
        "ext.watch.transport.previous": "Anterior",
        "ext.watch.transport.next": "Siguiente",
        "ext.watch.transport.previousStation": "Estación anterior",
        "ext.watch.transport.nextStation": "Estación siguiente",
        "ext.watch.transport.skipBackward": "Retroceder %d segundos",
        "ext.watch.transport.skipForward": "Adelantar %d segundos",
        "ext.watch.lyrics.show": "Mostrar letra",
        "ext.watch.lyrics.hide": "Mostrar portada",
        "ext.watch.unreachable.badge": "iPhone sin conexión",
        "ext.watch.retry": "Reintentar",
        "ext.watch.nowPlaying.empty.unreachableTitle": "No se puede conectar con el iPhone",
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
        "ext.watch.more.title": "Mais",
        "ext.watch.like": "Curtir",
        "ext.watch.liked": "Curtida",
        "ext.watch.mode.title": "Modo de reprodução",
        "ext.watch.mode.sequential": "Em ordem",
        "ext.watch.mode.repeatAll": "Repetir tudo",
        "ext.watch.mode.repeatOne": "Repetir música",
        "ext.watch.mode.shuffle": "Aleatório",
        "ext.watch.seek.title": "Posição",
        "ext.watch.seek.hint": "Gire a Digital Crown; a reprodução pula para lá quando você parar.",
        "ext.watch.output.title": "Tocando em",
        "ext.watch.volume.hint": "Em Tocando, gire a Digital Crown para mudar o volume do iPhone.",
        "ext.watch.transport.play": "Reproduzir",
        "ext.watch.transport.pause": "Pausar",
        "ext.watch.transport.previous": "Anterior",
        "ext.watch.transport.next": "Próxima",
        "ext.watch.transport.previousStation": "Estação anterior",
        "ext.watch.transport.nextStation": "Próxima estação",
        "ext.watch.transport.skipBackward": "Voltar %d segundos",
        "ext.watch.transport.skipForward": "Avançar %d segundos",
        "ext.watch.lyrics.show": "Mostrar letra",
        "ext.watch.lyrics.hide": "Mostrar capa",
        "ext.watch.unreachable.badge": "iPhone desconectado",
        "ext.watch.retry": "Tentar novamente",
        "ext.watch.nowPlaying.empty.unreachableTitle": "Não foi possível conectar ao iPhone",
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
        "ext.watch.more.title": "और",
        "ext.watch.like": "पसंद करें",
        "ext.watch.liked": "पसंद किया",
        "ext.watch.mode.title": "चलाने का तरीका",
        "ext.watch.mode.sequential": "क्रम से चलाएँ",
        "ext.watch.mode.repeatAll": "सभी दोहराएँ",
        "ext.watch.mode.repeatOne": "एक गाना दोहराएँ",
        "ext.watch.mode.shuffle": "फेरबदल",
        "ext.watch.seek.title": "चलाने की स्थिति",
        "ext.watch.seek.hint": "Digital Crown घुमाएँ; रुकने पर प्लेबैक वहीं पहुँच जाएगा।",
        "ext.watch.output.title": "इस पर चल रहा है",
        "ext.watch.volume.hint": "अभी चल रहा है स्क्रीन पर Digital Crown घुमाकर iPhone का वॉल्यूम बदलें।",
        "ext.watch.transport.play": "चलाएँ",
        "ext.watch.transport.pause": "रोकें",
        "ext.watch.transport.previous": "पिछला",
        "ext.watch.transport.next": "आगे",
        "ext.watch.transport.previousStation": "पिछला स्टेशन",
        "ext.watch.transport.nextStation": "अगला स्टेशन",
        "ext.watch.transport.skipBackward": "%d सेकंड पीछे",
        "ext.watch.transport.skipForward": "%d सेकंड आगे",
        "ext.watch.lyrics.show": "बोल दिखाएँ",
        "ext.watch.lyrics.hide": "कवर दिखाएँ",
        "ext.watch.unreachable.badge": "iPhone कनेक्ट नहीं है",
        "ext.watch.retry": "पुनः प्रयास करें",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhone से संपर्क नहीं हो पा रहा",
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
        "ext.watch.more.title": "เพิ่มเติม",
        "ext.watch.like": "ชอบ",
        "ext.watch.liked": "ชอบแล้ว",
        "ext.watch.mode.title": "รูปแบบการเล่น",
        "ext.watch.mode.sequential": "เล่นตามลำดับ",
        "ext.watch.mode.repeatAll": "เล่นซ้ำทั้งหมด",
        "ext.watch.mode.repeatOne": "เล่นซ้ำเพลงเดียว",
        "ext.watch.mode.shuffle": "สุ่มเล่น",
        "ext.watch.seek.title": "ตำแหน่งการเล่น",
        "ext.watch.seek.hint": "หมุน Digital Crown แล้วหยุด เพลงจะข้ามไปยังตำแหน่งนั้น",
        "ext.watch.output.title": "กำลังเล่นบน",
        "ext.watch.volume.hint": "ในหน้ากำลังเล่น หมุน Digital Crown เพื่อปรับระดับเสียงของ iPhone",
        "ext.watch.transport.play": "เล่น",
        "ext.watch.transport.pause": "พัก",
        "ext.watch.transport.previous": "ก่อนหน้า",
        "ext.watch.transport.next": "ถัดไป",
        "ext.watch.transport.previousStation": "สถานีก่อนหน้า",
        "ext.watch.transport.nextStation": "สถานีถัดไป",
        "ext.watch.transport.skipBackward": "ย้อนกลับ %d วินาที",
        "ext.watch.transport.skipForward": "ข้ามไป %d วินาที",
        "ext.watch.lyrics.show": "แสดงเนื้อเพลง",
        "ext.watch.lyrics.hide": "แสดงภาพปก",
        "ext.watch.unreachable.badge": "ไม่ได้เชื่อมต่อ iPhone",
        "ext.watch.retry": "ลองอีกครั้ง",
        "ext.watch.nowPlaying.empty.unreachableTitle": "เชื่อมต่อ iPhone ไม่ได้",
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
        "ext.watch.more.title": "Daha Fazla",
        "ext.watch.like": "Beğen",
        "ext.watch.liked": "Beğenildi",
        "ext.watch.mode.title": "Çalma Modu",
        "ext.watch.mode.sequential": "Sırayla Çal",
        "ext.watch.mode.repeatAll": "Tümünü Tekrarla",
        "ext.watch.mode.repeatOne": "Şarkıyı Tekrarla",
        "ext.watch.mode.shuffle": "Karıştır",
        "ext.watch.seek.title": "Konum",
        "ext.watch.seek.hint": "Digital Crown'u çevirin; durduğunuzda çalma oraya atlar.",
        "ext.watch.output.title": "Çalınan Cihaz",
        "ext.watch.volume.hint": "Şimdi Çalıyor ekranında iPhone'un ses düzeyini değiştirmek için Digital Crown'u çevirin.",
        "ext.watch.transport.play": "Oynat",
        "ext.watch.transport.pause": "Duraklat",
        "ext.watch.transport.previous": "Önceki",
        "ext.watch.transport.next": "İleri",
        "ext.watch.transport.previousStation": "Önceki İstasyon",
        "ext.watch.transport.nextStation": "Sonraki İstasyon",
        "ext.watch.transport.skipBackward": "%d saniye geri",
        "ext.watch.transport.skipForward": "%d saniye ileri",
        "ext.watch.lyrics.show": "Sözleri göster",
        "ext.watch.lyrics.hide": "Kapağı göster",
        "ext.watch.unreachable.badge": "iPhone bağlı değil",
        "ext.watch.retry": "Tekrar dene",
        "ext.watch.nowPlaying.empty.unreachableTitle": "iPhone'a ulaşılamıyor",
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
        "ext.watch.more.title": "Więcej",
        "ext.watch.like": "Polub",
        "ext.watch.liked": "Polubiono",
        "ext.watch.mode.title": "Tryb odtwarzania",
        "ext.watch.mode.sequential": "Po kolei",
        "ext.watch.mode.repeatAll": "Powtarzaj wszystko",
        "ext.watch.mode.repeatOne": "Powtarzaj utwór",
        "ext.watch.mode.shuffle": "Losowo",
        "ext.watch.seek.title": "Pozycja",
        "ext.watch.seek.hint": "Obróć Digital Crown; po zatrzymaniu odtwarzanie przeskoczy w to miejsce.",
        "ext.watch.output.title": "Odtwarzanie na",
        "ext.watch.volume.hint": "Na ekranie Teraz odtwarzane obróć Digital Crown, aby zmienić głośność iPhone’a.",
        "ext.watch.transport.play": "Odtwórz",
        "ext.watch.transport.pause": "Wstrzymaj",
        "ext.watch.transport.previous": "Poprzedni",
        "ext.watch.transport.next": "Następny",
        "ext.watch.transport.previousStation": "Poprzednia stacja",
        "ext.watch.transport.nextStation": "Następna stacja",
        "ext.watch.transport.skipBackward": "Do tyłu o %d s",
        "ext.watch.transport.skipForward": "Do przodu o %d s",
        "ext.watch.lyrics.show": "Pokaż tekst",
        "ext.watch.lyrics.hide": "Pokaż okładkę",
        "ext.watch.unreachable.badge": "iPhone niepołączony",
        "ext.watch.retry": "Spróbuj ponownie",
        "ext.watch.nowPlaying.empty.unreachableTitle": "Brak połączenia z iPhone’em",
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

    /// 表盘上的封面图 (iPhone 推来的小 JPEG 原样存一份)。存在 App Group 的容器里,
    /// 组件进程才读得到。
    private static var coverURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("watch-now-playing-cover.jpg")
    }

    static func write(
        songID: String,
        title: String,
        artist: String,
        isPlaying: Bool,
        isLiveStream: Bool = false,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        playbackRate: Double = 1,
        accent: (r: Double, g: Double, b: Double)? = nil
    ) {
        guard let d = defaults else { return }
        d.set(songID, forKey: "wnp.songID")
        d.set(title, forKey: "wnp.title")
        d.set(artist, forKey: "wnp.artist")
        d.set(isPlaying, forKey: "wnp.isPlaying")
        d.set(isLiveStream, forKey: "wnp.isLiveStream")
        d.set(duration, forKey: "wnp.duration")
        d.set(elapsed, forKey: "wnp.elapsed")
        d.set(playbackRate, forKey: "wnp.rate")
        if let accent {
            d.set([accent.r, accent.g, accent.b], forKey: "wnp.accent")
        }
        d.set(Date().timeIntervalSince1970, forKey: "wnp.updatedAt")
    }

    /// 存当前这首的封面; nil 清掉。记下是哪一首的, 换歌后组件不会拿上一首的图。
    static func writeCover(_ jpeg: Data?, songID: String) {
        guard let d = defaults, let url = coverURL else { return }
        if let jpeg, !jpeg.isEmpty {
            guard (try? jpeg.write(to: url, options: .atomic)) != nil else { return }
            d.set(songID, forKey: "wnp.coverSongID")
        } else {
            try? FileManager.default.removeItem(at: url)
            d.removeObject(forKey: "wnp.coverSongID")
        }
    }

    static func read() -> Snapshot {
        guard let d = defaults else { return .empty }
        let songID = d.string(forKey: "wnp.songID") ?? ""
        let accent = d.array(forKey: "wnp.accent") as? [Double]
        let cover: Data? = {
            guard !songID.isEmpty, d.string(forKey: "wnp.coverSongID") == songID,
                  let url = coverURL else { return nil }
            return try? Data(contentsOf: url)
        }()
        return Snapshot(
            songID: songID,
            title: d.string(forKey: "wnp.title") ?? "",
            artist: d.string(forKey: "wnp.artist") ?? "",
            isPlaying: d.bool(forKey: "wnp.isPlaying"),
            isLiveStream: d.bool(forKey: "wnp.isLiveStream"),
            updatedAt: Date(timeIntervalSince1970: d.double(forKey: "wnp.updatedAt")),
            duration: d.double(forKey: "wnp.duration"),
            elapsed: d.double(forKey: "wnp.elapsed"),
            // 旧版写的快照没有这项, 按 1 倍。
            playbackRate: d.object(forKey: "wnp.rate") as? Double ?? 1,
            accentRGB: accent?.count == 3 ? accent : nil,
            coverJPEG: cover
        )
    }

    struct Snapshot: Sendable {
        let songID: String
        let title: String
        let artist: String
        let isPlaying: Bool
        let isLiveStream: Bool
        let updatedAt: Date
        var duration: TimeInterval = 0
        /// 写入那一刻播到哪 (秒)。
        var elapsed: TimeInterval = 0
        /// iPhone 的实际倍速; elapsed / duration 都是内容时间, 换算成墙钟要除以它。
        var playbackRate: Double = 1
        var accentRGB: [Double]?
        var coverJPEG: Data?

        static let empty = Snapshot(
            songID: "", title: "", artist: "", isPlaying: false,
            isLiveStream: false, updatedAt: .distantPast
        )
        var hasSong: Bool { !songID.isEmpty }

        /// 正在播时这首从哪一刻放到哪一刻 (墙钟), 给会自己走的进度条用; 暂停、电台、不知道时长时为 nil。
        /// 倍速时整段按倍速压缩, 进度圈在真正放完的那一刻走满。
        var playbackInterval: ClosedRange<Date>? {
            guard hasSong, isPlaying, !isLiveStream, duration > 0 else { return nil }
            let rate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
            let start = updatedAt.addingTimeInterval(-elapsed / rate)
            return start...start.addingTimeInterval(duration / rate)
        }

        /// 多久没收到更新就当 iPhone 那边已经不放了, 表盘换成空白。
        static let staleInterval: TimeInterval = 15 * 60
        /// 按进度该放完之后再留这么久, 等下一首的状态推过来。
        static let endGrace: TimeInterval = 60

        /// 这份快照到什么时候算过期。默认写入后 15 分钟; 正在放、知道时长的, 进度自己往前走
        /// 不会触发重写 (只有换歌、暂停、拖进度才写), 所以一直撑到按进度该放完的时候,
        /// 四五十分钟一章的有声书不会放到一半就从表盘上消失。
        var staleDate: Date {
            let afterUpdate = updatedAt.addingTimeInterval(Self.staleInterval)
            guard let interval = playbackInterval else { return afterUpdate }
            return max(afterUpdate, interval.upperBound.addingTimeInterval(Self.endGrace))
        }

        /// 暂停时停在的比例。
        var pausedFraction: Double? {
            guard hasSong, !isPlaying, !isLiveStream, duration > 0 else { return nil }
            return min(1, max(0, elapsed / duration))
        }
    }
}
