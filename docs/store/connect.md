# Ipsio na Mac App Store: ficha para copiar e colar

Siga na ordem. Cada campo tem: onde fica, o valor num bloco (clique e copie) e o limite.

- O valor vai exatamente como está no bloco.
- O que está entre `<` e `>` é para você preencher. Nunca cole os sinais.
- "Agora" é a contagem atual do valor. Limites conferidos no site da Apple em 06/10/2026.
- Os textos vêm de `docs/store/listing-en.md`, `docs/store/listing-pt.md`, `docs/store/privacy.md` e `docs/store/review-notes.md`. Aqui estão em parágrafo corrido: as quebras de linha dos arquivos não vão para a loja.

Dois sites:

- **Developer**: https://developer.apple.com/account (certificados, App ID, perfil).
- **App Store Connect**: https://appstoreconnect.apple.com (o app, a ficha, a compra).

---

## 0. Antes de tudo

### 0.1 Inscrição no Apple Developer Program

Onde: https://developer.apple.com/programs/enroll

- Inscreva-se como **Organization** (empresa), com a Conta Apple criada para as lojas.
- Precisa do **D-U-N-S** da empresa (Dun & Bradstreet, grátis, de 7 a 14 dias úteis fora dos EUA). O nome e o endereço no D-U-N-S têm que bater com os do cadastro na Apple.
- A empresa precisa de um site público no próprio domínio, e a Conta Apple de um e-mail desse domínio.
- Quem se inscreve precisa poder assinar pela empresa. A Apple costuma telefonar para confirmar.
- A Conta Apple precisa de autenticação de dois fatores.
- Custa US$ 99 por ano.
- Espere o e-mail de aprovação antes do passo 0.2.
- Na loja, o nome do vendedor é o nome legal da empresa, como está no D-U-N-S.

Anote o **Team ID** (10 letras e números). Onde: developer.apple.com/account, Membership details.

```
<TEAM_ID>
```

### 0.2 Contratos, impostos e banco

Onde: App Store Connect, **Business**, aba **Agreements**.

1. Na linha **Paid Apps**, clique **View and Agree to Terms** e aceite. Sem isso não há compra dentro do app.
2. Ainda em Business, preencha **Tax Forms**. Para empresa fora dos EUA, o formulário dos EUA que a Apple pede é o W-8BEN-E. Confira com o seu contador.
3. Em Business, cadastre a **conta bancária** que recebe.

O Paid Apps só fica ativo com os três prontos.

### 0.3 Small Business Program (comissão de 15% em vez de 30%)

Onde: https://developer.apple.com/app-store/small-business-program/enroll/

- Vale para quem é novo na App Store.
- Precisa do Paid Apps aceito (passo 0.2).
- Se perguntar por "Associated Developer Accounts", responda que não há.

### 0.4 Certificados (dois)

Primeiro, um pedido de certificado no Mac:

1. Abra **Acesso às Chaves** (Keychain Access).
2. Menu Acesso às Chaves, **Assistente de Certificado**, **Solicitar um Certificado de uma Autoridade de Certificação**.
3. E-mail: o da sua Conta Apple. Nome: `Caio Figueiroa`. Marque **Salvo no disco**.
4. Salve o arquivo `CertificateSigningRequest.certSigningRequest` na Mesa.

Depois, em developer.apple.com/account, **Certificates, Identifiers & Profiles**, **Certificates**, botão **+**:

| Tipo para escolher | Para quê | Nome que aparece no Mac |
|---|---|---|
| **Apple Distribution** | assina o app | `Apple Distribution: <NOME DA EMPRESA> (<TEAM_ID>)` |
| **Mac Installer Distribution** | assina o pacote `.pkg` | `3rd Party Mac Developer Installer: <NOME DA EMPRESA> (<TEAM_ID>)` |

Para cada um: envie o mesmo pedido, baixe o `.cer` e **dê dois cliques** nele. Ele entra no Acesso às Chaves (chaveiro "início de sessão"). Depois pode apagar o `.cer` da pasta Downloads.

