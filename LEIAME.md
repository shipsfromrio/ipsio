# Ipsio

Grava aula e reunião no Mac **com o som**: tela, o áudio do computador e, no
modo reunião, a sua voz numa faixa separada. Começa e para pelo menu ao lado do
relógio, ou **sozinho, pela sua agenda**: toda reunião com link de Meet, Zoom,
Teams ou Webex é gravada do começo ao fim, com o nome dela no arquivo.

O nome vem de *ipsis verbis*: tal como foi dito.

*In English: [README.md](README.md).*

## O que ele resolve

O macOS não grava o próprio som. O atalho Shift+Cmd+5 e o QuickTime gravam a
tela muda, e você descobre no fim do dia. O Ipsio grava tela e som dentro do
próprio app, pelo ScreenCaptureKit, sem driver e sem ferramenta extra, e
confere enquanto grava:

| O que dá errado | Como aparece | O que o Ipsio faz |
|---|---|---|
| Gravar com Shift+Cmd+5 / QuickTime | 8 h de vídeo, 228 GB, zero áudio | pega o som do computador direto do macOS, no mesmo fluxo da tela |
| O Zoom manda o som para o alto-falante que ELE escolheu | manhã inteira a -91 dB | grava o que o Mac toca, em qualquer alto-falante; nada a escolher no Zoom, no Teams ou no Meet, e a saída de som nunca é mexida |
| Conferir "tem faixa de áudio" | a faixa existia, e estava muda | mede VOLUME, uma amostra por segundo, dos mesmos buffers que vão para o arquivo |
| Descobrir o silêncio no fim | horas mudas | ícone amarelo e alerta com 90 s de silêncio |
| Microfone sem permissão | o macOS não dá erro: entrega silêncio digital | microfone abaixo de -80 dB = mudo (voz fica perto de -32 dB, sala vazia perto de -60); alerta em 90 s |
| A sua voz escondendo a faixa do computador muda | a mistura parece boa, os outros sumiram | nada é misturado no disco: computador e microfone são faixas separadas, e o medidor, a conferência e o teste leem só a faixa do computador |
| Mac dorme ou apaga a tela | gravação preta ou cortada | repouso e apagar da tela segurados durante a gravação; Mac acordado com reunião chegando |
| O macOS para a captura (permissão tirada, tela sumiu) | arquivo para de crescer calado | o app vê o fluxo parar e diz o motivo |
| O app ou o Mac cai no meio da gravação | um `.mp4` cortado não abre | `.mov` fragmentado, gravado em pedaços de 2 s: toca até o último, e na abertura seguinte o Ipsio fecha o arquivo e avisa |
| Começar sem permissão, sem pasta, sem disco | descobre-se no fim | pré-voo que RECUSA com o motivo em palavras |
| Reunião semanal na agenda | quem lê só o primeiro horário grava uma semana e perde as outras | lê a regra de repetição, as exceções, as remarcadas e as canceladas |

Tamanho: no máximo ~1,8 GB por hora (H.264 por hardware, 12 fps, 4 Mbps). Só
entram os quadros em que a tela mudou, então um slide parado ocupa bem menos.

## Instalar

Precisa de macOS 13 ou mais novo e das Command Line Tools
(`xcode-select --install`). Na pasta do repositório:

    bash install.sh

Ele cria um certificado local que mantém as permissões entre atualizações,
compila o app de barra de menus e o liga; o app volta sozinho a cada login.
Pede a senha do Mac uma vez (certificado). Recusa rodar com gravação em
andamento, ou com uma gravação deixada aberta por uma queda (abra o Ipsio e
ele a fecha).

Depois, uma vez, a janela **Configurar o Ipsio** abre sozinha. Ela lista o que
o Ipsio precisa, uma linha por item, verde ou vermelha, e cada linha vermelha
tem o botão que resolve:

| Linha | O botão |
|---|---|
| Pasta de configuração (`~/.ipsio`) | nenhum: o texto diz o que conferir |
| Permissão de Gravação de Tela | **Abrir Ajustes**: ligue "Ipsio"; o app fecha e reabre sozinho |
| Permissão de Microfone | **Permitir**. Obrigatória só no modo reunião ou com agenda conectada; o modo aula não grava microfone |
| Microfone do modo reunião | **Abrir Som**, para conectar ou escolher um microfone |
| Pasta das gravações, espaço em disco | **Escolher pasta** |
| Agenda (opcional) | **Conectar** |

