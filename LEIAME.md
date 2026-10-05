# Ipsio

Grava aula e reunião no Mac **com o som**: tela, o áudio do computador e, no
modo reunião, a sua voz numa faixa separada. Começa e para pelo menu ao lado do
relógio, ou **sozinho, pela sua agenda**: toda reunião com link de Meet, Zoom,
Teams ou Webex é gravada do começo ao fim, com o nome dela no arquivo.

O nome vem de *ipsis verbis*: tal como foi dito.

*In English: [README.md](README.md).*

## O que ele resolve

O macOS não grava o próprio som. O atalho Shift+Cmd+5 e o QuickTime gravam a
tela muda, e você descobre no fim do dia. O Ipsio junta o que é preciso para
isso não acontecer, e confere enquanto grava:

| O que dá errado | Como aparece | O que o Ipsio faz |
|---|---|---|
| Gravar com Shift+Cmd+5 / QuickTime | 8 h de vídeo, 228 GB, zero áudio | grava pelo driver BlackHole |
| Trocar só a saída do sistema | o Zoom manda o som para o alto-falante que ELE escolheu; manhã inteira a -91 dB | o alto-falante dentro do Zoom/Teams é o dispositivo `Ipsio`; o medidor acusa em 90 s |
| Conferir "tem faixa de áudio" | a faixa existia, e estava muda | mede VOLUME, uma amostra por segundo, no mesmo ffmpeg que grava |
| A sua voz escondendo a faixa do computador muda | a mistura parece boa, os outros sumiram | o medidor, a conferência e o teste leem só a faixa do computador, nunca a mistura |
| Descobrir o silêncio no fim | horas mudas | ícone amarelo e alerta com 90 s de silêncio |
| Microfone sem permissão | o macOS não dá erro: entrega silêncio digital | microfone abaixo de -80 dB = mudo (voz fica perto de -32 dB, sala vazia perto de -60); alerta em 90 s |
| Mac dorme ou apaga a tela | gravação preta ou cortada | `caffeinate` amarrado ao gravador; Mac acordado com reunião chegando |
| Gravador morre (disco, energia) | arquivo para de crescer calado | o app vê o processo morto e avisa com o fim do log |
| Gravar em `.mp4` | corte abrupto corrompe | `.mkv`, legível mesmo cortado |
| Começar sem driver, sem dispositivo, sem disco, sem permissão | descobre-se no fim | pré-voo que RECUSA com o motivo em palavras |
| Reunião semanal na agenda | quem lê só o primeiro horário grava uma semana e perde as outras | lê a regra de repetição, as exceções, as remarcadas e as canceladas |

Tamanho: ~1,8 GB por hora (H.264 por hardware, 12 fps, 4 Mbps).

## Instalar