Para conferir, no Terminal:

```
security find-identity -v
```

### 0.5 App ID

Onde: Certificates, Identifiers & Profiles, **Identifiers**, botão **+**, **App IDs**, **App**.

Description:

```
Ipsio Store
```

Bundle ID: marque **Explicit** e cole:

```
io.github.shipsfromrio.ipsio.store
```

Capabilities: **não marque nada**. A **In-App Purchase** já vem ligada sozinha. Continue e registre.

### 0.6 Perfil de distribuição (Mac App Store)

Onde: Certificates, Identifiers & Profiles, **Profiles**, botão **+**.

1. Em Distribution, escolha **Mac App Store Connect**.
2. App ID: `io.github.shipsfromrio.ipsio.store`.
3. Certificado: o **Apple Distribution**.
4. Nome do perfil:

```
Ipsio Mac App Store
```

5. **Generate**, depois **Download**. O arquivo vai para a pasta Downloads com o nome `Ipsio_Mac_App_Store.provisionprofile`. Deixe lá: é o caminho que o passo 9 usa.

### 0.7 Chave da API do App Store Connect (para o `store/release.sh`)

Onde: App Store Connect, **Users and Access**, **Integrations**, **App Store Connect API**, **Team Keys**.

1. Se aparecer um pedido de acesso à API, aceite primeiro.
2. Clique **Generate API Key** (ou **+**).
3. Name:

```
ipsio release
```

4. Access: **App Manager**.
5. Anote o **Key ID** (10 caracteres, na linha da chave) e o **Issuer ID** (no alto da página).
6. Baixe o `AuthKey_<KEY_ID>.p8`. **A Apple só deixa baixar uma vez.**
7. No Terminal, mova o arquivo para a pasta que o script lê:

```
mkdir -p ~/.appstoreconnect/private_keys && mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
```

Nunca coloque esse arquivo no repositório nem mande por mensagem.

---

## 1. Criar o app

Onde: App Store Connect, **Apps**, botão **+**, **New App**.

**Platforms**: marque só **macOS**.

**Name**. Limite: de 2 a 30. Agora: 5.

```
Ipsio
```

Se a Apple disser que o nome já está em uso, pare e me avise. Não invente outro na hora.

**Primary Language**: **English (U.S.)**.

**Bundle ID**: escolha na lista (só aparece depois do passo 0.5):

```
io.github.shipsfromrio.ipsio.store
```

**SKU** (interno, ninguém vê, não muda depois):

```
ipsio-mac-1
```

**User Access**: **Full Access**. Clique **Create**.

---

## 2. App Information

Onde: no app, barra lateral, **App Information**.

### 2.1 Textos por idioma

O idioma se troca no menu de idiomas no alto, à direita. Para criar o português, escolha **Portuguese (Brazil)** nesse menu.

**English (U.S.)**

Name. Limite: 30. Agora: 5.

```
Ipsio
```

Subtitle. Limite: 30. Agora: 28.

```
Records meetings, with sound
```

**Portuguese (Brazil)**

Name. Limite: 30. Agora: 5.

```
Ipsio
```

Subtitle. Limite: 30. Agora: 25.

```
Grava reuniões, com o som
```

### 2.2 Categoria

- **Primary Category**: **Productivity**. Tem que ser essa: é a que está dentro do app (`build-store.sh`).
- **Secondary Category** (opcional): sugestão **Business**.

### 2.3 Content Rights

Pergunta se o app contém, mostra ou acessa conteúdo de terceiros. Responda **No**.

Por quê: o app não traz conteúdo de ninguém. Ele grava a tela de quem usa, por ordem de quem usa.

### 2.4 Age Rating (classificação etária)

Onde: App Information, **Age Rating**, **Edit**. Responda tudo assim:

| Etapa | Resposta |
|---|---|
| In-App Controls: Parental Controls, Age Assurance | **No** |
| Capabilities: Unrestricted Web Access | **No** |
| Capabilities: User-Generated Content, Social Media, Messaging and Chat, Advertising | **No** |
| Mature Themes (todas) | **None** |
| Medical or Wellness (todas) | **None** |
| Sexuality or Nudity (todas) | **None** |
| Violence (todas) | **None** |
| Chance-Based Activities: Gambling, Loot Boxes | **No** |
| Chance-Based Activities: Simulated Gambling, Contests | **None** |
| Última etapa (Made for Kids, Override) | **Not Applicable** |

Por quê:

- O app não tem navegador. Ele só baixa a agenda cujo endereço você cola. Por isso "Unrestricted Web Access" é **No**.
- Não tem anúncio, chat, rede social nem conteúdo de outros usuários.
- O resultado esperado é **4+**.
- Se aparecer uma pergunta específica do Brasil, aceite a classificação que a Apple calcular.

Clique **Save**.

### 2.5 Campos que ficam em branco

- License Agreement: deixe o padrão da Apple. O `LICENSING.md` diz que a edição da loja usa o contrato padrão da App Store.
- URL for App Store Server Notifications: em branco.

### 2.6 Digital Services Act (União Europeia)

Onde: App Information, **Digital Services Act**.

A Apple pede para declarar se você é "trader" (comerciante) na União Europeia. Quem vende (e aqui há compra) normalmente é trader. Se for trader, o seu endereço, telefone e e-mail aparecem na página do app nos países da UE. Sem essa resposta, o app não sai na UE.

Essa decisão é sua. Preencha com:

```
<ENDEREÇO>
```

```
<TELEFONE com +55>
```

```
<EMAIL>
```

---

## 3. Pricing and Availability (o app)

Onde: barra lateral, **Monetization**, **Pricing and Availability**.

1. Em **Price Schedule**, clique **Add Pricing**.
2. Base country or region: **United States**.
3. Price: **Free** (US$ 0.00). Clique **Next** e depois **Confirm**.
4. Em **Availability**: todos os países e regiões, **menos China mainland**. A China pede um número de registro (ICP) que você não tem.

O app é grátis. Quem paga é a compra dentro do app (passo 4).

---

## 4. In-App Purchase: "Ipsio lifetime"

Onde: barra lateral, **Monetization**, **In-App Purchases**, botão **+**.

**Type**: **Non-Consumable**.

**Reference Name** (interno). Limite: 64. Agora: 14.

```
Ipsio lifetime
```

**Product ID**. Limite: 100. Agora: 37. **Não muda depois e não pode ter erro**: o app procura exatamente este.

```
io.github.shipsfromrio.ipsio.lifetime
```

Clique **Create**.

### 4.1 Preço

Na página da compra, **Price Schedule**, **Add Pricing**.

1. Base country or region: **United States**.
2. Price: **19.99 USD**.
3. **Next**: aparece a tabela com o preço de cada país. O Brasil é convertido sozinho. **Confira o valor em R$** nessa tabela. Se quiser um número redondo, dá para mudar só o Brasil (aí a Apple para de ajustar o Brasil sozinha).
4. **Confirm**.

### 4.2 Availability

Todos os países e regiões, igual ao app (menos China mainland).

### 4.3 Textos por idioma (Localization)

Clique **+** em Localization para cada idioma.

**English (U.S.)**

Display Name. Limite: de 2 a 30. Agora: 14.

```
Ipsio lifetime
```

Description. Limite: 45. Agora: 37.

```
Unlocks Ipsio for life. One purchase.
```

**Portuguese (Brazil)**

Display Name. Limite: de 2 a 30. Agora: 15.

```
Ipsio vitalício
```

Description. Limite: 45. Agora: 41.

```
Libera o Ipsio para sempre. Compra única.
```

O nome em português bate com o menu do app em português ("Comprar Ipsio vitalício").