A lista se confere de novo a cada poucos segundos: a linha fica verde assim que
o item fica pronto, onde quer que tenha sido resolvido. Com tudo verde, ela
oferece **Testar agora (10 s)**: grava, o Mac fala uma frase, mede, apaga e dá
o veredito (no modo reunião confere também o microfone). Nada a configurar no
Zoom, no Teams ou no Meet.

A janela volta a abrir sozinha sempre que falta algo obrigatório, e a qualquer
hora pelo menu, **Conferir a instalação**.

## Usar

O círculo ao lado do relógio: branco parado, vermelho gravando, amarelo com
exclamação quando o som (ou o microfone) some por 90 s.

- **Gravar agora / Parar e salvar.** Ao parar, o veredito da gravação inteira
  sai na hora: `som OK (média -20 dB, silêncio em 3% do tempo)`,
  `GRAVAÇÃO SALVA, MAS MUDA` ou `GRAVAÇÃO SALVA, COM FALHAS DE SOM`. Gravação
  limpa vira notificação; problema vira popup.
- **Conferir o som até agora.** Lê o medidor ao vivo: o nível médio da
  gravação até agora, e o pico, na hora (o arquivo não é decodificado).
- **Modo.** *Aula*: só o som do computador. *Reunião*: som do computador +
  o seu microfone (a entrada padrão do sistema). O arquivo da reunião tem duas
  faixas de áudio: **1** computador (os outros), **2** microfone (você). O
  QuickTime toca as duas juntas; as faixas separadas são para a transcrição
  saber quem falou.
- **Próximas gravações.** O que a agenda vai gravar. Clicar numa reunião pula
  (ou despula) só ela; pular a que está gravando para na hora. Parar à mão uma
  gravação da agenda também conta como pular.
- **Título, Pasta, Gravações recentes, Idioma (pt/en).** Arquivos em
  `~/Movies/Ipsio/AAAA-MM-DD_HH-MM Título.mov`.

A gravação mora dentro do app. Sair, encerrar a sessão e desligar o Mac param e
salvam antes, e **Reiniciar o app** fica cinza durante a gravação. Se o app ou
o Mac cair, os pedaços até os últimos 2 s ficam no disco, e na abertura
seguinte o Ipsio fecha esse arquivo, grava o `.sha256` dele e avisa.

Pelo Terminal:

    ipsio-calendar            # o que a agenda gravaria agora

## Agenda: gravar sozinho

A cada 5 minutos o app lê as fontes configuradas. Cada reunião é gravada de
2 minutos antes do início a 5 minutos depois do fim, no modo reunião. Duas
reuniões seguidas viram dois arquivos: a primeira grava até o horário de
fim dela, e então a segunda assume. Um convite que se sobrepõe à reunião em
gravação nunca a corta; se terminar depois dela, assume nesse fim. Gravação
começada à mão nunca é parada nem trocada pela agenda. Se a leitura falhar
(rede, por exemplo), vale a última lida, e o menu diz desde quando. Depois de
2 horas sem uma leitura completa, a linha do menu vira aviso e uma notificação
diz o motivo: reunião marcada depois disso não entraria. Com reunião nos
próximos 15 minutos o Mac não entra em repouso por ociosidade.

Fontes (pode usar mais de uma; nenhuma credencial fica no código):

| Fonte | Como ligar | O que entra |
|---|---|---|
| **Calendário do Mac** (toda conta que já está no app Calendário) | menu, **Conectar agenda…**, **Calendário do Mac**, depois **Permitir** (ou `CALENDAR_MACOS=1` na conf) | os mesmos filtros do iCal; sem endereço para colar, nada sai do Mac |
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
| `TITLE` | vazio | entra no nome das gravações feitas à mão |
| `RECORDINGS_DIR` | `~/Movies/Ipsio` | onde ficam os `.mov` |
| `MIN_FREE_GB` | `20` | abaixo disso, recusa começar |
| `UI_LANGUAGE` | idioma do sistema | `pt` ou `en` |
| `CALENDAR_AUTO` | `1` | `0` desliga a gravação automática (a lista continua no menu) |
| `CALENDAR_BEFORE_MIN` / `CALENDAR_AFTER_MIN` | `2` / `5` | margens de cada reunião |
| `CALENDAR_MODE` | `meeting` | modo das gravações da agenda |
| `CALENDAR_ME` | vazio | seu e-mail na agenda, para pular o que você recusou |
| `CALENDAR_LINK_ONLY` | `1` | `0` grava também evento do iCal sem link |
| `CALENDAR_MACOS` | vazio | `1` lê o app Calendário do Mac (acima) |
| `CALENDAR_COMMAND` | vazio | fonte por comando (acima) |
| `POST_RECORDING` | vazio | comando rodado depois de cada gravação salva, com o `.mov` em `$1` (veja abaixo) |