Precisa de macOS 13 ou mais novo, [Homebrew](https://brew.sh) e as Command
Line Tools (`xcode-select --install`). Na pasta do repositório:

    bash install.sh

Ele instala `ffmpeg`, `switchaudio-osx` e o driver `blackhole-2ch`, recarrega o
áudio, cria por código o dispositivo de saída **`Ipsio`** (toca no seu
alto-falante e manda o mesmo som ao BlackHole), cria um certificado local que
mantém as permissões entre atualizações e liga o app de barra de menus, que
volta sozinho a cada login. Pede a senha do Mac três vezes (driver, recarga do
áudio, certificado). Recusa rodar com gravação em andamento.

Depois, uma vez, a janela **Configurar o Ipsio** abre sozinha. Ela lista o que
o Ipsio precisa, uma linha por item, verde ou vermelha, e cada linha vermelha
tem o botão que resolve:

| Linha | O botão |
|---|---|
| ffmpeg, SwitchAudioSource, BlackHole | **Instalar**: abre o Terminal com o comando do Homebrew (o BlackHole pede a senha do Mac) |
| Saída de som `Ipsio` | **Criar**: um clique, sem senha |
| Permissão de Gravação de Tela | **Abrir Ajustes**: ligue "Ipsio"; o app fecha e reabre sozinho |
| Permissão de Microfone | **Permitir**. Vale até para aula: o BlackHole é uma entrada de áudio para o macOS |
| Microfone do modo reunião | **Abrir Som**, para escolher o microfone de verdade |
| Pasta das gravações, espaço em disco | **Escolher pasta** |
| Agenda (opcional) | **Conectar** |

A lista se confere de novo a cada poucos segundos: a linha fica verde assim que
o item fica pronto, onde quer que tenha sido resolvido. Com tudo verde, ela
oferece **Testar agora (20 s)**: grava, o Mac fala uma frase, mede, apaga e dá o
veredito (no modo reunião confere também o microfone).

Um passo só você faz: no Zoom, engrenagem, Áudio, Alto-falante = `Ipsio`; no
Teams, Configurações, Dispositivos. O Meet no navegador segue a saída do
sistema, que o Ipsio troca sozinho ao gravar.

A janela volta a abrir sozinha sempre que falta algo obrigatório, e a qualquer
hora pelo menu, **Conferir a instalação**. No Terminal: `ipsio doctor` (sai 0 só
com tudo completo).

## Usar

O círculo ao lado do relógio: branco parado, vermelho gravando, amarelo com
exclamação quando o som (ou o microfone) some por 90 s.

- **Gravar agora / Parar e salvar.** Ao parar, o veredito da gravação inteira
  sai na hora: `som OK (média -20 dB, silêncio em 3% do tempo)`,
  `GRAVAÇÃO SALVA, MAS MUDA` ou `GRAVAÇÃO SALVA, COM FALHAS DE SOM`. Gravação limpa vira notificação;
  problema vira popup.
- **Modo.** *Aula*: só o som do computador. *Reunião*: som do computador +
  o seu microfone (a entrada padrão do sistema, ou `MICROPHONE` na conf). O
  arquivo da reunião tem três faixas de áudio: **1** mistura, **2** só o
  computador (os outros), **3** só o microfone (você). As faixas separadas são
  para a transcrição saber quem falou.
- **Próximas gravações.** O que a agenda vai gravar. Clicar numa reunião pula
  (ou despula) só ela; pular a que está gravando para na hora. Parar à mão uma
  gravação da agenda também conta como pular.
- **Título, Pasta, Gravações recentes, Idioma (pt/en).** Arquivos em
  `~/Movies/Ipsio/AAAA-MM-DD_HH-MM Título.mkv`.

Pelo Terminal, a mesma receita (o app só chama este script):

    ipsio start | stop | level | check | status | test
    ipsio-calendar            # o que a agenda gravaria agora

## Agenda: gravar sozinho

A cada 5 minutos o app lê as fontes configuradas. Cada reunião é gravada de
2 minutos antes do início a 5 minutos depois do fim, no modo reunião. Duas
reuniões seguidas viram dois arquivos: quando a segunda começa, a primeira
fecha. Gravação começada à mão nunca é parada nem trocada pela agenda. Se a
leitura falhar (rede, por exemplo), vale a última lida, e o menu diz desde
quando. Com reunião nos próximos 15 minutos o Mac não entra em repouso por
ociosidade.

Fontes (pode usar mais de uma; nenhuma credencial fica no código):

| Fonte | Como ligar | O que entra |
|---|---|---|
| **iCal secreto** (Google, Outlook, iCloud) | menu, **Conectar agenda…**, cole o endereço (ou escreva em `~/.ipsio/calendar.url`, um por linha) | eventos com link de Meet, Zoom, Teams ou Webex; sem os de dia inteiro, cancelados e os que você recusou (com `CALENDAR_ME`) |
| **Lista** | `~/.ipsio/calendar.txt`, linhas `AAAA-MM-DD HH:MM HH:MM Nome` | tudo |
| **Comando** | `CALENDAR_COMMAND='...'` na conf; ele imprime linhas no formato da lista | tudo; é a porta para quem tem a agenda atrás de credencial própria (OAuth, API da empresa): a credencial fica no seu programa. Morto depois de 60 s |

No Google Agenda, o endereço iCal fica em Configurações, a sua agenda,
"Integrar agenda", **Endereço secreto no formato iCal**. Ele dá leitura da
agenda inteira a quem o tiver; por isso o **Conectar agenda…** recebe o endereço
num campo de senha, lê uma vez, só salva se ele respondeu um calendário (colar
errado nunca troca uma agenda que funciona) e grava `calendar.url` legível só
por você (`chmod 600`). O Ipsio nunca o imprime, nem em mensagem de erro. Para
conferir antes de confiar:

    ipsio-calendar

Limite conhecido: agenda do Outlook pode usar nome de fuso do Windows
(`E. South America Standard Time`). O Ipsio ainda não lê os blocos `VTIMEZONE`,
então esse evento cai no fuso do Mac, com aviso no menu. Fica certo enquanto o
Mac e a agenda estiverem no mesmo fuso.

## Configuração

`~/.ipsio/conf`, formato shell. O menu escreve; à mão também vale.

| Chave | Padrão | O que é |
|---|---|---|
| `MODE` | `class` | `class` (aula) ou `meeting` (reunião) |
| `MICROPHONE` | entrada padrão | nome exato do microfone no modo reunião |
| `TITLE` | vazio | entra no nome das gravações feitas à mão |
| `RECORDINGS_DIR` | `~/Movies/Ipsio` | onde ficam os `.mkv` |
| `OUTPUT_DEVICE` | `Ipsio` | o dispositivo de saída múltipla |
| `MIN_FREE_GB` | `20` | abaixo disso, recusa começar |
| `UI_LANGUAGE` | idioma do sistema | `pt` ou `en` |
| `CALENDAR_AUTO` | `1` | `0` desliga a gravação automática (a lista continua no menu) |
| `CALENDAR_BEFORE_MIN` / `CALENDAR_AFTER_MIN` | `2` / `5` | margens de cada reunião |
| `CALENDAR_MODE` | `meeting` | modo das gravações da agenda |
| `CALENDAR_ME` | vazio | seu e-mail na agenda, para pular o que você recusou |
| `CALENDAR_LINK_ONLY` | `1` | `0` grava também evento do iCal sem link |
| `CALENDAR_COMMAND` | vazio | fonte por comando (acima) |

As chaves ficam em inglês nas duas línguas; o menu e as mensagens trocam.

## Permissões e assinatura

As permissões de Gravação de Tela e de Microfone são do **app**, não do
Terminal, e o macOS as amarra ao requisito designado da assinatura. Assinado
ad hoc, esse requisito muda a cada compilação e a permissão some calada (a
chave aparece ligada nos Ajustes e não vale). O `certificate.sh` cria uma vez
um certificado só deste Mac, e o requisito vira `identifier + certificate
leaf`, estável entre atualizações. Não precisa marcar o certificado como
confiável. Entrada fantasma de assinatura antiga: remova com "−" nos Ajustes
e ligue de novo.

## O que ele não resolve

- Só grava o que acontece **neste Mac**. Reunião aberta no celular sai como
  tela parada e som vazio.
- Mac desligado, dormindo com a tampa fechada ou com a sessão bloqueada não
  grava (tela bloqueada grava a tela de bloqueio).
- O volume das teclas pode não agir com a saída múltipla ativa; ajuste o
  volume dentro do app de reunião.

## Depois

Transcrição com quem falou o quê (usando as faixas separadas) e faxina de
disco (apagar o vídeo depois de N dias, guardando áudio e transcrição) estão
desenhadas em [`docs/DESIGN.md`](docs/DESIGN.md), ainda sem código.

## Desenvolver

    bash tests/test-ipsio.sh      # o script, com dublês: roda no Linux e no Mac
    swiftc -parse-as-library app/Schedule.swift tests/ScheduleTests.swift -o /tmp/t && /tmp/t
    bash tests/mutants.sh         # planta defeitos na agenda e exige que a bancada reprove cada um

O CI (GitHub Actions) roda `bash -n`, `shellcheck`, as duas bancadas, os
mutantes e a compilação do app num macOS de verdade.

Toda regra de gravação mora em `ipsio.sh`; o app decide ícone e alarme pela
linha de máquina `#state key=value` que fecha toda saída do script, nunca
pelo texto, que muda com o idioma.

## Licença

[GPL-3.0](LICENSE).