### 4.4 Review Information da compra

**Screenshot** (só a Apple vê): uma foto do menu do Ipsio com a linha "Buy Ipsio lifetime". Mesmo tamanho das capturas da loja (por exemplo 2880 x 1800). Dá para usar o `docs/store/frame.sh`, como em `docs/store/screenshots.md`.

**Review Notes**. Limite: 4000. Agora: 270.

```
Non-consumable. It unlocks Ipsio for life after the free 7-day trial. In the menu bar, the bottom of the menu shows "Buy Ipsio lifetime" and "Restore purchase". Please test with a sandbox Apple Account. The full purchase steps are in the App Review notes of version 1.0.
```

A compra vai para a revisão **junto com a versão 1.0** (passo 6.8). Não envie sozinha.

---

## 5. App Privacy

Onde: barra lateral, **App Privacy**.

### 5.1 Coleta de dados

1. Clique **Get Started**.
2. Escolha **No, we do not collect data from this app**.
3. **Save**.

Isso vira "Data Not Collected" na loja. Por quê: o Ipsio não tem conta, servidor, estatística, anúncio nem código de terceiros (`docs/store/privacy.md`).

### 5.2 Privacy Policy URL

Em **Privacy Policy**, clique **Edit**. Privacy Policy URL:

```
https://github.com/shipsfromrio/ipsio/blob/main/docs/site/privacy.md
```

User Privacy Choices URL: em branco. **Save**.

A página tem inglês e português, então a mesma URL serve para os dois idiomas.

### 5.3 Publicar

Clique **Publish** (alto, à direita) e confirme.

---

## 6. Versão 1.0 (por idioma)

Onde: barra lateral, **macOS App**, **1.0 Prepare for Submission**. Troque o idioma no menu do alto, à direita, e preencha os dois.

### 6.1 English (U.S.)

**Promotional Text**. Limite: 170. Agora: 148.

```
Connect your calendar once and every video meeting records itself, start to end. Screen and sound in separate tracks, a silence alarm, one purchase.
```

**Description**. Limite: 4000. Agora: 3825.

```
Ipsio records classes and meetings on your Mac with the sound: the screen, everything the Mac plays, and, in meeting mode, your voice. It lives in the menu bar, next to the clock.

RECORDS BY ITSELF, FROM YOUR CALENDAR
Connect the Mac's Calendar (one Allow, every account already in it) or a private iCal link. Every event with a video-call link is recorded from 2 minutes before it starts to 5 minutes after it ends, in any meeting app, with the meeting's name in the file. Weekly meetings, moved and cancelled occurrences are read correctly. Back-to-back meetings become two files. Skip one with a click.

OFFERS TO RECORD AN OPEN CALL
Join a call in Zoom, Teams, Google Meet, Webex or a Slack huddle, and Ipsio offers once to record it: one notification with a Record button. It reads only window titles, never what is on the screen.

SOUND YOU CAN TRUST
The Mac's own screenshot tools record a silent screen. Ipsio takes the computer's sound straight from macOS, whatever speaker or headset you use. Nothing to set up in the meeting app, no driver, and your sound output is never changed.

SCREEN AND SOUND IN SEPARATE TRACKS
In meeting mode the file has two audio tracks: the computer (the others) and your microphone (you). Nothing is mixed on disk, so you always know who spoke, and a silent computer track can never hide behind your voice.

A SILENCE ALARM, WHILE IT RECORDS
Ipsio measures the volume every second. After 90 seconds of silence, or of a dead microphone, the icon turns yellow and an alert tells you what to do. On stop, a verdict for the whole recording: sound OK, silent, or with gaps.

BUILT TO SURVIVE
Files are written in 2-second pieces. If the Mac loses power or the app closes, the recording plays up to the last piece, and Ipsio closes it on the next launch. The Mac does not idle-sleep while recording, nor with a meeting coming.

EVIDENCE OF INTEGRITY
Every saved recording gets a SHA-256 fingerprint next to it, checkable with the standard shasum tool: proof that the file was not changed afterwards. For any recent recording, a PDF integrity report puts it on one page: the fingerprint computed again, size, length and tracks, and how to check it.

FIND WHAT WAS SAID
Search your recordings for a word said in any transcript, or in a file name, with or without accents. Ipsio shows the recording and the time it was said.

EVERYTHING STAYS ON YOUR MAC
No account, no server, no cloud. Recordings go to Movies/Ipsio, or a folder you pick. Ipsio collects no data.

SET UP IN A MINUTE
A setup window lists what is needed, one line each, with the one button that fixes it. Then a 10-second test: the Mac speaks a sentence, Ipsio measures it, and tells you it works.

ONE PURCHASE
Free for 7 days, every feature included. Then one in-app purchase unlocks Ipsio for life. No subscription.

Also:
- Class mode: screen and computer sound only; it works without the microphone permission.
- Record the whole screen, another screen, or one window.
- Quality: Economy, Normal or High, with the GB per hour shown.
- Global shortcuts: Control-Option-Command-R records or stops, Control-Option-Command-T tests.
- Recent recordings, title and folder from the menu.
- English and Portuguese.
- Open source: the full code is public under the GPL.

TELL THEM YOU ARE RECORDING
Ipsio records what happens on this Mac. Recording other people may require their consent where you live. Before a recording you start, Ipsio offers a notice ready to paste in the meeting chat. When the calendar starts one, a notification reminds you, and a click copies the notice.

TRANSCRIPTION ON YOUR MAC
Each recording becomes a transcript with who spoke: you from the microphone track, the others from the computer track. Speech is recognized on this Mac, never on a server (macOS may first download the language from Apple).
```

