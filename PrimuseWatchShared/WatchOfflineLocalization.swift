import Foundation

enum WatchOfflineLocalization {
    static func string(_ key: String, language: String) -> String? {
        let code: String
        if language.hasPrefix("zh") {
            code = language.contains("Hant") || language.contains("TW") || language.contains("HK") ? "zh-Hant" : "zh-Hans"
        } else if language.hasPrefix("es") { code = "es-MX" }
        else if language.hasPrefix("pt") { code = "pt-BR" }
        else { code = String(language.prefix(2)) }
        guard let index = keys.firstIndex(of: key) else { return nil }
        return (translations[code] ?? translations["en"]!)[index]
    }

    private static let keys = [
        "ext.watch.offline.title",
        "ext.watch.offline.phone",
        "ext.watch.offline.empty",
        "ext.watch.offline.companions",
        "ext.watch.offline.delete",
        "ext.watch.offline.cancel",
        "ext.watch.offline.playFailed",
        "ext.watch.offline.fileFailed",
        "ext.watch.offline.volume",
        "ext.watch.offline.ok",
        "watchDestinationHint",
        "watchUnavailable",
        "watchTransfers",
        "watchPreparing",
        "watchQueued",
        "watchAwaitingReceipt",
        "watchReceived"
]

    private static let translations: [String: [String]] = [
        "en": ["On Apple Watch", "Control iPhone", "Send music from the iPhone transfer page to listen offline.", "Artwork and lyrics", "Delete", "Cancel", "Unable to play this file.", "Unable to save or remove this file.", "Turn the Digital Crown to adjust Apple Watch audio volume.", "OK", "Save on your paired watch for offline playback", "Pair an Apple Watch and install Primuse on it", "Watch transfers", "Preparing for Apple Watch", "Queued for Apple Watch", "Waiting for watch confirmation", "Saved on Apple Watch"],
        "zh-Hans": ["手表上的音乐", "控制 iPhone", "从 iPhone 的文件传输页发送音乐，即可离线播放。", "封面与歌词", "删除", "取消", "无法播放此文件。", "无法保存或删除此文件。", "转动数码表冠调节 Apple Watch 的播放音量。", "好", "保存到已配对的手表，供离线播放", "请先配对 Apple Watch 并安装 Primuse", "手表传输记录", "正在为手表准备文件", "已加入手表传输队列", "等待手表确认", "已保存到 Apple Watch"],
        "zh-Hant": ["手錶上的音樂", "控制 iPhone", "從 iPhone 的檔案傳輸頁傳送音樂，即可離線播放。", "封面與歌詞", "刪除", "取消", "無法播放此檔案。", "無法儲存或刪除此檔案。", "轉動數位錶冠調整 Apple Watch 的播放音量。", "好", "儲存到已配對的手錶，供離線播放", "請先配對 Apple Watch 並安裝 Primuse", "手錶傳輸記錄", "正在為手錶準備檔案", "已加入手錶傳輸佇列", "等待手錶確認", "已儲存到 Apple Watch"],
        "de": ["Auf der Apple Watch", "iPhone steuern", "Musik über die Dateiübertragung auf dem iPhone senden und offline hören.", "Cover und Liedtexte", "Löschen", "Abbrechen", "Diese Datei kann nicht abgespielt werden.", "Diese Datei konnte nicht gespeichert oder gelöscht werden.", "Mit der Digital Crown die Lautstärke der Apple Watch ändern.", "OK", "Auf der gekoppelten Watch zum Offlinehören speichern", "Apple Watch koppeln und Primuse darauf installieren", "Watch-Übertragungen", "Für Apple Watch vorbereiten", "Für Apple Watch eingereiht", "Bestätigung der Watch ausstehend", "Auf Apple Watch gespeichert"],
        "fr": ["Sur Apple Watch", "Contrôler l’iPhone", "Envoyez de la musique depuis le transfert de fichiers de l’iPhone pour l’écouter hors ligne.", "Pochettes et paroles", "Supprimer", "Annuler", "Impossible de lire ce fichier.", "Impossible d’enregistrer ou de supprimer ce fichier.", "Tournez la Digital Crown pour régler le volume de l’Apple Watch.", "OK", "Enregistrer sur la montre jumelée pour écouter hors ligne", "Jumelez une Apple Watch et installez Primuse dessus", "Transferts Watch", "Préparation pour Apple Watch", "En attente d’envoi vers Apple Watch", "En attente de confirmation de la montre", "Enregistré sur Apple Watch"],
        "ja": ["Apple Watch内の音楽", "iPhoneを操作", "iPhoneのファイル転送画面から音楽を送信するとオフラインで再生できます。", "アートワークと歌詞", "削除", "キャンセル", "このファイルを再生できません。", "このファイルを保存または削除できません。", "Digital CrownでApple Watchの音量を調整します。", "OK", "ペアリング済みのWatchに保存してオフライン再生", "Apple WatchをペアリングしてPrimuseをインストールしてください", "Watchへの転送", "Apple Watch用に準備中", "Apple Watchへの転送待ち", "Watchの確認待ち", "Apple Watchに保存済み"],
        "ko": ["Apple Watch의 음악", "iPhone 제어", "iPhone의 파일 전송 화면에서 음악을 보내 오프라인으로 재생하세요.", "앨범 표지 및 가사", "삭제", "취소", "이 파일을 재생할 수 없습니다.", "이 파일을 저장하거나 삭제할 수 없습니다.", "Digital Crown을 돌려 Apple Watch 음량을 조절하세요.", "확인", "페어링된 시계에 저장하여 오프라인 재생", "Apple Watch를 페어링하고 Primuse를 설치하세요", "Watch 전송", "Apple Watch용 파일 준비 중", "Apple Watch 전송 대기 중", "시계 확인 대기 중", "Apple Watch에 저장됨"],
        "es-MX": ["En Apple Watch", "Controlar iPhone", "Envía música desde la transferencia de archivos del iPhone para escuchar sin conexión.", "Portadas y letras", "Eliminar", "Cancelar", "No se puede reproducir este archivo.", "No se pudo guardar o eliminar este archivo.", "Gira la Digital Crown para ajustar el volumen del Apple Watch.", "Aceptar", "Guardar en el reloj enlazado para escuchar sin conexión", "Enlaza un Apple Watch e instala Primuse", "Transferencias al Watch", "Preparando para Apple Watch", "En cola para Apple Watch", "Esperando confirmación del reloj", "Guardado en Apple Watch"],
        "pt-BR": ["No Apple Watch", "Controlar iPhone", "Envie músicas pela transferência de arquivos do iPhone para ouvir offline.", "Capas e letras", "Apagar", "Cancelar", "Não foi possível reproduzir este arquivo.", "Não foi possível salvar ou apagar este arquivo.", "Gire a Digital Crown para ajustar o volume do Apple Watch.", "OK", "Salvar no relógio emparelhado para ouvir offline", "Emparelhe um Apple Watch e instale o Primuse", "Transferências para Watch", "Preparando para Apple Watch", "Na fila para Apple Watch", "Aguardando confirmação do relógio", "Salvo no Apple Watch"],
        "ru": ["На Apple Watch", "Управлять iPhone", "Отправьте музыку через передачу файлов на iPhone, чтобы слушать офлайн.", "Обложки и тексты", "Удалить", "Отмена", "Не удалось воспроизвести файл.", "Не удалось сохранить или удалить файл.", "Поверните Digital Crown для изменения громкости Apple Watch.", "ОК", "Сохранить на связанных часах для прослушивания офлайн", "Создайте пару с Apple Watch и установите Primuse", "Передачи на Watch", "Подготовка для Apple Watch", "В очереди на Apple Watch", "Ожидание подтверждения часов", "Сохранено на Apple Watch"],
        "uk": ["На Apple Watch", "Керувати iPhone", "Надішліть музику через передавання файлів на iPhone, щоб слухати офлайн.", "Обкладинки й тексти", "Видалити", "Скасувати", "Не вдалося відтворити файл.", "Не вдалося зберегти або видалити файл.", "Поверніть Digital Crown, щоб змінити гучність Apple Watch.", "ОК", "Зберегти на спареному годиннику для прослуховування офлайн", "Спарте Apple Watch і встановіть Primuse", "Передавання на Watch", "Підготовка для Apple Watch", "У черзі на Apple Watch", "Очікування підтвердження годинника", "Збережено на Apple Watch"],
        "ar": ["على Apple Watch", "التحكم في iPhone", "أرسل الموسيقى من صفحة نقل الملفات على iPhone للاستماع دون اتصال.", "الأغلفة وكلمات الأغاني", "حذف", "إلغاء", "تعذر تشغيل هذا الملف.", "تعذر حفظ هذا الملف أو حذفه.", "أدر التاج الرقمي لضبط مستوى صوت Apple Watch.", "موافق", "الحفظ على الساعة المقترنة للاستماع دون اتصال", "اقرن Apple Watch وثبّت Primuse عليها", "عمليات النقل إلى Watch", "جارٍ التحضير لـ Apple Watch", "في قائمة الانتظار لـ Apple Watch", "بانتظار تأكيد الساعة", "تم الحفظ على Apple Watch"],
        "hi": ["Apple Watch पर", "iPhone नियंत्रित करें", "ऑफ़लाइन सुनने के लिए iPhone के फ़ाइल ट्रांसफ़र पेज से संगीत भेजें।", "कवर और गीत के बोल", "हटाएँ", "रद्द करें", "यह फ़ाइल चलाई नहीं जा सकी।", "यह फ़ाइल सहेजी या हटाई नहीं जा सकी।", "Apple Watch की आवाज़ बदलने के लिए Digital Crown घुमाएँ।", "ठीक है", "ऑफ़लाइन सुनने के लिए पेयर की गई वॉच पर सहेजें", "Apple Watch पेयर करें और उस पर Primuse इंस्टॉल करें", "Watch ट्रांसफ़र", "Apple Watch के लिए तैयारी जारी", "Apple Watch के लिए कतार में", "वॉच की पुष्टि का इंतज़ार", "Apple Watch पर सहेजा गया"],
        "pl": ["Na Apple Watch", "Steruj iPhonem", "Wyślij muzykę ze strony przesyłania plików na iPhonie, aby słuchać offline.", "Okładki i teksty", "Usuń", "Anuluj", "Nie można odtworzyć tego pliku.", "Nie można zapisać lub usunąć tego pliku.", "Obróć Digital Crown, aby zmienić głośność Apple Watch.", "OK", "Zapisz na połączonym zegarku do słuchania offline", "Połącz Apple Watch i zainstaluj na nim Primuse", "Transfery do Watch", "Przygotowanie dla Apple Watch", "W kolejce do Apple Watch", "Oczekiwanie na potwierdzenie zegarka", "Zapisano na Apple Watch"],
        "tr": ["Apple Watch’ta", "iPhone’u kontrol et", "Çevrimdışı dinlemek için iPhone’un dosya aktarımı sayfasından müzik gönderin.", "Kapaklar ve şarkı sözleri", "Sil", "İptal", "Bu dosya çalınamadı.", "Bu dosya kaydedilemedi veya silinemedi.", "Apple Watch sesini ayarlamak için Digital Crown’u çevirin.", "Tamam", "Çevrimdışı dinlemek için eşlenmiş saate kaydet", "Apple Watch’u eşleyin ve Primuse’u yükleyin", "Watch aktarımları", "Apple Watch için hazırlanıyor", "Apple Watch için sırada", "Saatin onayı bekleniyor", "Apple Watch’a kaydedildi"],
        "th": ["บน Apple Watch", "ควบคุม iPhone", "ส่งเพลงจากหน้าถ่ายโอนไฟล์บน iPhone เพื่อฟังแบบออฟไลน์", "ปกและเนื้อเพลง", "ลบ", "ยกเลิก", "ไม่สามารถเล่นไฟล์นี้ได้", "ไม่สามารถบันทึกหรือลบไฟล์นี้ได้", "หมุน Digital Crown เพื่อปรับระดับเสียง Apple Watch", "ตกลง", "บันทึกบน Apple Watch ที่จับคู่ไว้เพื่อฟังแบบออฟไลน์", "จับคู่ Apple Watch และติดตั้ง Primuse", "การถ่ายโอนไปยัง Watch", "กำลังเตรียมสำหรับ Apple Watch", "อยู่ในคิวส่งไปยัง Apple Watch", "กำลังรอการยืนยันจากนาฬิกา", "บันทึกบน Apple Watch แล้ว"],
    ]
}
