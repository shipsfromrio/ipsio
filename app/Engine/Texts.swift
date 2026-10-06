// Texts.swift: what the native engine says, in pt and en. The same keys and
// the same first line (the popup title) as the t() table in ipsio.sh, so the
// app shows the same words whichever engine recorded. What only made sense
// with BlackHole (the "Ipsio" output device, ffmpeg, SwitchAudioSource) is gone.
// %1...%5 are the arguments.
import Foundation

enum Texts {
    static func t(_ k: String, _ a: [String] = [], lang: String) -> String {
        fill((lang == "en" ? en[k] : pt[k]) ?? k, a)
    }

    /// One pass: an argument that holds "%2" (a file name can) is never filled again.
    static func fill(_ s: String, _ a: [String]) -> String {
        var out = "", it = Array(s), i = 0
        while i < it.count {
            if it[i] == "%", i + 1 < it.count, let n = it[i + 1].wholeNumberValue, n >= 1, n <= a.count {
                out += a[n - 1]; i += 2
            } else { out.append(it[i]); i += 1 }
        }
        return out
    }

    static let en: [String: String] = [
        "already_recording": "ALREADY RECORDING\nA recording is in progress. Stop it before starting another.",
        "no_screen": "NO SCREEN TO RECORD\nmacOS reported no display to record.",
        "no_microphone": "NO MICROPHONE\nMeeting mode needs a microphone and the Mac has no sound input. Connect one, or choose it in System Settings > Sound > Input.",
        "microphone_dead_start": "RECORDING, BUT THE MICROPHONE IS DEAD\nScreen and computer sound are being recorded to %1, but the microphone '%2' delivers digital silence: the macOS Microphone permission is missing, or the input volume is at zero. The others are being recorded; your voice is not.",
        "folder_inaccessible": "FOLDER NOT ACCESSIBLE\nCould not create the folder %1",
        "disk_full": "DISK FULL\nOnly %1 GB free in %2, and a recording takes about 2 GB per hour. Free some space (configured minimum: %3 GB).",
        "no_permission": "NO SCREEN RECORDING PERMISSION\nmacOS does not let Ipsio record the screen. In System Settings > Privacy & Security > Screen & System Audio Recording, enable Ipsio and reopen it.",
        "battery_warning": "WARNING: the Mac is on BATTERY. An 8-hour recording will not fit; plug it in.",
        "did_not_start": "DID NOT START\nThe capture did not start: %1",
        "recording": "RECORDING\nScreen and sound are being recorded to %1. Sound is checked automatically every second.",
        "recording_meeting": "RECORDING THE MEETING\nScreen, the others and your voice (microphone '%2') are being recorded to %1, each sound in its own track.",
        "no_sound": "NO SOUND\nThe screen is recording, but NO sound is coming from the computer. Check that the meeting app is playing sound and is not muted, then check again.",
        "sound_low": "SOUND TOO LOW\nThere is sound, but weak. Raise the volume inside Zoom or Teams (not the keyboard) and check again.",
        "sound_loud": "SOUND TOO LOUD\nIt is coming in too loud and may distort. Lower the volume a bit inside Zoom or Teams.",
        "sound_ok": "SOUND OK\nScreen and sound are coming in. Keep recording.",
        "microphone_dead": "Microphone dead for about %1 s (permission, mute or input volume at zero).",
        "not_recording": "NOT RECORDING\nThere is no recording in progress.",
        "measuring": "MEASURING\nFirst seconds; sound is measured every second.",
        "silent_for": "Silent for about %1 s.",
        "meter_stalled": "NO SOUND\nThe recorder has received no sound for about %1 s: macOS may have stopped the capture. Stop and record again; if it repeats, restart the Mac.",
        "too_early": "TOO EARLY\nCould not measure yet. Wait a few seconds of speech and check again.",
        "does_not_open": "FILE NOT CLOSED\n%1 ended up with %2 but could not be closed normally. Do not delete it: the .mov is written in 2-second pieces and usually opens up to the last one.",
        "nothing_recorded": "NOTHING RECORDED\nThe capture delivered no image (screen asleep, or permission revoked), so no file was left.",
        "saved": "RECORDING SAVED",
        "saved_silent": "RECORDING SAVED, BUT SILENT",
        "saved_gaps": "RECORDING SAVED, WITH SOUND GAPS",
        "saved_mic_dead": "RECORDING SAVED, BUT YOUR MICROPHONE WAS DEAD",
        "saved_body": "%1: %2, %3, %4. It is in %5.",
        "mic_sum_dead": "microphone DEAD %1% of the time",
        "mic_sum_ok": "microphone OK",
        "was_not_recording": "NOT RECORDING\nThere was no recording in progress.",
        "test_no_video": "TEST FAILED: NO VIDEO\nThe file has no image. Check the Screen Recording permission.",
        "test_no_sound": "TEST FAILED: NO SOUND\nThe test sentence did not make it into the recording. Check that the Mac plays sound.",
        "test_no_microphone": "TEST FAILED: MICROPHONE DEAD\nComputer sound made it into the recording, but the microphone '%1' delivered digital silence. Check the Microphone permission (System Settings > Privacy & Security > Microphone) and the input volume.",
        "test_ok": "TEST OK\nScreen and sound made it into the test recording. The test file was deleted.",
        "test_ok_meeting": "TEST OK (MEETING)\nScreen, computer sound and the microphone '%1' made it into the test recording. The test file was deleted.",
        "detail": "technical detail: %1",
        "detail_start": "%1 GB free, Mac kept awake, mode %2",
        "detail_level": "level now %1 dB, %2 recorded, %3, disk for another %4 GB (~%5 h)",
        "detail_mic": "microphone now %1 dB",
        "detail_check": "average so far %1 dB, peak %2 dB, %3 recorded, %4",
        "detail_stop": "file closed, %1 buffers dropped",
        "detail_test": "average %1 dB in the test",
        "detail_test_mic": "average %1 dB in the test, microphone %2 dB",
        "recorded": "%1 recorded, %2",
        "sum_silent": "NO SOUND %1% of the time (SILENT)",
        "sum_gaps": "sound only %1% of the time (average %2 dB)",
        "sum_low": "sound LOW (average %1 dB)",
        "sum_ok": "sound OK (average %1 dB, silence %2% of the time)",
        "no_measure": "no measurement",
        "doctor_ok": "SETUP COMPLETE\nEverything Ipsio needs is in place.",
        "doctor_incomplete": "SETUP INCOMPLETE\nFix the items marked with X, then check again.",
        "doctor_item": "OK  %1",
        "doctor_calendar_none": "--  calendar: none connected (optional; menu > Connect calendar)",
        "doctor_calendar": "OK  calendar: %1",
        "screen_permission": "screen permission",
    ]