**Keywords**. Limite: 100 bytes. Agora: 100 bytes. Sem espaço depois da vírgula.

```
meeting recorder,screen recording,system audio,calendar,class,lecture,call,minutes,microphone,sha256
```

**Support URL**:

```
https://github.com/shipsfromrio/ipsio/blob/main/docs/site/support.md
```

**Marketing URL**:

```
https://github.com/shipsfromrio/ipsio
```

### 6.2 Portuguese (Brazil)

**Promotional Text**. Limite: 170. Agora: 151.

```
Conecte a agenda uma vez e toda reunião por vídeo se grava sozinha, do começo ao fim. Tela e som em faixas separadas, alarme de silêncio, compra única.
```

**Description**. Limite: 4000. Agora: 3915.

```
O Ipsio grava aula e reunião no seu Mac com o som: a tela, tudo o que o Mac toca e, no modo reunião, a sua voz. Fica na barra de menus, ao lado do relógio.

GRAVA SOZINHO, PELA SUA AGENDA
Conecte o Calendário do Mac (um Permitir, com todas as contas que já estão nele) ou um endereço iCal privado. Todo evento com link de videochamada é gravado de 2 minutos antes do início a 5 minutos depois do fim, em qualquer app de reunião, com o nome da reunião no arquivo. Reuniões semanais, remarcadas e canceladas são lidas do jeito certo. Reuniões seguidas viram dois arquivos. Pule uma com um clique.

OFERECE GRAVAR A CHAMADA ABERTA
Entre numa chamada no Zoom, no Teams, no Google Meet, no Webex ou num huddle do Slack, e o Ipsio oferece uma vez gravar: uma notificação com o botão Gravar. Ele lê só o título das janelas, nunca o que está na tela.

SOM EM QUE VOCÊ PODE CONFIAR
As ferramentas de captura do próprio Mac gravam a tela muda. O Ipsio pega o som do computador direto do macOS, seja qual for o alto-falante ou fone que você usa. Nada a configurar no app de reunião, nenhum driver, e a sua saída de som nunca é trocada.

TELA E SOM EM FAIXAS SEPARADAS
No modo reunião o arquivo tem duas faixas de áudio: o computador (os outros) e o seu microfone (você). Nada é misturado no disco, então você sempre sabe quem falou, e uma faixa do computador muda nunca se esconde atrás da sua voz.

ALARME DE SILÊNCIO, ENQUANTO GRAVA
O Ipsio mede o volume a cada segundo. Com 90 segundos de silêncio, ou de microfone mudo, o ícone fica amarelo e um alerta diz o que fazer. Ao parar, um veredito da gravação inteira: som OK, muda ou com falhas.

FEITO PARA SOBREVIVER
Os arquivos são gravados em pedaços de 2 segundos. Se o Mac perder a energia ou o app fechar, a gravação toca até o último pedaço, e o Ipsio a fecha na abertura seguinte. O Mac não entra em repouso durante a gravação, nem com reunião chegando.

PROVA DE INTEGRIDADE
Toda gravação salva ganha ao lado uma impressão digital SHA-256, conferível com a ferramenta padrão shasum: prova de que o arquivo não foi alterado depois. Para qualquer gravação recente, um relatório de integridade em PDF põe tudo numa página: a impressão digital calculada de novo, tamanho, duração, faixas e como conferir.

ACHE O QUE FOI DITO
Busque nas suas gravações uma palavra dita em qualquer transcrição, ou no nome do arquivo, com ou sem acento. O Ipsio mostra a gravação e o tempo em que foi dita.

TUDO FICA NO SEU MAC
Sem conta, sem servidor, sem nuvem. As gravações vão para Filmes/Ipsio, ou para a pasta que você escolher. O Ipsio não coleta dado nenhum.

PRONTO EM UM MINUTO
Uma janela de configuração lista o que falta, uma linha por item, com o botão que resolve. Depois, um teste de 10 segundos: o Mac fala uma frase, o Ipsio mede e diz que está funcionando.

COMPRA ÚNICA
Grátis por 7 dias, com tudo incluído. Depois, uma compra dentro do app libera o Ipsio para sempre. Sem assinatura.

E também:
- Modo aula: só tela e som do computador; funciona sem a permissão de microfone.
- Grave a tela inteira, outra tela, ou uma janela.
- Qualidade: Econômica, Normal ou Alta, com os GB por hora à vista.
- Atalhos globais: Control-Option-Command-R grava ou para, Control-Option-Command-T testa.
- Gravações recentes, título e pasta pelo menu.
- Português e inglês.
- Código aberto: o código inteiro é público, sob a GPL.

AVISE QUE ESTÁ GRAVANDO
O Ipsio grava o que acontece neste Mac. Gravar outras pessoas pode exigir o consentimento delas onde você está. Antes de uma gravação que você começa, o Ipsio oferece um aviso pronto para colar no chat da reunião. Quando a agenda começa uma, uma notificação lembra, e um clique copia o aviso.

TRANSCRIÇÃO NO SEU MAC
Cada gravação vira uma transcrição com quem falou: você pela faixa do microfone, os outros pela faixa do computador. A fala é reconhecida neste Mac, nunca num servidor (o macOS pode baixar antes o idioma da Apple).
```