O microfone da reunião é a entrada padrão do sistema: escolha em Ajustes do
Sistema, Som, Entrada. `CALENDAR_COMMAND` e `POST_RECORDING` só existem na
versão compilada deste repositório; a edição da App Store não roda comandos.

### Depois de cada gravação

Toda gravação salva ganha, ao lado, um arquivo `.sha256` no formato que o
`shasum -a 256 -c` confere: prova de que o arquivo não foi alterado depois.
Em seguida, se houver `POST_RECORDING`, ele roda com o arquivo em `$1`; é por
aqui que entram a transcrição ou a cópia para outro disco. Os dois rodam em
segundo plano, com a saída do comando em `~/.ipsio/post-recording.log` (com o
código de saída); um comando que falha nunca mexe no vídeo, e parar a gravação
nunca espera por eles. Cada gravação é entregue uma vez só (parar de novo não
roda outra vez), e o trecho do **Testar agora** nunca é.

    POST_RECORDING='~/bin/transcrever.sh'

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
- Uma queda perde no máximo os últimos 2 s, mas o medidor morre junto com o
  app: a gravação fechada na abertura seguinte é salva sem veredito de som.
- A chave de assinatura que o `certificate.sh` cria fica no chaveiro do
  sistema, usável pelo `codesign` sem pergunta (é o que deixa a atualização
  reassinar sozinha). Um programa que já esteja rodando neste Mac poderia se
  assinar como Ipsio e herdar as permissões de Gravação de Tela e Microfone.
  Um certificado Developer ID, ou uma pergunta a cada assinatura, fecharia isso.

## A edição da App Store

O mesmo app, compilado pelo `build-store.sh` com `-D STORE`: em sandbox,
universal (Apple silicon e Intel), macOS 13 ou mais novo. Não tem LaunchAgent
(o item de menu **Abrir ao iniciar a sessão** pede ao macOS), nem
`POST_RECORDING`, nem `CALENDAR_COMMAND`. É grátis por 7 dias, com tudo, e
depois uma compra dentro do app libera para sempre; gravação em andamento
sempre termina. A versão compilada deste repositório é sempre liberada.

## A receita do Terminal (legado)

O `ipsio.sh` é a receita antiga, mantida para uso no Terminal: grava pelo
ffmpeg e pelo driver BlackHole em `.mkv`, e exige escolher o dispositivo de
saída `Ipsio` como alto-falante dentro do Zoom ou do Teams. O app não o usa.
Para montar: `bash install.sh --with-script` (exige Homebrew; pede a senha
para o driver e para recarregar o áudio). Depois,
`ipsio start | stop | level | check | status | test | doctor`.

## Depois

Transcrição com quem falou o quê (usando as faixas separadas) e faxina de
disco (apagar o vídeo depois de N dias, guardando áudio e transcrição) estão
desenhadas em [`docs/DESIGN.md`](docs/DESIGN.md), ainda sem código.

## Desenvolver

    bash tests/test-ipsio.sh      # o script legado, com dublês: roda no Linux e no Mac
    swiftc -parse-as-library app/Schedule.swift tests/ScheduleTests.swift -o /tmp/t && /tmp/t
    swiftc -parse-as-library app/Setup.swift tests/SetupTests.swift -o /tmp/s && /tmp/s   # a lista da configuração
    swiftc -parse-as-library app/Engine/*.swift tests/EngineTests.swift -o /tmp/e && /tmp/e   # motor nativo
    swiftc -parse-as-library app/Engine/*.swift app/Setup.swift tests/BackendTests.swift -o /tmp/b && /tmp/b   # o backend do app
    bash tests/mutants.sh         # planta defeitos na agenda e no motor; cada um tem que reprovar na sua bancada
    bash build-store.sh           # a edição da App Store em dist/ (assinatura ad hoc; a da loja está no script)

O CI (GitHub Actions) roda `bash -n`, `shellcheck`, as bancadas, os mutantes
e a compilação do app num macOS de verdade.

Toda regra de gravação mora em `app/Engine/`. O `Backend.swift` responde no
formato que o script sempre usou, e o app decide ícone e alarme pela linha de
máquina `#state key=value` que fecha toda resposta, nunca pelo texto, que muda
com o idioma. O `tools/NativeCLI.swift` compila o `ipsio-native`, o mesmo
backend pelo Terminal.

## Licença

[GPL-3.0](LICENSE).
