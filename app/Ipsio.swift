// Ipsio: menu-bar app (next to the clock) that records with the native
// engine (app/Engine: ScreenCaptureKit + AVAssetWriter, no BlackHole, no ffmpeg).
// Builds without Xcode: bash install-app.sh (uses swiftc from the Command Line Tools).
//
// The engine answers run("start"), run("stop")... in the format ipsio.sh
// always answered (Backend.swift): first line = popup title, then the body.
// The app picks icon and alarm from the "#state key=value" line that ends
// every output, never from the human text: the text changes with the
// language (UI_LANGUAGE='pt'|'en' in the conf, switched by the flag item in
// the menu).
//
// What the app checks BY ITSELF while recording:
// - reads the live meter (level subcommand) every 3 s; 90 s of silence in a
//   row turn the icon yellow + an alert saying what to do. In meeting mode, the
//   same for the microphone (90 s of a DEAD microphone, not of you being quiet);
// - watches the recorder: macOS stopping the capture, or a recording left by
//   a run of the app that went down mid-way, is "stopped by itself", and the
//   app says so (the fragmented .mov keeps everything up to the last 2 s).
//
// Calendar (Schedule.swift): reads the sources every 5 min and records each
// meeting by itself, from start minus 2 min to end plus 5 min, in meeting mode,
// with the meeting's name in the file. "Upcoming recordings" shows what is
// coming and lets you skip one. The timers run in the run loop's .common mode:
// with a popup open and nobody at the Mac, the next meeting still starts and
// ends on time.
import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications

let agentLabel = "io.github.shipsfromrio.ipsio"   // LaunchAgent (install-app.sh)

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let recentMenu = NSMenu()
    let upcomingMenu = NSMenu()
    let modeMenu = NSMenu()
    let permMenu = NSMenu()
    let dir = ProcessInfo.processInfo.environment["IPSIO_DIR"] ?? (NSHomeDirectory() + "/.ipsio")
    lazy var backend: Backend = {
        var h = Host()
        #if STORE
        h.hook = nil      // the store build runs no commands
        #endif
        return Backend(dir: dir, capture: Recorder(), host: h, conf: { [unowned self] in self.readConf() })
    }()
    var timer: Timer?
    var calendarTimer: Timer?
    let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let calendarStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let recordItem = NSMenuItem(title: "", action: #selector(doRecord), keyEquivalent: "")
    let stopItem = NSMenuItem(title: "", action: #selector(doStop), keyEquivalent: "")
    let checkItem = NSMenuItem(title: "", action: #selector(doCheck), keyEquivalent: "")
    let testItem = NSMenuItem(title: "", action: #selector(doTest), keyEquivalent: "")
    let modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let modeClass = NSMenuItem(title: "", action: #selector(doModeClass), keyEquivalent: "")
    let modeMeeting = NSMenuItem(title: "", action: #selector(doModeMeeting), keyEquivalent: "")
    let upcomingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let titleItem = NSMenuItem(title: "", action: #selector(doTitle), keyEquivalent: "")
    let folderItem = NSMenuItem(title: "", action: #selector(doFolder), keyEquivalent: "")
    let recentItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let openItem = NSMenuItem(title: "", action: #selector(doOpen), keyEquivalent: "")
    let permItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let permScreen = NSMenuItem(title: "", action: #selector(doScreenPermission), keyEquivalent: "")
    let permMic = NSMenuItem(title: "", action: #selector(doMicPermission), keyEquivalent: "")
    let doctorItem = NSMenuItem(title: "", action: #selector(doDoctor), keyEquivalent: "")
    let connectItem = NSMenuItem(title: "", action: #selector(doConnectCalendar), keyEquivalent: "")
    let languageItem = NSMenuItem(title: "", action: #selector(doLanguage), keyEquivalent: "")
    // Our own action, not the system's terminate:: on macOS 26 the standard quit
    // action gets an automatic icon, which opens an icon column and indents the
    // whole menu.
    let restartItem = NSMenuItem(title: "", action: #selector(doRestart), keyEquivalent: "")
    // A real "Quit": the LaunchAgent has KeepAlive, so ending the process only
    // reopens it; quitting means unloading the agent until the next login.
    let quitItem = NSMenuItem(title: "", action: #selector(doQuit), keyEquivalent: "q")
    var confPath: String { dir + "/conf" }
    // Silence: the engine says silence=N (and mic_silence=N in meeting mode) on
    // the #state line; above this threshold the app raises the alarm. 90 s
    // covers a pause without crying wolf.
    let silenceThreshold = 90
    var alarmGiven = false       // one alert per silence episode
    var micAlarmGiven = false    // same, microphone
    var busy = false             // start/stop/test running in the background
    var readingLevel = false
    var notificationsOk = false  // system authorization; without it, a popup
    // Without the screen permission the app is useless: on launch it asks,
    // opens the pane, explains ONCE and waits; when the permission shows up,
    // it reopens by itself (macOS only applies it to a new process).
    var waitingPermission = false
    let hasBundle = Bundle.main.bundleIdentifier != nil
    var pendingModals: [() -> Void] = []   // see modal()

    // ---- calendar ----
    var meetings: [Meeting] = []
    var skipped = Set<String>()
    var calendarReadAt: Date?
    var calendarErrors: [String] = []
    let appStart = Date()                      // the stale clock with no success on record
    var staleAlerted = false                   // one notification per stale episode
    var calendarWarnings: [String] = []
    var readingCalendar = false
    var calendarFailure: [String: Date] = [:]   // id -> last attempt that failed
    var failureAlerted = Set<String>()         // one popup per meeting that did not start
    var activity: NSObjectProtocol?            // Mac awake with a meeting coming
    var skipPath: String { dir + "/calendar-skip" }
    var markerPath: String { dir + "/calendar-recording" }

    // ---- language ----
    var lang: String { Schedule.language(readConf()) }
    func t(_ k: String) -> String {
        let pt: [String: String] = [
            "stopped": "Parado", "stopped_no_perm": "Parado · falta permissão de Gravação de Tela",
            "stopped_no_mic": "Parado · falta permissão de Microfone",
            "record": "Gravar agora", "stop": "Parar e salvar", "check": "Conferir o arquivo inteiro",
            "test": "Testar agora (20 s)", "testing": "Testando (20 s)…", "recent": "Gravações recentes",
            "none": "(nenhuma ainda)", "open": "Abrir pasta das gravações", "title": "Título: %@…",
            "no_title": "(sem título)", "folder": "Pasta: %@…", "perm": "Permissões",
            "perm_screen": "Gravação de Tela…", "perm_mic": "Microfone…",
            "mode": "Modo: %@", "mode_class": "Aula (só o som do computador)", "mode_meeting": "Reunião (som do computador + seu microfone)",
            "mode_meeting_mic": "Reunião (som do computador + %@)", "class": "Aula", "meeting": "Reunião",
            "language": "Switch to English  🇺🇸", "restart": "Reiniciar o app", "quit": "Sair (até o próximo login)",
            "waiting": "Aguardando a permissão de Gravação de Tela…",
            "recording": "GRAVANDO", "measuring": "medindo o som", "disk": "disco para %@ h",
            "silent_for": "GRAVANDO SEM SOM há %@ s", "alarm_title": "SEM SOM HÁ %@ SEGUNDOS",
            "mic_dead_for": "MICROFONE MUDO há %@ s", "mic_alarm_title": "MICROFONE MUDO HÁ %@ SEGUNDOS",
            "mic_alarm_body": "A sua voz não está entrando na gravação: microfone sem permissão, no mudo ou com o volume de entrada no zero. Os outros continuam sendo gravados.",
            "died_title": "A GRAVAÇÃO PAROU SOZINHA",
            "died_body": "A gravação parou sem você pedir (o macOS parou a captura, ou o app ou o Mac caíram). O que já foi gravado está salvo no arquivo.\n\nMotivo:\n%@",
            "record_again": "Gravar de novo", "ok": "OK",
            "no_perm_title": "Falta a permissão de Gravação de Tela",
            "no_perm_body": "Em Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema, ligue \"Ipsio\". Depois use \"Reiniciar o app\" no menu e grave de novo.",
            "no_mic_title": "Falta a permissão de Microfone",
            "no_mic_body": "A reunião grava também a sua voz. Em Ajustes do Sistema > Privacidade e Segurança > Microfone, ligue \"Ipsio\".",
            "notif_recording": "Gravando", "notif_saved": "Gravação salva", "did_not_start": "Não começou a gravar",
            "volume": "Volume da gravação", "test_title": "Teste", "no_log": "(sem log)",
            "title_title": "Título das gravações",
            "title_body": "Entra no nome do arquivo, depois da data e hora. Ex.: 2026-09-12_10-37 Curso de exemplo.mov. Vale para as próximas gravações feitas à mão até você trocar. As da agenda usam o nome da reunião.",
            "save": "Salvar", "cancel": "Cancelar", "use_folder": "Usar esta pasta", "where": "Onde guardar as gravações",
            "verdict_NO_SOUND": "SEM SOM", "verdict_LOW": "SOM BAIXO", "verdict_LOUD": "SOM ALTO", "verdict_OK": "SOM OK",
            "upcoming": "Próximas gravações", "calendar_auto": "Gravar as reuniões da agenda sozinho",
            "calendar_read_now": "Ler a agenda agora", "calendar_no_source": "(nenhuma agenda: use Conectar agenda… no menu)",
            "calendar_empty": "(nenhuma reunião com link nos próximos 7 dias)",
            "calendar_read_at": "Agenda lida às %@", "calendar_failed": "Agenda: falhou às %@ (valendo a última leitura)",
            "calendar_reading": "Lendo a agenda…", "calendar_warnings": "%@ aviso(s): rode ipsio-calendar no Terminal",
            "calendar_skipped": "  (pulada)", "calendar_off": "Agenda: gravação automática desligada",
            "next": "Próxima: %@", "recording_calendar": "Gravando da agenda: %@",
            "notif_calendar": "Gravando a reunião", "notif_calendar_body": "%@, até %@. Para pular: Próximas gravações.",
            "calendar_did_not_start": "A reunião \"%@\" não começou a gravar",
            "today": "hoje", "tomorrow": "amanhã", "wake_reason": "Ipsio: reunião da agenda chegando",
            "doctor": "Conferir a instalação", "doctor_title": "Instalação",
            "connect": "Conectar agenda…", "connect_again": "Trocar a agenda conectada…",
            "connect_title": "Conectar a sua agenda",
            "connect_body": "Cole o endereço secreto da agenda no formato iCal (no Google Agenda: Configurações > a sua agenda > Endereço secreto no formato iCal). Ele é uma senha: fica só neste Mac, legível só por você, e nunca aparece na tela.",
            "connect_reading": "Lendo a agenda…", "connect_ok_title": "Agenda conectada",
            "connect_ok_body": "%@ reunião(ões) com link nos próximos 7 dias. Elas aparecem em Próximas gravações.",
            "connect_fail_title": "A agenda não foi conectada", "connect_fail_body": "%@\n\nNada foi trocado: continua valendo a agenda anterior, se havia uma.",
            "connect_button": "Conectar",
            "connect_replaces": "Atenção: hoje há %@ endereços em calendar.url, e este substitui todos.",
            "calendar_stale": "⚠ Agenda sem atualizar desde %@", "calendar_never": "a abertura do app",
            "calendar_stale_title": "A agenda parou de atualizar",
            "script_timeout_title": "O Ipsio não respondeu",
            "script_timeout_body": "O passo “%@” passou de %@ s e foi interrompido. Costuma ser a captura de tela travada: reinicie o Mac e tente de novo.",
            "check_running": "Ainda conferindo o arquivo anterior.",
            "calendar_stale_body": "A leitura falha desde %@. O Ipsio segue gravando pela última leitura, mas reunião marcada depois disso não entra. Motivo: %@",
            "connect_choice_body": "De onde o Ipsio lê as suas reuniões? O Calendário do Mac já tem as contas que você adicionou nele (Google, iCloud, Exchange): basta um \"Permitir\". O endereço iCal serve para uma agenda que não está no Calendário.",
            "connect_mac": "Calendário do Mac (recomendado)", "connect_ical": "Endereço iCal…",
            "connect_mac_ok_body": "O Ipsio passa a ler o Calendário do Mac. As reuniões com link aparecem em Próximas gravações em alguns segundos.",
            "connect_mac_denied": "O macOS não deu acesso aos Calendários. Em Ajustes do Sistema > Privacidade e Segurança > Calendários, ligue \"Ipsio\" e conecte de novo.",
            "setup_title": "Configurar o Ipsio",
            "setup_intro": "O Ipsio precisa destes itens para gravar. Cada linha fica verde sozinha quando ficar pronta: pode resolver na ordem que quiser.",
            "setup_zoom": "Nada para mudar no Zoom, Teams ou Meet: o Ipsio grava o som que o Mac toca, no alto-falante que você já usa.",
            "setup_close": "Fechar", "setup_checking": "Conferindo…", "setup_missing": "falta",
            "setup_ready": "Tudo pronto. Faça um teste de 20 s.", "setup_left_one": "Falta 1 item.", "setup_left": "Faltam %@ itens.",
            "setup_script": "O gravador respondeu", "setup_script_hint": "O gravador não respondeu à conferência. Reinicie o app.",
            "setup_dir": "Pasta de configuração", "setup_dir_hint": "Não consegui criar a pasta de configuração do Ipsio (~/.ipsio). Confira as permissões da sua pasta pessoal.",
            "setup_ffmpeg": "ffmpeg, o gravador", "setup_ffmpeg_hint": "Instala pelo Homebrew, sem senha.",
            "setup_switchaudio": "SwitchAudioSource, que troca a saída de som", "setup_switchaudio_hint": "Instala pelo Homebrew, sem senha.",
            "setup_blackhole": "BlackHole, que capta o som do computador", "setup_blackhole_hint": "Instala pelo Homebrew e pede a senha do Mac. Se não aparecer depois, reinicie o Mac.",
            "setup_device": "Saída de som \"%@\"", "setup_device_hint": "Toca no seu alto-falante e manda o mesmo som para o gravador. Um clique cria.",
            "setup_screen": "Tela visível para o gravador", "setup_screen_hint": "O ffmpeg não encontrou a tela. Reinicie o Mac e confira de novo.",
            "setup_screen_permission": "Permissão de Gravação de Tela", "setup_screen_permission_hint": "Em Ajustes, ligue \"Ipsio\" na lista. O app fecha quando a permissão entrar e volta sozinho (se não voltar, abra o Ipsio de novo).",
            "setup_mic_permission": "Permissão de Microfone", "setup_mic_permission_hint": "A reunião grava a sua voz.",
            "setup_microphone": "Microfone do modo reunião", "setup_microphone_hint": "O Mac não tem entrada de som. Conecte um microfone, ou mude para o modo aula no menu.",
            "setup_folder": "Pasta das gravações", "setup_folder_hint": "Não consegui criar a pasta. Escolha outra.",
            "setup_disk": "Espaço em disco", "setup_disk_hint": "Pouco espaço: uma hora de gravação ocupa cerca de 2 GB. Libere espaço ou escolha uma pasta em outro disco.",
            "setup_other": "Outro item", "setup_other_hint": "O gravador acusou um item que esta janela ainda não conhece. Atualize o Ipsio.",
            "setup_calendar": "Agenda (opcional)", "setup_calendar_hint": "Conecte a sua agenda para o Ipsio gravar as reuniões sozinho.",
            "fix_install": "Instalar", "fix_create": "Criar", "fix_settings": "Abrir Ajustes", "fix_allow": "Permitir",
            "fix_sound": "Abrir Som", "fix_folder": "Escolher pasta", "fix_calendar": "Conectar",
            "device_failed": "Não consegui criar a saída de som", "device_failed_body": "Rode o install.sh no Terminal, ou crie em Configuração de Áudio e MIDI um dispositivo de saída múltipla chamado \"%@\".",
        ]
        let en: [String: String] = [
            "stopped": "Stopped", "stopped_no_perm": "Stopped · Screen Recording permission missing",
            "stopped_no_mic": "Stopped · Microphone permission missing",
            "record": "Record now", "stop": "Stop and save", "check": "Check the whole file",
            "test": "Test now (20 s)", "testing": "Testing (20 s)…", "recent": "Recent recordings",
            "none": "(none yet)", "open": "Open recordings folder", "title": "Title: %@…",
            "no_title": "(no title)", "folder": "Folder: %@…", "perm": "Permissions",
            "perm_screen": "Screen Recording…", "perm_mic": "Microphone…",
            "mode": "Mode: %@", "mode_class": "Class (computer sound only)", "mode_meeting": "Meeting (computer sound + your microphone)",
            "mode_meeting_mic": "Meeting (computer sound + %@)", "class": "Class", "meeting": "Meeting",
            "language": "Mudar para português  🇧🇷", "restart": "Restart the app", "quit": "Quit (until next login)",
            "waiting": "Waiting for the Screen Recording permission…",
            "recording": "RECORDING", "measuring": "measuring sound", "disk": "disk for %@ h",
            "silent_for": "RECORDING WITHOUT SOUND for %@ s", "alarm_title": "NO SOUND FOR %@ SECONDS",
            "mic_dead_for": "MICROPHONE DEAD for %@ s", "mic_alarm_title": "MICROPHONE DEAD FOR %@ SECONDS",
            "mic_alarm_body": "Your voice is not getting into the recording: microphone without permission, muted, or input volume at zero. The others are still being recorded.",
            "died_title": "THE RECORDING STOPPED BY ITSELF",
            "died_body": "The recording stopped without you asking (macOS stopped the capture, or the app or the Mac went down). What was already recorded is saved in the file.\n\nReason:\n%@",
            "record_again": "Record again", "ok": "OK",
            "no_perm_title": "Screen Recording permission missing",
            "no_perm_body": "In System Settings > Privacy & Security > Screen & System Audio Recording, enable \"Ipsio\". Then use \"Restart the app\" in the menu and record again.",
            "no_mic_title": "Microphone permission missing",
            "no_mic_body": "Meetings also record your voice. In System Settings > Privacy & Security > Microphone, enable \"Ipsio\".",
            "notif_recording": "Recording", "notif_saved": "Recording saved", "did_not_start": "Did not start recording",
            "volume": "Recording volume", "test_title": "Test", "no_log": "(no log)",
            "title_title": "Recording title",
            "title_body": "Goes into the file name, after date and time. E.g. 2026-09-12_10-37 Sample course.mov. Applies to the next manual recordings until you change it. Calendar recordings use the meeting name.",
            "save": "Save", "cancel": "Cancel", "use_folder": "Use this folder", "where": "Where to keep the recordings",
            "verdict_NO_SOUND": "NO SOUND", "verdict_LOW": "SOUND TOO LOW", "verdict_LOUD": "SOUND TOO LOUD", "verdict_OK": "SOUND OK",
            "upcoming": "Upcoming recordings", "calendar_auto": "Record calendar meetings automatically",
            "calendar_read_now": "Read the calendar now", "calendar_no_source": "(no calendar: use Connect calendar… in the menu)",
            "calendar_empty": "(no meeting with a link in the next 7 days)",
            "calendar_read_at": "Calendar read at %@", "calendar_failed": "Calendar: failed at %@ (using the last reading)",
            "calendar_reading": "Reading the calendar…", "calendar_warnings": "%@ warning(s): run ipsio-calendar in Terminal",
            "calendar_skipped": "  (skipped)", "calendar_off": "Calendar: automatic recording off",
            "next": "Next: %@", "recording_calendar": "Recording from calendar: %@",
            "notif_calendar": "Recording the meeting", "notif_calendar_body": "%@, until %@. To skip: Upcoming recordings.",
            "calendar_did_not_start": "The meeting \"%@\" did not start recording",
            "today": "today", "tomorrow": "tomorrow", "wake_reason": "Ipsio: calendar meeting coming up",
            "doctor": "Check setup", "doctor_title": "Setup",
            "connect": "Connect calendar…", "connect_again": "Replace the connected calendar…",
            "connect_title": "Connect your calendar",
            "connect_body": "Paste the calendar's secret address in iCal format (in Google Calendar: Settings > your calendar > Secret address in iCal format). It is a password: it stays on this Mac, readable only by you, and is never shown on screen.",
            "connect_reading": "Reading the calendar…", "connect_ok_title": "Calendar connected",
            "connect_ok_body": "%@ meeting(s) with a link in the next 7 days. They show up under Upcoming recordings.",
            "connect_fail_title": "The calendar was not connected", "connect_fail_body": "%@\n\nNothing was replaced: the previous calendar, if any, still applies.",
            "connect_button": "Connect",
            "connect_replaces": "Note: calendar.url holds %@ addresses today, and this one replaces all of them.",
            "calendar_stale": "⚠ Calendar not updated since %@", "calendar_never": "the app opened",
            "calendar_stale_title": "The calendar stopped updating",
            "script_timeout_title": "Ipsio did not answer",
            "script_timeout_body": "The step “%@” took over %@ s and was stopped. It is usually a wedged screen capture: restart the Mac and try again.",
            "check_running": "Still checking the previous file.",
            "calendar_stale_body": "Reading has failed since %@. Ipsio keeps recording from the last reading, but a meeting added after that will be missed. Reason: %@",
            "connect_choice_body": "Where should Ipsio read your meetings from? The Mac's Calendar already has the accounts you added to it (Google, iCloud, Exchange): one \"Allow\" is enough. The iCal address is for a calendar that is not in Calendar.",
            "connect_mac": "Mac's Calendar (recommended)", "connect_ical": "iCal address…",
            "connect_mac_ok_body": "Ipsio now reads the Mac's Calendar. Meetings with a link show up under Upcoming recordings in a few seconds.",
            "connect_mac_denied": "macOS did not grant access to Calendars. In System Settings > Privacy & Security > Calendars, turn on \"Ipsio\" and connect again.",
            "setup_title": "Set up Ipsio",
            "setup_intro": "Ipsio needs these to record. Each line turns green by itself once it is ready, so fix them in any order.",
            "setup_zoom": "Nothing to change in Zoom, Teams or Meet: Ipsio records the sound the Mac plays, on the speaker you already use.",
            "setup_close": "Close", "setup_checking": "Checking…", "setup_missing": "missing",
            "setup_ready": "All set. Run a 20 s test.", "setup_left_one": "1 item left.", "setup_left": "%@ items left.",
            "setup_script": "The recorder answered", "setup_script_hint": "The recorder did not answer the check. Restart the app.",
            "setup_dir": "Settings folder", "setup_dir_hint": "Could not create Ipsio's settings folder (~/.ipsio). Check the permissions of your home folder.",
            "setup_ffmpeg": "ffmpeg, the recorder", "setup_ffmpeg_hint": "Installs through Homebrew, no password.",
            "setup_switchaudio": "SwitchAudioSource, which switches the sound output", "setup_switchaudio_hint": "Installs through Homebrew, no password.",
            "setup_blackhole": "BlackHole, which captures the computer sound", "setup_blackhole_hint": "Installs through Homebrew and asks for the Mac's password. If it does not show up afterwards, restart the Mac.",
            "setup_device": "Sound output \"%@\"", "setup_device_hint": "Plays on your speaker and sends the same sound to the recorder. One click creates it.",
            "setup_screen": "Screen visible to the recorder", "setup_screen_hint": "ffmpeg did not find the screen. Restart the Mac and check again.",
            "setup_screen_permission": "Screen Recording permission", "setup_screen_permission_hint": "In Settings, turn on \"Ipsio\" in the list. The app closes once the permission is in and comes back by itself (if it does not, open Ipsio again).",
            "setup_mic_permission": "Microphone permission", "setup_mic_permission_hint": "Meetings record your voice.",
            "setup_microphone": "Microphone for meeting mode", "setup_microphone_hint": "The Mac has no sound input. Connect a microphone, or switch to class mode in the menu.",
            "setup_folder": "Recordings folder", "setup_folder_hint": "Could not create the folder. Pick another one.",
            "setup_disk": "Disk space", "setup_disk_hint": "Low on space: an hour of recording takes about 2 GB. Free some space or pick a folder on another disk.",
            "setup_other": "Another item", "setup_other_hint": "The recorder reported an item this window does not know yet. Update Ipsio.",
            "setup_calendar": "Calendar (optional)", "setup_calendar_hint": "Connect your calendar so Ipsio records meetings by itself.",
            "fix_install": "Install", "fix_create": "Create", "fix_settings": "Open Settings", "fix_allow": "Allow",
            "fix_sound": "Open Sound", "fix_folder": "Choose folder", "fix_calendar": "Connect",
            "device_failed": "Could not create the sound output", "device_failed_body": "Run install.sh in Terminal, or create a multi-output device named \"%@\" in Audio MIDI Setup.",
        ]
        return (lang == "pt" ? pt : en)[k] ?? k
    }
    func t(_ k: String, _ a: String) -> String { t(k).replacingOccurrences(of: "%@", with: a) }
    func t(_ k: String, _ a: String, _ b: String) -> String {
        guard let r = t(k).range(of: "%@") else { return t(k) }
        var s = t(k); s.replaceSubrange(r, with: a)
        return s.replacingOccurrences(of: "%@", with: b)
    }

    // ---- conf ----
    func readConf() -> [String: String] {
        var d: [String: String] = [:]
        guard let s = try? String(contentsOfFile: confPath, encoding: .utf8) else { return d }
        for l in s.components(separatedBy: CharacterSet.newlines) {
            guard let i = l.firstIndex(of: "=") else { continue }
            var v = String(l[l.index(after: i)...])
            if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 { v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'") }
            d[String(l[..<i])] = v
        }
        return d
    }
    func writeConf(_ d: [String: String]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lines = d.keys.sorted().map { k in "\(k)='" + d[k]!.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: confPath, atomically: true, encoding: .utf8)
    }
    func currentFolder() -> String { readConf()["RECORDINGS_DIR"] ?? (NSHomeDirectory() + "/Movies/Ipsio") }
    var mode: String { readConf()["MODE"] == "meeting" ? "meeting" : "class" }
    var calendarAuto: Bool { (readConf()["CALENDAR_AUTO"] ?? "1") != "0" }
    func minutes(_ k: String, _ fallback: Double) -> TimeInterval { (Double(readConf()[k] ?? "") ?? fallback) * 60 }

    func applicationDidFinishLaunching(_ n: Notification) {
        // A single instance: a kickstart on top of an app opened outside launchd
        // once left two circles in the bar.
        if let bid = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 { NSApp.terminate(nil); return }
        // Private, like install-app.sh makes it: conf may hold a token in
        // CALENDAR_COMMAND, and the cache has meeting titles and links.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without this NSMenu re-enables every item that has an action by
        // itself, and "Record" stayed clickable during a recording.
        for m in [menu, recentMenu, upcomingMenu, modeMenu, permMenu] { m.autoenablesItems = false }
        for m in [recordItem, stopItem, checkItem, testItem, modeClass, modeMeeting, titleItem, folderItem, openItem, permScreen, permMic, doctorItem, connectItem, languageItem, restartItem, quitItem] { m.target = self }
        statusItem.isEnabled = false; calendarStatus.isEnabled = false
        menu.addItem(statusItem); menu.addItem(calendarStatus); menu.addItem(.separator())
        menu.addItem(recordItem); menu.addItem(stopItem); menu.addItem(checkItem); menu.addItem(testItem); menu.addItem(.separator())
        modeMenu.addItem(modeClass); modeMenu.addItem(modeMeeting); modeItem.submenu = modeMenu; menu.addItem(modeItem)
        upcomingItem.submenu = upcomingMenu; menu.addItem(upcomingItem)
        recentItem.submenu = recentMenu; menu.addItem(recentItem)
        menu.addItem(openItem); menu.addItem(titleItem); menu.addItem(folderItem)
        permMenu.addItem(permScreen); permMenu.addItem(permMic); permItem.submenu = permMenu; menu.addItem(permItem)
        menu.addItem(connectItem); menu.addItem(doctorItem)
        menu.addItem(.separator()); menu.addItem(languageItem); menu.addItem(restartItem); menu.addItem(quitItem)
        menu.delegate = self
        item.menu = menu
        // The notification center throws (and kills the app) outside an .app
        // bundle, e.g. the bare binary run from Terminal; there, popups only.
        if hasBundle {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { self.notificationsOk = ok } }
        }
        MacCalendar.install()
        skipped = Set(((try? String(contentsOfFile: skipPath, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
        meetings = Sources(dir: dir, conf: readConf()).readCache()
        refresh()
        // .common: the timers keep running with a popup open (NSAlert runs the
        // run loop in modal mode, and in the default mode a timer just stops).
        let t1 = Timer(timeInterval: 3, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t1, forMode: .common); timer = t1
        let t2 = Timer(timeInterval: 300, repeats: true) { _ in self.readCalendar() }
        RunLoop.main.add(t2, forMode: .common); calendarTimer = t2
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in self.readCalendar() }
        readCalendar()
        // Microphone first (one "Allow" on the spot), screen after (Settings pane).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        }
        if !CGPreflightScreenCaptureAccess() { askScreenPermission() }
        openSetupIfNeeded()
    }

    /// Without the screen permission the app waits for it (tick reopens the app
    /// when it comes in). The explanation and the button live in the setup
    /// window, which opens right after this; no popup on top of it.
    func askScreenPermission() {
        waitingPermission = true
        CGRequestScreenCaptureAccess()          // puts the app in the Settings list
        icon("exclamationmark.circle", color: .systemYellow)
        statusItem.title = t("waiting")
        recordItem.isEnabled = false; testItem.isEnabled = false
    }

    func micOk() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// The app's preflight, before the engine's: the permissions only the
    /// Mac's screen can grant. The microphone only matters in a meeting: the
    /// computer sound comes from ScreenCaptureKit, not from an audio input.
    /// Returns false and explains, without recording.
    func permissionsOk(explain: Bool, meeting: Bool) -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            if explain { alert(t("no_perm_title"), t("no_perm_body")) }
            return false
        }
        guard meeting else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
            return false
        default:
            if explain { doMicPermission(); alert(t("no_mic_title"), t("no_mic_body")) }
            return false
        }
    }

    // Notifications even with the app in front (the default hides them).
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner, .sound]) }
    // Clicking the "saved" notification shows the recording in Finder.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        if let p = r.notification.request.content.userInfo["file"] as? String, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
        h()
    }
    // Tells without asking for a decision: a notification if the system allows, else a popup.
    func notify(_ title: String, _ body: String, file: String? = nil) {
        if notificationsOk && hasBundle {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            if let f = file { c.userInfo = ["file": f] }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            alert(title, body)
        }
    }

    // Submenus are built when the menu opens.
    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === menu else { return }
        buildRecent()
        buildUpcoming()
        let mic = run("microphone").trimmingCharacters(in: .whitespacesAndNewlines)
        modeClass.title = t("mode_class")
        modeMeeting.title = mic.isEmpty ? t("mode_meeting") : t("mode_meeting_mic", mic)
    }
    func buildRecent() {
        recentMenu.removeAllItems()
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: currentFolder()), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { ["mov", "mkv"].contains($0.pathExtension.lowercased()) }   // mkv: recordings of the script engine
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db }
            .prefix(5)
        if urls.isEmpty { let v = NSMenuItem(title: t("none"), action: nil, keyEquivalent: ""); v.isEnabled = false; recentMenu.addItem(v) }
        for u in urls {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mi = NSMenuItem(title: "\(u.lastPathComponent)  ·  \(String(format: "%.1f GB", Double(size) / 1_073_741_824))", action: #selector(doOpenRecent(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = u; recentMenu.addItem(mi)
        }
    }
    @objc func doOpenRecent(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func when(_ d: Date) -> String {
        let cal = Calendar.current, f = DateFormatter()
        f.locale = Locale(identifier: lang == "pt" ? "pt_BR" : "en_US")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return t("today") + " " + f.string(from: d) }
        if cal.isDateInTomorrow(d) { f.dateFormat = "HH:mm"; return t("tomorrow") + " " + f.string(from: d) }
        f.dateFormat = "EEE dd/MM HH:mm"; return f.string(from: d)
    }
    func shortTime(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    func buildUpcoming() {
        upcomingMenu.removeAllItems()
        let sources = Sources(dir: dir, conf: readConf())
        func info(_ s: String) { let v = NSMenuItem(title: s, action: nil, keyEquivalent: ""); v.isEnabled = false; upcomingMenu.addItem(v) }
        if sources.configured.isEmpty {
            info(t("calendar_no_source"))
        } else {
            let list = Schedule.upcoming(now: Date(), meetings: meetings, after: minutes("CALENDAR_AFTER_MIN", 5), n: 10)
            if list.isEmpty { info(t("calendar_empty")) }
            let recordingId = readMarker()?.id
            for e in list {
                let isSkipped = skipped.contains(e.id)
                var title = "\(when(e.start))–\(shortTime(e.end))  \(e.title)"
                if e.id == recordingId { title = "● " + title }
                if isSkipped { title += t("calendar_skipped") }
                let mi = NSMenuItem(title: title, action: #selector(doSkip(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = e.id; mi.state = isSkipped || !calendarAuto ? .off : .on
                upcomingMenu.addItem(mi)
            }
            upcomingMenu.addItem(.separator())
            if readingCalendar { info(t("calendar_reading")) }
            else if !calendarErrors.isEmpty, let q = calendarReadAt { info(t("calendar_failed", shortTime(q))) }
            else if let q = calendarReadAt { info(t("calendar_read_at", shortTime(q))) }
            for e in calendarErrors.prefix(3) { info("  " + e) }
            if !calendarWarnings.isEmpty { info(t("calendar_warnings", String(calendarWarnings.count))) }
        }
        let auto = NSMenuItem(title: t("calendar_auto"), action: #selector(doCalendarAuto), keyEquivalent: "")
        auto.target = self; auto.state = calendarAuto ? .on : .off; auto.isEnabled = !sources.configured.isEmpty
        upcomingMenu.addItem(auto)
        let read = NSMenuItem(title: t("calendar_read_now"), action: #selector(doReadCalendar), keyEquivalent: "")
        read.target = self; read.isEnabled = !sources.configured.isEmpty && !readingCalendar
        upcomingMenu.addItem(read)
    }

    // ---- script ----
    /// The engine, in the script's output format. Blocking: call it off the
    /// main thread (start waits for ScreenCaptureKit, at most 30 s).
    func run(_ cmd: String, env: [String: String] = [:]) -> String { backend.run(cmd, env: env) }
    // Splits the script output into: title (first line), body (the rest,
    // without the machine line) and the dictionary of the "#state key=value ..." line.
    struct Output { let title: String; let body: String; let state: [String: String] }
    func parse(_ s: String) -> Output {
        var st: [String: String] = [:]
        var lines = s.components(separatedBy: CharacterSet.newlines)
        if let i = lines.lastIndex(where: { $0.hasPrefix("#state") }) {
            // values with spaces run up to the next " key="; file= is always
            // last and takes the rest of the line (a title may hold "word=").
            var rest = String(lines[i].dropFirst("#state".count))
            if let r = rest.range(of: " file=") { st["file"] = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) }
            var curKey = "", value = ""
            for tok in rest.split(separator: " ", omittingEmptySubsequences: false) {
                if let eq = tok.firstIndex(of: "="), tok[..<eq].allSatisfy({ $0.isLetter || $0 == "_" }), !tok[..<eq].isEmpty {
                    if !curKey.isEmpty { st[curKey] = value }
                    curKey = String(tok[..<eq]); value = String(tok[tok.index(after: eq)...])
                } else { value += " " + tok }
            }
            if !curKey.isEmpty { st[curKey] = value }
            lines.remove(at: i)
        }
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(title: title, body: body, state: st)
    }

    func recording() -> Bool { backend.recording }
    // The watcher's signal: macOS stopped the capture, or a recording of a
    // previous run was left with nothing capturing it (see Backend).
    func diedByItself() -> Bool { backend.diedByItself }
    func currentFile() -> String? { backend.currentFile }

    func icon(_ name: String, color: NSColor?) {
        if let color = color {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ipsio")?.withSymbolConfiguration(cfg)
            img?.isTemplate = false
            item.button?.image = img
        } else {
            // Stopped: a template, which the system paints white on a dark bar and black on a light one.
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ipsio")
            img?.isTemplate = true
            item.button?.image = img
        }
    }

    func refresh() {
        Schedule.lang = lang
        if waitingPermission { return }
        let on = recording()
        if !on {
            icon("record.circle", color: nil)
            statusItem.title = !CGPreflightScreenCaptureAccess() ? t("stopped_no_perm") : (mode == "meeting" && !micOk() ? t("stopped_no_mic") : t("stopped"))
        }
        recordItem.isEnabled = !on && !busy; stopItem.isEnabled = on && !busy; checkItem.isEnabled = on; testItem.isEnabled = !on && !busy
        recordItem.title = t("record"); stopItem.title = t("stop"); checkItem.title = t("check"); testItem.title = busy && !on ? t("testing") : t("test")
        modeItem.title = t("mode", mode == "meeting" ? t("meeting") : t("class"))
        modeClass.state = mode == "class" ? .on : .off; modeMeeting.state = mode == "meeting" ? .on : .off
        upcomingItem.title = t("upcoming"); recentItem.title = t("recent"); openItem.title = t("open")
        permItem.title = t("perm"); permScreen.title = t("perm_screen"); permMic.title = t("perm_mic")
        doctorItem.title = t("doctor"); doctorItem.isEnabled = !busy
        connectItem.title = Sources(dir: dir, conf: readConf()).configured.contains { $0 == "ics" || $0 == "macos" } ? t("connect_again") : t("connect")
        languageItem.title = t("language"); restartItem.title = t("restart"); quitItem.title = t("quit")
        // The recording lives in this process now: restarting would cut it.
        restartItem.isEnabled = !on && !busy
        let c = readConf()
        let title = c["TITLE"] ?? ""
        titleItem.title = t("title", title.isEmpty ? t("no_title") : title)
        folderItem.title = t("folder", (currentFolder() as NSString).abbreviatingWithTildeInPath)
        // Second line: the calendar in one sentence.
        let sources = Sources(dir: dir, conf: c)
        if sources.configured.isEmpty { calendarStatus.isHidden = true }
        else {
            calendarStatus.isHidden = false
            let lastOk = sources.readLastOk()
            if let m = readMarker(), on { calendarStatus.title = t("recording_calendar", m.title) }
            else if Schedule.stale(configured: true, lastOk: lastOk, start: appStart, now: Date()) {
                calendarStatus.title = t("calendar_stale", lastOk.map { when($0) } ?? t("calendar_never"))
            }
            else if !calendarAuto { calendarStatus.title = t("calendar_off") }
            else if let p = Schedule.upcoming(now: Date(), meetings: meetings, after: 0, n: 20).first(where: { !skipped.contains($0.id) && $0.start > Date() }) {
                calendarStatus.title = t("next", when(p.start) + " · " + p.title)
            } else { calendarStatus.title = t("calendar_empty") }
        }
    }

    // 3 s timer: watcher + live meter + calendar. Nothing here blocks the UI:
    // whatever calls the script runs off the main thread.
    func tick() {
        if waitingPermission {
            // The permission came in: only a new process sees it. The
            // LaunchAgent (KeepAlive) reopens the app right away.
            if CGPreflightScreenCaptureAccess() { NSApp.terminate(nil) }
            return
        }
        if busy { return }
        if diedByItself() {
            let log = logTail()
            busy = true                                            // a single alert: stop clears the signal
            DispatchQueue.global().async {
                _ = self.run("stop")                               // closes the file, writes the .sha256
                DispatchQueue.main.async {
                    self.busy = false; self.refresh()
                    if let m = self.readMarker() {
                        // From the calendar: the next tick re-records by itself
                        // if the meeting is still in its window, after a 60 s
                        // pause (a recorder that keeps dying must not restart
                        // every 3 s). A popup here would only get in the way.
                        self.calendarFailure[m.id] = Date()
                        self.deleteMarker()
                        self.notify(self.t("died_title"), m.title + "\n" + log)
                        return
                    }
                    self.modal({
                        let a = NSAlert()
                        a.messageText = self.t("died_title")
                        a.informativeText = self.t("died_body", log)
                        a.addButton(withTitle: self.t("record_again")); a.addButton(withTitle: self.t("ok"))
                        return a
                    }) { if $0 == .alertFirstButtonReturn { self.doRecord() } }
                }
            }
            return
        }
        decideCalendar()
        guard recording(), !readingLevel else { if !recording() { refresh() }; return }
        readingLevel = true
        DispatchQueue.global().async {
            let r = self.run("level")
            DispatchQueue.main.async { self.readingLevel = false; if self.recording() { self.applyLevel(r) } }
        }
    }

    func applyLevel(_ output: String) {
        let s = parse(output)
        let verdict = s.state["verdict"] ?? ""
        let silentSeconds = Int(s.state["silence"] ?? "") ?? 0
        let meeting = s.state["mode"] == "meeting"
        let micSilence = Int(s.state["mic_silence"] ?? "") ?? 0
        let time = s.state["time"] ?? "", size = s.state["size"] ?? "", diskH = s.state["disk_h"] ?? ""
        let alarm = verdict == "NO_SOUND" && silentSeconds >= silenceThreshold
        let micAlarm = meeting && micSilence >= silenceThreshold
        if alarm || micAlarm {
            icon("exclamationmark.circle.fill", color: .systemYellow)
            statusItem.title = [alarm ? t("silent_for", String(silentSeconds)) : "", micAlarm ? t("mic_dead_for", String(micSilence)) : "", time].filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            icon("record.circle.fill", color: .systemRed)
            let v = verdict == "MEASURING" ? t("measuring") : t("verdict_" + verdict)
            let disk = diskH.isEmpty ? "" : t("disk", diskH)
            statusItem.title = [t("recording"), time, size.isEmpty ? "" : size + "B", v, meeting ? "🎙" : "", disk].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if verdict != "NO_SOUND" { alarmGiven = false }
        if micSilence == 0 { micAlarmGiven = false }
        recordItem.isEnabled = false; stopItem.isEnabled = !busy; checkItem.isEnabled = true; testItem.isEnabled = false
        if alarm && !alarmGiven {
            alarmGiven = true
            alert(t("alarm_title", String(silentSeconds)),
                  s.body.components(separatedBy: "\n").filter { !$0.contains("\(silentSeconds) s") }.joined(separator: "\n"))
        }
        if micAlarm && !micAlarmGiven {
            micAlarmGiven = true
            alert(t("mic_alarm_title", String(micSilence)), t("mic_alarm_body"))
        }
    }

    func logTail() -> String { backend.whyItDied ?? t("no_log") }

    /// Every popup the app opens on its own goes through here. NSAlert.runModal
    /// inside a DispatchQueue.main block holds the main queue (it is serial)
    /// until someone clicks: every other main.async waits, including the end of
    /// a calendar stop (busy=false, marker removed), so ONE forgotten popup
    /// stopped every later meeting from recording. Opened from
    /// perform(selector), the main queue keeps draining under the popup.
    /// Measured on 05/10/2026 with a real NSAlert: false inside main.async,
    /// true from perform(selector). Popups opened straight from a menu click
    /// (title, folder, connect calendar) are not in a queue block and stay as they are.
    func modal(_ build: @escaping () -> NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        let job = { NSApp.activate(ignoringOtherApps: true); then(build().runModal()) }
        let enqueue = {
            self.pendingModals.append(job)
            self.perform(#selector(self.runPendingModal), with: nil, afterDelay: 0, inModes: [.common])
        }
        if Thread.isMainThread { enqueue() } else { DispatchQueue.main.async(execute: enqueue) }
    }
    @objc func runPendingModal() {
        guard !pendingModals.isEmpty else { return }
        pendingModals.removeFirst()()
    }
    func alert(_ title: String, _ text: String) {
        modal { let a = NSAlert(); a.messageText = title; a.informativeText = text; return a }
    }
    func alertFromScript(_ output: String, title: String) {
        let s = parse(output)
        alert(s.title.isEmpty ? title : s.title, s.body)
    }

    // ============================================================ calendar ===
    struct Marker { let id: String; let title: String }
    func readMarker() -> Marker? {
        guard let s = try? String(contentsOfFile: markerPath, encoding: .utf8) else { return nil }
        let p = s.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        return p.count >= 2 ? Marker(id: p[0], title: p[1]) : nil
    }
    func writeMarker(_ e: Meeting) { try? (Schedule.clean(e.id) + "\t" + Schedule.clean(e.title) + "\n").write(toFile: markerPath, atomically: true, encoding: .utf8) }
    func deleteMarker() { try? FileManager.default.removeItem(atPath: markerPath) }
    func writeSkipped() {
        // Keeps only what is still in the calendar: the list does not grow forever.
        let alive = Set(meetings.map { $0.id })
        skipped = skipped.intersection(alive)
        try? (skipped.sorted().joined(separator: "\n") + "\n").write(toFile: skipPath, atomically: true, encoding: .utf8)
    }

    func readCalendar() {
        let sources = Sources(dir: dir, conf: readConf())
        // No source left (calendar.url deleted, list removed): forget what the
        // removed calendar had, or it would keep starting recordings.
        if sources.configured.isEmpty { meetings = []; calendarErrors = []; calendarWarnings = []; return }
        guard !readingCalendar else { return }
        readingCalendar = true
        DispatchQueue.global().async {
            let r = sources.read()
            let merged = Schedule.merge(fresh: r.meetings, sourcesOk: r.sourcesOk, cache: sources.readCache())
            sources.writeCache(merged)
            DispatchQueue.main.async {
                self.readingCalendar = false
                self.meetings = merged; self.calendarErrors = r.errors; self.calendarWarnings = r.warnings
                self.calendarReadAt = Date()
                // Only a reading where EVERY source answered resets the stale clock.
                if r.errors.isEmpty && !r.sourcesOk.isEmpty { sources.writeLastOk(Date()) }
                let lastOk = sources.readLastOk()
                if Schedule.stale(configured: true, lastOk: lastOk, start: self.appStart, now: Date()) {
                    if !self.staleAlerted {
                        self.staleAlerted = true
                        self.notify(self.t("calendar_stale_title"),
                                    self.t("calendar_stale_body", lastOk.map { self.when($0) } ?? self.t("calendar_never"), r.errors.first ?? "-"))
                    }
                } else { self.staleAlerted = false }
                self.writeSkipped()
                self.refresh()
            }
        }
    }

    /// One decision per tick: the meeting that should be recording now
    /// (Schedule.target) against what is recording. The calendar only touches
    /// what it started itself (marker in ~/.ipsio/calendar-recording); a manual
    /// recording is never stopped or replaced by it.
    func decideCalendar() {
        let now = Date()
        let target = Schedule.target(now: now, meetings: meetings, skipped: skipped,
                                     before: minutes("CALENDAR_BEFORE_MIN", 2), after: minutes("CALENDAR_AFTER_MIN", 5),
                                     current: recording() ? readMarker()?.id : nil)
        keepAwake(now)
        // A start or stop already in flight (manual or not): decide on the next tick.
        if busy { return }
        if let m = readMarker() {
            if !recording() { deleteMarker(); return }        // stopped; the next tick decides
            if target?.id != m.id { stopCalendar(m) }         // ended, skipped, or the next one started
            return
        }
        guard !recording(), calendarAuto, let tg = target else { return }
        if let f = calendarFailure[tg.id], now.timeIntervalSince(f) < 60 { return }
        startCalendar(tg)
    }

    /// Mac awake when there is a meeting to record in the next 15 min (the
    /// recording itself already holds caffeinate). Without this, an idle Mac
    /// sleeps and the meeting never starts.
    func keepAwake(_ now: Date) {
        let near = calendarAuto && meetings.contains { !skipped.contains($0.id) && $0.start.timeIntervalSince(now) < 900 && $0.end > now }
        if near && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: t("wake_reason"))
        } else if !near, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    func startCalendar(_ e: Meeting) {
        if !permissionsOk(explain: !failureAlerted.contains(e.id), meeting: readConf()["CALENDAR_MODE"] != "class") {
            calendarFailure[e.id] = Date(); failureAlerted.insert(e.id); return
        }
        busy = true; refresh()
        alarmGiven = false; micAlarmGiven = false
        let mode = readConf()["CALENDAR_MODE"] == "class" ? "class" : "meeting"
        DispatchQueue.global().async {
            let r = self.run("start", env: ["IPSIO_TITLE": Schedule.fileTitle(e.title), "IPSIO_MODE": mode])
            DispatchQueue.main.async {
                self.busy = false
                let s = self.parse(r)
                // Only a start that says RECORDING is ours: "recording()" alone
                // could be a manual recording that began meanwhile.
                if s.state["verdict"] == "RECORDING" && self.recording() {
                    self.writeMarker(e)
                    self.calendarFailure[e.id] = nil
                    if s.state["microphone"] == "DEAD" || s.state["battery"] == "1" { self.alert(s.title, s.body) }
                    else { self.notify(self.t("notif_calendar"), self.t("notif_calendar_body", e.title, self.shortTime(e.end)), file: s.state["file"]) }
                } else {
                    self.calendarFailure[e.id] = Date()
                    if !self.failureAlerted.contains(e.id) {
                        self.failureAlerted.insert(e.id)
                        self.alert(self.t("calendar_did_not_start", e.title) + ": " + s.title, s.body)
                    }
                }
                self.refresh()
            }
        }
    }

    func stopCalendar(_ m: Marker) {
        busy = true; refresh()
        let file = currentFile()
        DispatchQueue.global().async {
            let r = self.run("stop")
            DispatchQueue.main.async {
                self.busy = false
                self.deleteMarker()
                self.showStop(self.parse(r), file: file)
                self.refresh()
            }
        }
    }

    func showStop(_ s: Output, file: String?) {
        // Saved clean: a notification (a click shows it in Finder). Silent, with
        // gaps, dead microphone or not opening: a popup, because it asks for a decision.
        let sound = s.state["sound"] ?? ""
        if s.state["verdict"] == "SAVED" && (sound == "OK" || sound == "LOW" || sound == "NO_MEASURE") && s.state["microphone"] != "DEAD" {
            notify(t("notif_saved"), s.body.components(separatedBy: "\n").first ?? "", file: file)
        } else { alert(s.title, s.body) }
    }

    // ---- actions ----
    @objc func doRecord() {
        guard permissionsOk(explain: true, meeting: mode == "meeting") else { refresh(); return }
        alarmGiven = false; micAlarmGiven = false
        busy = true; refresh()
        DispatchQueue.global().async {
            let r = self.run("start")
            DispatchQueue.main.async {
                self.busy = false; self.refresh()
                let s = self.parse(r)
                if self.recording() {
                    // A warning (battery, dead microphone) asks for a decision: popup. No warning: notification.
                    if s.state["battery"] == "1" || s.state["microphone"] == "DEAD" { self.alert(s.title, s.body) }
                    else { self.notify(self.t("notif_recording"), s.body.components(separatedBy: "\n").first ?? "") }
                } else {
                    self.alert(s.title.isEmpty ? self.t("did_not_start") : s.title, s.body)
                }
            }
        }
    }
    @objc func doStop() {
        let file = currentFile()
        // Stopping a calendar recording by hand = skipping that meeting
        // (otherwise the calendar's next tick would start it again).
        if let m = readMarker() { skipped.insert(m.id); writeSkipped(); deleteMarker() }
        busy = true; refresh()
        DispatchQueue.global().async {
            let r = self.run("stop")
            DispatchQueue.main.async { self.busy = false; self.refresh(); self.showStop(self.parse(r), file: file) }
        }
    }
    @objc func doCheck() {
        // Each click decodes the whole file next to the recorder: one at a time.
        guard !checking else { notify(t("volume"), t("check_running")); return }
        checking = true
        DispatchQueue.global().async {
            let r = self.run("check")
            DispatchQueue.main.async { self.checking = false }
            self.alertFromScript(r, title: self.t("volume"))
        }
    }
    @objc func doTest() {
        // A second click (or Return in the setup window) during a test would
        // finish fast with ALREADY_RECORDING and clear busy under the first one.
        guard !busy else { return }
        guard permissionsOk(explain: true, meeting: mode == "meeting") else { refresh(); return }
        busy = true; refresh()
        statusItem.title = t("testing")
        DispatchQueue.global().async {
            let r = self.run("test")
            DispatchQueue.main.async { self.busy = false; self.refresh(); self.alertFromScript(r, title: self.t("test_title")) }
        }
    }
    @objc func doModeClass() { var c = readConf(); c["MODE"] = "class"; writeConf(c); refresh() }
    @objc func doModeMeeting() {
        var c = readConf(); c["MODE"] = "meeting"; writeConf(c); refresh()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        }
    }
    @objc func doSkip(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        if skipped.contains(id) { skipped.remove(id) } else { skipped.insert(id) }
        writeSkipped(); refresh()
        decideCalendar()   // skipping the one recording stops it now, not in 3 s
    }
    @objc func doCalendarAuto() { var c = readConf(); c["CALENDAR_AUTO"] = calendarAuto ? "0" : "1"; writeConf(c); refresh() }
    @objc func doReadCalendar() { readCalendar() }
    @objc func doOpen() {
        let folder = run("folder").trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
    }
    @objc func doTitle() {
        NSApp.activate(ignoringOtherApps: true)
        var c = readConf()
        let history = (c["RECENT_TITLES"] ?? "").components(separatedBy: "|").filter { !$0.isEmpty }
        let a = NSAlert()
        a.messageText = t("title_title")
        a.informativeText = t("title_body")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.addItems(withObjectValues: history)
        field.stringValue = c["TITLE"] ?? ""
        field.completes = true
        a.accessoryView = field
        a.addButton(withTitle: t("save")); a.addButton(withTitle: t("cancel"))
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "-")
            c["TITLE"] = name
            if !name.isEmpty { c["RECENT_TITLES"] = ([name] + history.filter { $0 != name }).prefix(5).joined(separator: "|") }
            writeConf(c); refresh()
        }
    }
    @objc func doFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = t("use_folder"); p.message = t("where")
        p.directoryURL = URL(fileURLWithPath: run("folder").trimmingCharacters(in: .whitespacesAndNewlines))
        if p.runModal() == .OK, let u = p.url {
            var c = readConf(); c["RECORDINGS_DIR"] = u.path; writeConf(c); refresh()
        }
    }
    @objc func doDoctor() { setup.show() }

    // ---- first-run window ----
    var checking = false
    lazy var setup: SetupWindow = {
        let w = SetupWindow(app: self)
        w.onComplete = { [weak self] in
            guard let self = self else { return }
            FileManager.default.createFile(atPath: self.setupDonePath, contents: Data())
        }
        return w
    }()
    var setupDonePath: String { dir + "/setup-done" }
    func deviceName() -> String { let d = readConf()["OUTPUT_DEVICE"] ?? ""; return d.isEmpty ? "Ipsio" : d }

    /// At launch: the window opens on the first run, and on any later launch
    /// where something required is missing (a driver removed, a permission
    /// revoked). A complete setup that was already seen opens nothing.
    func openSetupIfNeeded() {
        let firstRun = !FileManager.default.fileExists(atPath: setupDonePath)
        DispatchQueue.global().async {
            let r = self.run("doctor")
            DispatchQueue.main.async {
                let items = Setup.items(state: Setup.parseState(r), screenPermission: CGPreflightScreenCaptureAccess(), micPermission: self.micOk())
                if firstRun || !Setup.complete(items) { self.setup.show() }
            }
        }
    }

    static func fixLabel(_ f: SetupFix) -> String {
        switch f {
        case .terminal: return "fix_install"
        case .createDevice: return "fix_create"
        case .screenSettings: return "fix_settings"
        case .micPermission: return "fix_allow"
        case .soundInput: return "fix_sound"
        case .chooseFolder: return "fix_folder"
        case .connectCalendar: return "fix_calendar"
        case .none: return ""
        }
    }

    func applyFix(_ f: SetupFix) {
        switch f {
        case .terminal(let cmd):
            // A .command file opens in Terminal with no Automation permission
            // (osascript to Terminal would ask for one more).
            // A failed write must not open a previous fix.command (another command).
            let path = dir + "/fix.command"
            try? FileManager.default.removeItem(atPath: path)
            guard (try? Setup.terminalScript(cmd).write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
                alert(t("setup_title"), path); return
            }
            chmod(path, 0o700)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .createDevice:
            let name = deviceName()
            let tool = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("create-device").path ?? ""
            guard FileManager.default.isExecutableFile(atPath: tool) else { alert(t("device_failed"), t("device_failed_body", name)); return }
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = [name]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
                if !ok { self.alert(self.t("device_failed"), self.t("device_failed_body", name)) }
            }
        case .screenSettings: CGRequestScreenCaptureAccess(); doScreenPermission()
        case .micPermission: doMicPermission()
        case .soundInput:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input") { NSWorkspace.shared.open(u) }
        case .chooseFolder: doFolder()
        case .connectCalendar: doConnectCalendar()
        case .none: break
        }
    }
    /// Connect calendar: the address goes into a secure field (it is a
    /// credential, and the screen may be the very thing being recorded), is
    /// read once, and is saved only if it answered with a calendar.
    /// Connect calendar: first the choice. The Mac's Calendar is the easy way
    /// (the accounts are already there, one "Allow"); the iCal address is for
    /// a calendar that is not in the Calendar app.
    @objc func doConnectCalendar() {
        NSApp.activate(ignoringOtherApps: true)
        let c = NSAlert()
        c.messageText = t("connect_title"); c.informativeText = t("connect_choice_body")
        c.addButton(withTitle: t("connect_mac")); c.addButton(withTitle: t("connect_ical")); c.addButton(withTitle: t("cancel"))
        switch c.runModal() {
        case .alertFirstButtonReturn: connectMacCalendar()
        case .alertSecondButtonReturn: connectICal()
        default: break
        }
    }

    func connectMacCalendar() {
        func turnOn() {
            var c = readConf(); c["CALENDAR_MACOS"] = "1"; if c["CALENDAR_AUTO"] == nil { c["CALENDAR_AUTO"] = "1" }; writeConf(c)
            refresh(); readCalendar()
            alert(t("connect_ok_title"), t("connect_mac_ok_body"))
        }
        if MacCalendar.authorized { turnOn(); return }
        if MacCalendar.denied {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
            alert(t("connect_fail_title"), t("connect_mac_denied")); return
        }
        MacCalendar.requestAccess { ok in
            DispatchQueue.main.async { if ok { turnOn() } else { self.alert(self.t("connect_fail_title"), self.t("connect_mac_denied")) } }
        }
    }

    func connectICal() {
        let a = NSAlert()
        a.messageText = t("connect_title"); a.informativeText = t("connect_body")
        // Several hand-written addresses would vanish without a word: say so first.
        let current = ((try? String(contentsOfFile: dir + "/calendar.url", encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if current.count > 1 { a.informativeText += "\n\n" + t("connect_replaces", String(current.count)) }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: t("connect_button")); a.addButton(withTitle: t("cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let address = field.stringValue
        field.stringValue = ""
        let sources = Sources(dir: dir, conf: readConf())
        statusItem.title = t("connect_reading")
        DispatchQueue.global().async {
            let r = sources.connect(address)
            DispatchQueue.main.async {
                self.refresh()
                switch r {
                case .success(let n):
                    self.alert(self.t("connect_ok_title"), self.t("connect_ok_body", String(n)))
                    var c = self.readConf(); if c["CALENDAR_AUTO"] == nil { c["CALENDAR_AUTO"] = "1"; self.writeConf(c) }
                    self.readCalendar()
                case .failure(let e):
                    self.alert(self.t("connect_fail_title"), self.t("connect_fail_body", e.description))
                }
            }
        }
    }
    @objc func doLanguage() {
        var c = readConf(); c["UI_LANGUAGE"] = lang == "pt" ? "en" : "pt"; writeConf(c); refresh()
    }
    @objc func doRestart() { NSApp.terminate(nil) }
    /// Quit, logout or shutdown mid-recording: close the file and write its
    /// .sha256 before going (without this, it would only be found on the next launch).
    func applicationWillTerminate(_ n: Notification) {
        if recording() { _ = run("stop") }
    }
    @objc func doQuit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        try? p.run()          // bootout kills this process; nothing to do after
        NSApp.terminate(nil)  // if the agent does not exist (app opened by hand), quit normally
    }
    @objc func doScreenPermission() {
        CGRequestScreenCaptureAccess()
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }
    @objc func doMicPermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
            return
        }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }
}

@main
struct IpsioMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