**Keywords**. Limite: 100 bytes. Agora: 97 bytes (letra com acento conta 2). Sem espaço depois da vírgula.

```
gravador,reunião,gravar tela,áudio do sistema,agenda,aula,palestra,chamada,ata,microfone,sha256
```

**Support URL** (a página tem os dois idiomas):

```
https://github.com/shipsfromrio/ipsio/blob/main/docs/site/support.md
```

**Marketing URL**:

```
https://github.com/shipsfromrio/ipsio
```

### 6.3 What's New

Na versão 1.0 esse campo não aparece. A Apple só pede a partir da segunda versão. O texto já está guardado em `docs/store/listing-en.md` e `listing-pt.md`.

### 6.4 Screenshots

Onde: no alto da página da versão, **Mac**, em cada idioma.

- De 1 a 10 por idioma.
- Tamanho 16:10: 1280 x 800, 1440 x 900, 2560 x 1600 ou 2880 x 1800.
- PNG ou JPG, sem transparência.
- A lista das 8 capturas e o jeito de fazer estão em `docs/store/screenshots.md`.

### 6.5 Copyright (vale para os dois idiomas)

A Apple põe o símbolo © sozinha. Não digite o símbolo.

```
2026 Caio Figueiroa
```

### 6.6 Version

```
1.0
```