    static let pt: [String: String] = [
        "already_recording": "JÁ ESTÁ GRAVANDO\nHá uma gravação em andamento. Pare antes de começar outra.",
        "no_screen": "SEM TELA PARA GRAVAR\nO macOS não informou nenhuma tela para gravar.",
        "no_microphone": "SEM MICROFONE\nO modo reunião precisa de um microfone e o Mac não tem entrada de som. Conecte um, ou escolha em Ajustes do Sistema > Som > Entrada.",
        "microphone_dead_start": "GRAVANDO, MAS O MICROFONE ESTÁ MUDO\nTela e som do computador estão sendo gravados em %1, mas o microfone '%2' entrega silêncio digital: falta a permissão de Microfone do macOS, ou o volume de entrada está no zero. Os outros estão sendo gravados; a sua voz não.",
        "folder_inaccessible": "PASTA INACESSÍVEL\nNão consegui criar a pasta %1",
        "disk_full": "DISCO CHEIO\nSó há %1 GB livres em %2, e uma gravação gasta cerca de 2 GB por hora. Libere espaço (mínimo configurado: %3 GB).",
        "no_permission": "SEM PERMISSÃO DE TELA\nO macOS não deixa o Ipsio gravar a tela. Em Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema, ligue o Ipsio e reabra.",
        "battery_warning": "AVISO: o Mac está na BATERIA. Uma gravação de 8 h não cabe; ligue na tomada.",
        "did_not_start": "NÃO COMEÇOU\nA captura não começou: %1",
        "recording": "GRAVANDO\nTela e som sendo gravados em %1. O som é conferido sozinho a cada segundo.",
        "recording_meeting": "GRAVANDO A REUNIÃO\nTela, os outros e a sua voz (microfone '%2') sendo gravados em %1, cada som na sua faixa.",
        "no_sound": "SEM SOM\nA tela está gravando, mas NÃO entra som do computador. Confira se o app da reunião está tocando som e não está mudo, e confira de novo.",
        "sound_low": "SOM BAIXO\nTem som, mas fraco. Suba o volume dentro do Zoom ou Teams (não o do teclado) e confira de novo.",
        "sound_loud": "SOM ALTO\nEstá entrando alto demais e pode distorcer. Abaixe um pouco o volume dentro do Zoom ou Teams.",
        "sound_ok": "SOM OK\nTela e som estão entrando. Pode deixar gravando.",
        "microphone_dead": "Microfone mudo há cerca de %1 s (permissão, mudo ou volume de entrada no zero).",
        "not_recording": "NADA GRAVANDO\nNão há gravação em andamento.",
        "measuring": "MEDINDO\nPrimeiros segundos; o som é medido a cada segundo.",
        "silent_for": "Silêncio há cerca de %1 s.",
        "meter_stalled": "SEM SOM\nO gravador não recebe som há cerca de %1 s: o macOS pode ter parado a captura. Pare e grave de novo; se repetir, reinicie o Mac.",
        "too_early": "AINDA CEDO\nAinda não deu para medir. Espere alguns segundos de fala e confira de novo.",
        "does_not_open": "ARQUIVO NÃO FECHOU\n%1 ficou com %2 mas não fechou normalmente. Não apague: o .mov é gravado em pedaços de 2 s e costuma abrir até o último.",
        "nothing_recorded": "NADA GRAVADO\nA captura não entregou nenhuma imagem (tela dormindo, ou permissão retirada), e não ficou arquivo.",
        "saved": "GRAVAÇÃO SALVA",
        "saved_silent": "GRAVAÇÃO SALVA, MAS MUDA",
        "saved_gaps": "GRAVAÇÃO SALVA, COM FALHAS DE SOM",
        "saved_mic_dead": "GRAVAÇÃO SALVA, MAS O SEU MICROFONE FICOU MUDO",
        "saved_body": "%1: %2, %3, %4. Está em %5.",
        "mic_sum_dead": "microfone MUDO em %1% do tempo",
        "mic_sum_ok": "microfone OK",
        "was_not_recording": "NADA GRAVANDO\nNão havia gravação em andamento.",
        "test_no_video": "TESTE FALHOU: SEM VÍDEO\nO arquivo saiu sem imagem. Confira a permissão de Gravação de Tela.",
        "test_no_sound": "TESTE FALHOU: SEM SOM\nA frase de teste não entrou na gravação. Confira se o Mac está tocando som.",
        "test_no_microphone": "TESTE FALHOU: MICROFONE MUDO\nO som do computador entrou na gravação, mas o microfone '%1' entregou silêncio digital. Confira a permissão de Microfone (Ajustes do Sistema > Privacidade e Segurança > Microfone) e o volume de entrada.",
        "test_ok": "TESTE OK\nTela e som entraram na gravação de teste. O arquivo de teste foi apagado.",
        "test_ok_meeting": "TESTE OK (REUNIÃO)\nTela, som do computador e o microfone '%1' entraram na gravação de teste. O arquivo de teste foi apagado.",
        "detail": "detalhe técnico: %1",
        "detail_start": "%1 GB livres, Mac mantido acordado, modo %2",
        "detail_level": "nível agora %1 dB, %2 gravados, %3, disco para mais %4 GB (~%5 h)",
        "detail_mic": "microfone agora %1 dB",
        "detail_check": "média até agora %1 dB, pico %2 dB, %3 gravados, %4",
        "detail_stop": "arquivo fechado, %1 buffers perdidos",
        "detail_test": "média %1 dB no teste",
        "detail_test_mic": "média %1 dB no teste, microfone %2 dB",
        "recorded": "gravados %1, %2",
        "sum_silent": "SEM SOM em %1% do tempo (MUDA)",
        "sum_gaps": "som em só %1% do tempo (média %2 dB)",
        "sum_low": "som BAIXO (média %1 dB)",
        "sum_ok": "som OK (média %1 dB, silêncio em %2% do tempo)",
        "no_measure": "sem medida",
        "doctor_ok": "INSTALAÇÃO COMPLETA\nTudo de que o Ipsio precisa está no lugar.",
        "doctor_incomplete": "INSTALAÇÃO INCOMPLETA\nResolva os itens marcados com X e confira de novo.",
        "doctor_item": "OK  %1",
        "doctor_calendar_none": "--  agenda: nenhuma conectada (opcional; menu > Conectar agenda)",
        "doctor_calendar": "OK  agenda: %1",
        "screen_permission": "permissão de tela",
    ]
}