### 6.7 Build

Depois do passo 9, na seção **Build**, clique **Add Build** (ou **+**) e escolha o build que subiu.

### 6.8 In-App Purchases and Subscriptions

Na mesma página da versão, nessa seção, clique **+** e marque **Ipsio lifetime**. É assim que a compra vai para a revisão junto com o app.

### 6.9 App Store Version Release

Escolha **Manually release this version**. Assim, depois de aprovado, quem aperta o botão de publicar é você.

---

## 7. App Review Information

Onde: na página da versão 1.0, seção **App Review Information**.

**Sign-in required**: **desmarque**. O app não tem conta.

**Contact Information**:

First name:

```
Caio
```

Last name:

```
Figueiroa
```

Phone (com +55 e DDD):

```
<TELEFONE>
```

Email:

```
<EMAIL>
```

**Notes**. Limite: 4000 bytes. Agora: 3460 bytes.

```
Hello, and thank you for reviewing Ipsio. No demo account is needed.

WHAT IT DOES
Ipsio is a menu-bar app (the circle next to the clock) that records classes and video meetings on this Mac: the screen, the sound the Mac plays and, in meeting mode, the microphone. It can also record by itself from the user's calendar, for events with a video-call link.

PERMISSIONS
- Screen Recording (ScreenCaptureKit): the screen and the system sound are the recording.
- Microphone: meeting mode only, in a separate track. Class mode works without it.
- Calendars (optional): to know when a meeting starts and ends, and its name.
- Network (client only): to download a private iCal feed whose address the user pastes.
Everything stays on the Mac. No account, no server, no data collection.

CONSENT
Ipsio records only when the user starts it or connects a calendar. While recording, the menu-bar icon turns red and macOS shows its own indicator. Before a recording the user starts, "Tell them you are recording?" offers a notice to paste in the meeting chat, with "Copy notice and record", "Record" and "Cancel". A recording the calendar starts is never held by a popup: a notification "Recording: tell the others" copies the notice. The menu item "Remind me to announce the recording" turns this off.

HOW TO TEST
1. Launch Ipsio. In "Set up Ipsio", click "Open Settings" and turn on Ipsio under Screen & System Audio Recording. The app reopens by itself.
2. Click "Test now (10 s)". The Mac speaks a sentence, Ipsio measures it, deletes the test file and shows the verdict.
3. Menu, "Record now". Play a video with sound for a minute, then "Stop and save". The file is in Movies/Ipsio, with a .sha256 file next to it.
4. Menu, Mode, Meeting. Allow the microphone and record while speaking. The file has two audio tracks (computer, then microphone).
5. Optional: menu, "Connect calendar...", "Mac's Calendar", Allow. Add an event starting in 5 minutes with https://meet.google.com/abc-defg-hij in its notes. It appears under "Upcoming recordings" and records from 2 minutes before its start.
6. Open call: join a Google Meet call in Safari or Chrome. Within 15 seconds a notification offers to record it (notifications must be allowed). Only window titles are read.
7. Recent recordings, the file, "Transcribe". Then menu, "Search recordings..." finds a word that was said. "Integrity report (PDF)" writes a PDF next to the recording.
8. Shortcuts: Control-Option-Command-R records or stops, Control-Option-Command-T runs the test. Standard hot key API, no Accessibility permission.
"Open at login" uses SMAppService and stays off until the user ticks it.

PURCHASE
Free download with a 7-day trial, every feature included. Then one non-consumable in-app purchase, "Ipsio lifetime" (US$ 19.99), unlocks the app for life. Please test with a sandbox Apple Account.
1. On a fresh install, a window states the terms, with "Start the 7 days", "Buy now" and "Restore purchase". The menu then shows "Trial: 7 days left", "Buy Ipsio lifetime (<local price>)..." and "Restore purchase".
2. "Buy Ipsio lifetime" opens the App Store payment sheet. After confirming, "THANK YOU" appears and those lines leave the menu.
3. After reinstalling, "Restore purchase" unlocks it again. An account that never bought it gets "NOTHING TO RESTORE".
4. When the trial ends, "Record now" shows "TRIAL ENDED", pointing to Buy and Restore. A recording already running is never stopped.

Thank you.
```

O bloco acima é o mesmo texto de `docs/store/review-notes.md`, que cabe no limite. Cole este.

**Attachment**: nenhum.

---

## 8. Criptografia (export compliance) e direitos

### 8.1 Criptografia

O app só usa a criptografia do próprio macOS (HTTPS ao baixar a agenda). Isso é isento.

O app já declara isso por dentro (`ITSAppUsesNonExemptEncryption` = `false` no `build-store.sh`). Então a pergunta **normalmente não aparece**.

Se aparecer, a resposta é: **não usa criptografia não isenta**. Na lista de tipos de algoritmo, escolha **None of the algorithms mentioned above**.

### 8.2 Content Rights

Já respondido no passo 2.3: **No**.

---

## 9. Enviar o build, TestFlight, revisão

### 9.1 Enviar com o `store/release.sh`

No Mac, com o Xcode instalado (não pode ser beta), na pasta do repositório.

Primeiro, só conferir (não envia nada). Troque os campos entre `< >`:

```
IPSIO_TEAM=<TEAM_ID> \
IPSIO_STORE_SIGN='Apple Distribution: <NOME DA EMPRESA> (<TEAM_ID>)' \
IPSIO_INSTALLER_SIGN='3rd Party Mac Developer Installer: <NOME DA EMPRESA> (<TEAM_ID>)' \
IPSIO_PROFILE=~/Downloads/Ipsio_Mac_App_Store.provisionprofile \
ASC_KEY_ID=<KEY_ID> ASC_ISSUER=<ISSUER_ID> \
bash store/release.sh
```

Se terminar com `valid.`, envie de verdade (o mesmo comando, com `--upload` no fim):

```
IPSIO_TEAM=<TEAM_ID> \
IPSIO_STORE_SIGN='Apple Distribution: <NOME DA EMPRESA> (<TEAM_ID>)' \
IPSIO_INSTALLER_SIGN='3rd Party Mac Developer Installer: <NOME DA EMPRESA> (<TEAM_ID>)' \
IPSIO_PROFILE=~/Downloads/Ipsio_Mac_App_Store.provisionprofile \
ASC_KEY_ID=<KEY_ID> ASC_ISSUER=<ISSUER_ID> \
bash store/release.sh --upload
```

O nome dos certificados tem que ser **igual** ao que o `security find-identity -v` mostrou no passo 0.4.

O script precisa de um `icon.png` na raiz do repositório. Sem ícone, a Apple recusa.

### 9.2 TestFlight

1. Em alguns minutos, o build aparece em App Store Connect, aba **TestFlight**.
2. Espere sair de "Processing".
3. Opcional, mas recomendado: em **Internal Testing**, crie um grupo, ponha você, e instale pelo app **TestFlight** da Mac App Store.
4. No TestFlight, a compra é de teste: não cobra nada.

### 9.3 Enviar para revisão

1. Volte à página da versão 1.0 e escolha o build (passo 6.7).
2. Confira se a compra está marcada (passo 6.8).
3. Clique **Add for Review** (alto, à direita).
4. Na tela seguinte, clique **Submit for Review**.

A Apple responde por e-mail. Se pedirem algo, a mensagem chega em App Store Connect, **App Review**.
