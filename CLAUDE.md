# Ozvena — pokyny pre Claude

Aktívna vetva je **`master`**. Bežná práca (bugfixy, nové funkcie, UI) ide sem, žiadne
prepínanie nie je potrebné.

## Overovanie zmien v UI — nepoužívať computer use, opýtať sa usera (od 2026-09-14)

Appka je `LSUIElement` (menu bar, floating panely bez Docku) — automatizované UI testovanie cez
AppleScript/System Events/`cliclick` je v tomto prostredí nespoľahlivé (flaky AX čítania, skryté
okná, cliclick drag simulácia neverne reprodukuje reálne gestá) a stojí veľa času/rebuildov.
**Namiesto vlastného automatizovaného klikania/draggovania cez computer use radšej over `swift
build` a popíš userovi presne, čo má sám vyskúšať a čo očakávať** — user si to otestuje naživo
sám a povie výsledok. Výnimka: `swift build`/`./build-app.sh` a čítanie `app.log` sú v poriadku
(to nie je "computer use", len build a log).

## Dizajn UI — vždy cez skill `design-taste-frontend`

Pri akomkoľvek návrhu/úprave vzhľadu (rozloženie, veľkosti okien/popupov, spacing, stavy
loading/empty/error) najprv načítaj skill `design-taste-frontend`. Je písaný pre web
(React/Tailwind), appka je natívne SwiftUI/AppKit — **kód a komponenty z neho sa nekopírujú**,
ale jeho princípy áno: žiadny mŕtvy priestor (veľkosť okna/sheetu sedí na obsah, nie fixná pre
každý stav), state-aware layout (loading/empty/loaded majú rozdielne rozmery), plná šírka
kontajnera namiesto zbytočných okrajov, jeden spacing rytmus, žiadne "AI-default" flákanie
(napr. fixný box "na všetko"). Pre natívne macOS špecifiká (HIG, `.popover` vs `.sheet`,
`NSWindow` správanie) sa riaď Apple Human Interface Guidelines, skill sa netýka natívnych platforiem.

Brand/design handoff (farby, fonty, ikony, špecifikácie komponentov — "Ozvena" design system) žije
v `Vyvoj/` v koreni repa — **lokálne, gitignorované, nie je súčasťou repa** (rozhodnutie 2026-09-14:
niekto, kto si appku stiahne, chce nástroj, nie dizajnovú dokumentáciu a duplicitné assety navyše;
skutočné assety, čo appka reálne potrebuje na build, sú skopírované v `Sources/.../Resources/`).
Komentáre v kóde (`Theme.swift`, `ControlPanelWindow.swift`, `DictationIndicator.swift`,
`TTSEngine.swift`) odkazujú na súbory v `Vyvoj/*.md` ako zdroj rozhodnutí — tie odkazy platia len
na tomto stroji. Na inom stroji/klone bez `Vyvoj/` sú hodnoty v `Theme.swift` sami o sebe zdrojom
pravdy, nič sa tým nestráca pre samotný build.

## Uzavretý experiment: lokálny (on-device) Whisper

Experiment s lokálnym prepisom (WhisperKit + `NaiveNeuron/whisper-large-v3-turbo-sk`)
je **ukončený a NEBOL prijatý**. Kód z neho je odstránený z `master`, celý funkčný stav
je zachovaný v git značke:

```
git checkout -b <nazov-vetvy> experiment/local-whisper-sk
```

Značka nesie v popise celé meranie aj dôvody. Skrátene — na 98 diktovaniach (17.–19. 8. 2026)
lokálny model prehral vo všetkých troch rozmeroch naraz:

| | lokálny (WhisperKit SK) | cloud (`gpt-transcribe`) |
|---|---|---|
| pokusov | 67 | 31 |
| prázdny výsledok (1. pokus) | 12 (18 %) | 0 (0 %) |
| natrvalo stratené | 7 (10 %) | 0 |
| medián prepisu | 4,1 s | 1,8 s |
| najhorší prípad | 16,6 s | 5,8 s |

Rozhodujúca bola presnosť: na rovnakej téme (Elementor/WordPress) lokálny model dával
*„Českého vlážu"*, *„cezva videty"*, *„určené s vedostom a rusenskou"*, kým cloud zvládol
*carousel / Elementor / listing grid / loop carousel* bezchybne aj v dlhších diktovaniach.

**Ak sa téma vráti, toto už netreba znovu skúšať:** `large-v3-turbo-sk` je najlepší dostupný
SK fine-tune; plné `large-v3` by bolo ešte pomalšie (lokál je už teraz 2× pomalší než cloud
round-trip); vlastný fine-tuning na hlase je práca na dni a nevyriešil by anglické technické
termíny, na ktorých to padá najviac; streaming by zlepšil dojem z latencie, ale nie presnosť.

Zmysel má už len ako **offline režim** (lietadlo, práca bez internetu, striktne lokálne
spracovanie) — teda ako doplnok, nie ako náhrada cloudu.

Na obnovenie treba aj skonvertovaný CoreML model v
`~/Documents/whisperkit-models-sk/NaiveNeuron_whisper-large-v3-turbo-sk`
(postup konverzie cez `whisperkittools` je v CLAUDE.md na tej značke).

## Stav: alfa pre známych (od 2. 9. 2026, aktuálne v0.4.0)

Appka sa distribuuje ako **BYOK** (používateľ vloží vlastný OpenAI/Gemini kľúč) cez GitHub
Release `builds` + Sparkle. Bez Developer ID (Gatekeeper → „Otvoriť napriek tomu", postup je
v `NAVOD.md`). Platby a predplatiteľský backend sú odložené — licenčné kľúče (nižšie) už nie.

**Licenčný kľúč (od 2026-09-14) — appka bez neho vôbec nefunguje.** Nahradil starší
"prístupový kód" systém (`users.json` v tomto repe) — ten sa **prestal používať práve preto, že
`users.json` bol verejný súbor s kódmi v plaintexte**, čo pre tvrdý gate nestačí. Kľúč sa teraz
overuje proti vlastnému hosted backendu (`RemoteConfig.swift`, `POST /api/validate.php`) — PHP +
SQLite, beží na Hostinger Business hostingu, **kód backendu je v samostatnom priečinku
`~/Cluade Projects/Ozvena-licencie/`, zámerne mimo tohto (verejného) repa appky**, nikdy sem
nepatrí. Endpoint dostane jeden kľúč naraz a vráti `{valid, entitlements}` — appka nemá spôsob,
ako vypýtať zoznam platných kľúčov.

Bez platného kľúča appka odmietne diktovanie/čítanie/OCR/vloženie z pamäte (`AppDelegate.requireLicense()`)
a onboarding (`OnboardingWindowController`) sa nedá zavrieť — zobrazuje sa na každom štarte, kým
`RemoteConfig.shared.hasValidLicense` nie je `true`. Developer Mode obchádza gate (rovnako ako
ostatné entitlements). Platný kľúč sa cachuje lokálne (`UserDefaults`), takže appka funguje aj
offline **po** prvom úspešnom overení — nikdy predtým (žiadny fail-open na prvé spustenie).

**Entitlements** (`RemoteConfig.Entitlements`) — čo konkrétna licencia navyše odomkne: Smart ⌘⇧A,
realtime ⌘⇧S + live vkladanie, OCR ⌘⇧O, ostatné modely katalógu. Predvolene všetko vypnuté
(základná úroveň appky = batch diktovanie ⌘⇧D, zrušenie ⌘⇧X, čítanie ⌘⇧R, vloženie z pamäte,
história, Kvalita, Prehľad, 2 modely). Pridanie/úprava licencie: `.../Ozvena-licencie/admin/`
(prihlásenie heslom, presné URL a heslo nepatria do tohto súboru ani nikam do gitu appky) —
zoznam licencií tam má pri každej rozbaľovacie "Funkcie" s checkboxami, žiadne ručné SQL.

**Developer mode vs. Diagnostika (od 2026-09-14) — dve rozdielne veci, nezamieňať:**
- **Diagnostika** (O aplikácii, `AppLogger`/`AudioHealth`) je pre KAŽDÉHO testera predvolene
  zapnutá — len log súbor, nič nestojí, nič neodomyká.
- **Developer mode** (`entitlements.developerModeEnabled`, checkbox v admin dashboarde,
  oddelený a zvýraznený od bežných entitlements, appka: `RemoteConfig.developerModeGranted`)
  je pre KONKRÉTNU licenciu, nikdy predvolene. Automaticky odomkne všetky štyri entitlements
  vyššie a naviac odhalí v appke testovacie UI v O aplikácii (dnes: A/B test strihania ticha,
  tieňový prepis druhým modelom — obe prepíšu každé diktovanie ešte raz navyše, dvojnásobná
  cena), ktoré bežný tester nesmie mať zapnuté náhodou. **Tieňový prepis** (porovnanie dvoch
  modelov, `dictation.shadowCompareEnabled`, výsledky v Kvalite) bol pôvodne (do 2026-09-14)
  vlastná entitlements ako Smart/Realtime/OCR — user sa rozhodol, že to má byť čisto dev-only
  funkcia, nie niečo, čo dostane bežný tester zvlášť; `RemoteConfig.shadowCompareAllowed` je
  teraz `developerModeGranted` priamo, bez vlastného entitlements poľa. Lokálny `#if DEBUG`
  `DeveloperMode.isEnabled` toggle (Xcode build) na to isté
  zostáva bokom, len pre vlastný vývoj bez licencie. Zmena entitlements sa v appke prejaví po
  reštarte (alebo do hodiny, auto-refresh) — netreba nový build.

**Telemetria** (`Engines/Telemetry.swift`): anonymné udalosti (metriky z DictationQualityEngine,
trvanie, model, výsledok, latencia, kategória appky, feature tapy) → n8n webhook
`n8n.pixeled.sk/webhook/osobny-pomocnik-telemetry` → Data Table `osobny-pomocnik-telemetry`
(workflow `Ub6Tttj5GbNi4QiX`). Predvolene zapnuté, vypínateľné vo Všeobecné a v onboardingu.
Nikdy neposielať prepis, kľúčové slová, názvy appiek/okien, kľúče.

**Nesmie do logu:** prepisy, kľúčové slová, API kľúče, licenčný kľúč. Batch cesta loguje len
počty znakov; realtime WS loguje len typ eventu. Diagnostika (app.log + audio-health.log) má
jeden prepínač v O aplikácii, predvolene zapnutý.

## Záloha — kontrola na začiatku KAŽDEJ session (povinné)

Používateľské dáta appky (API kľúče v Kľúčenke, nastavenia, kľúčové slová, história) sa
3. 9. 2026 raz stratili spustením reset skriptu na ostrom účte. Aby sa to už nezopakovalo:

1. **Hneď na začiatku session** over, či je z dnešného dňa záloha:
   ```bash
   ls -1 ~/Library/Application\ Support/OsobnyPomocnik-zalohy/ | tail -1
   ```
   Názov zálohy je `YYYYMMDD-HHMMSS`. Ak najnovšia **nie je z dnešného dátumu**, spusti:
   ```bash
   ./scripts/backup-settings.sh
   ```
   (môže vyžiadať prístup ku Kľúčenke — používateľ klikne „Vždy povoliť"). Používateľovi
   jednou vetou napíš, že záloha prebehla / už existovala.
2. **Pred každou zmenou nastavení, kľúčov alebo skratiek** a **pred každým resetom** spusti
   zálohu znova — aj keď dnešná už existuje.
3. `reset-fresh-install.sh` **nikdy nespúšťaj sám** na účte používateľa — daj mu príkaz a nechaj
   rozhodnutie na ňom. Obnova: `./scripts/reset-fresh-install.sh --restore`.

Zálohy sú mimo repa (`~/Library/Application Support/OsobnyPomocnik-zalohy/`), `keys.plist`
má práva 600. Nikdy ich nekopíruj do repa — je verejné.

## Aktuálne priority

1. **Flow test alfy** na čistom účte podľa `NAVOD.md`, potom rozoslať známym.
2. **Zber dát od testerov (GDPR)** — návrh opt-in exportu metrík/prepisov na zlepšenie enginu;
   zatiaľ nerozhodnuté, čo presne sa zbiera.
3. Rýchlosť diktovania; výkon menu a Nastavení.

## Strihanie ticha (SilenceTrimmer) — stav a nápad na nadviazanie

Od 2026-09-08 batch mode naozaj strihá potvrdené dlhé ticho pred uploadom
(`Engines/DictationEngine.swift`, `SilenceTrimmer`) — nielen meria ako predtým (`SilenceTracker`,
ponechané bokom). Strihá až od 4s súvislého ticha (konzervatívne, na želanie), s "debounce" 0,3s
proti krátkym zvukovým záškubom (mikrofón/miestnosť), ktoré by inak fragmentovali dlhú pauzu na
kratšie kúsky a zabránili strihu. Overené na reálnom teste: 15s pauza → vystrihnutých 14s.

Momentálne beží **A/B test v teréne** (`dictation.silenceTrimABTestEnabled`, prepínač v O aplikácii
pod Developer mode) — každé diktovanie s reálnym strihom sa navyše prepíše aj netrimovane tým istým
modelom, oba texty idú do histórie (`trimTestText` vs `text`) na porovnanie. Cieľ: overiť, či strih
niekde neodrezal reč. Po dni testovania vypnúť a vyhodnotiť.

**2026-09-09 — prvé 2 reálne A/B porovnania (nie testovacie diktovania, skutočná práca):** obsahovo
100% v poriadku, žiadny stratený text na hranici strihu, rozdiely medzi trimovaným a netrimovaným
prepisom sú bežný šum rovnakého modelu (drobné slovné varianty, interpunkcia) — rovnaký typ šumu,
aký sme predtým zmapovali pri Gemini/GPT porovnaní. Vzorka je zatiaľ malá (2 porovnania), nechať
bežať ďalej. Zdanlivá nezhoda v diagnostickom logu (`trimmer vystrihol` niekedy vyššie než
`tracker meria`) **nie je bug** — `SilenceTracker` nemá debounce a počíta len súvislé úseky ≥1,5s,
takže pauzu prerušenú krátkym zvukovým záškubom vidí ako viac kratších úsekov, kým `SilenceTrimmer`
ich vďaka debounce zlepí do jednej dlhšej. Log riadok bol kvôli tomu prepísaný, aby čísla nepôsobili
ako "malo by sa zhodovať".

## Pilulky — pozícia per displej + TTS race fix (2026-09-17)

**Bug 1 — čítanie sa nakrátko spustilo aj bez toho, aby ho niekto spustil.** Príčina:
`GoogleCloudTTSEngine.speak()` (sentence-pipeline, prehráva vetu po vete) kontrolovalo
`isSpeaking` len na začiatku každej iterácie, nie hneď po `await nextFetch.value`. Keď
`stop()` (tlačidlo Stop na pilulke čítania, `ControlPanelWindow.swift`) prišlo práve vo chvíli,
keď sieťové stiahnutie ďalšej vety bežalo, tá veta sa aj tak prehrala — inak nesúvisiaci moment
(napr. začiatok diktovania krátko nato) len zhodou okolností pôsobil, akoby ho spustilo
diktovanie. Oprava: druhá `guard isSpeaking else { break }` hneď po `await` (`GoogleCloudTTSEngine.swift`).
Diktovanie samotné `TTSEngine`/Google engine vôbec nevolá — potvrdené grepom, žiadna priama
príčinná väzba medzi štartom diktovania a čítaním neexistuje.

**Bug 1b (ten istý deň, prvá oprava nestačila) — útržok starého čítania pri štarte/konci
diktovania.** Log potvrdil, že v tom momente sa NEvolá `handleReadText` ani `speak()`, ducking je
vypnutý — jediné, čo appka pri skratke diktovania zvukovo robí, sú tóny `DictationSounds`
(NSSound). Pracovná hypotéza (neoverená meraním, overuje user naživo): `AVAudioPlayer.stop()`
uprostred vety nechá už nabufferovaný zvuk "visieť" pod prehrávačom a ten vyjde ako krátky
záblesk, keď appka po nečinnosti výstupného zariadenia znova vydá akýkoľvek zvuk. Oprava v
`GoogleCloudTTSEngine.stop()`: prehrávač sa najprv stlmí na 0 a nechá 0,4 s dobehnúť (buffer
odtečie ako ticho), až potom `stop()`. Popri tom opravené dve reálne diery: (1) `generation`
token namiesto `isSpeaking` v pipeline slučke — nový `speak()` počas starého (druhé ⌘⇧R, zmena
rýchlosti) nechával starú slučku žiť a prehrať svoju ďalšiu vetu cez novú; (2) `resume()` bez
guardu vedel dočítaný prehrávač pustiť od nuly, dočítaný prehrávač sa teraz uvoľňuje. Pribudli
log riadky `[GoogleTTS]` (len počty znakov) — ak sa to zopakuje, log ukáže, či pri tom beží
náš kód, alebo ide o zvukové zariadenie.

**Zamrznutie appky 2026-09-17 14:29 — nebola to chyba appky, ale zaseknutý `coreaudiod`.**
Systémový log: 13:54:37 prišiel hovor cez iPhone (`callservicesd`/`Phone`) → prekonfigurovanie
zvuku (Sonos Ace BT, mikrofón iPhonu) → `arkaudiod` (Rogue Amoeba ARK, SoundSource 6.1.3)
si nanovo registroval tapy → posledný riadok `coreaudiod` 13:54:41.931, potom 25 min ticho,
klientom timeouty (`0x10004003`) a od 13:55:41 `0x10000004`. Ozvena v tom čase nerobila nič.
Zamrzla až o 14:29 pri štarte diktovania: HAL vrátil 0 vstupov, appka napriek tomu pokračovala
do AVAudioEngine a `installTap` zostal visieť v mach_msg na hlavnom vlákne. Oprava
(`DictationEngine.startRecording`): prázdny zoznam vstupov = okamžitá chyba s hláškou o
`sudo killall coreaudiod`. Pozn.: obyčajný `killall` zaseknutý coreaudiod ignoruje, treba `-9`.

**Bug 2 — pilulky si "nepamätali" pozíciu pri prechode na externý monitor.** Obe pilulky
(`DictationIndicator.swift`, `ControlPanelWindow.swift`) ukladali pozíciu ako holý bod v
súradniciach obrazovky, overený pri načítaní len geometrickým "patrí ešte niektorej aktuálnej
`NSScreen`?" — čo pri zmene rozlíšenia/usporiadania displejov (aj bez odpojenia monitora) zhodí
uložený bod mimo akejkoľvek aktuálnej obrazovky, appka to potichu vyhodnotí ako "monitor
odpojený" a spadne na default pozíciu. Nový `DisplayPosition.swift` ukladá pozíciu do slovníka
kľúčovaného `CGDirectDisplayID` (fyzický displej, stabilný cez zmeny rozlíšenia aj reštarty
appky) namiesto jedného globálneho bodu — každý displej má svoju zapamätanú pozíciu. Platí pre
obe pilulky; dictation pilulka mimo toho zachováva "sleduj zaostrené pole" (`followFocusedField`)
ako predtým — len keď pole nie je zaostrené, spadá na túto per-displej zapamätanú (alebo
default vycentrovanú) pozíciu namiesto jednej spoločnej pre celý stôl.

## Otvorené — realtime diktovanie s live vkladaním (2026-09-14)

Dve veci ladené 2026-09-12/14, obe zlepšené, ani jedna doriešená — pokračovať v ďalšej session:

- **Pilulka pri live vkladaní sa zbaľuje/rozbaľuje trhane.** Pôvodne (`DictationEngine.swift`)
  `liveText` (text v pilulke) sa napĺňal pri každom delte bez ohľadu na to, či ten istý text ide aj
  do zaostreného poľa (`liveInsertActive`) — opravené, teraz sa `liveText` napĺňa len keď live
  vkladanie nie je aktívne. Zbaľovací mechanizmus (`DictationIndicator.swift`, `isCompact`) bol
  navyše prerobený, aby kopíroval presne to, čo pri bežnom (batch) diktovaní funguje spoľahlivo:
  `liveInsertCompact` @State + `withAnimation` na tom istom 5s časovači ako `autoCompact`, namiesto
  priameho čítania `engine.liveInsertActive`. Používateľ potvrdil, že aj po týchto zmenách animácia
  stále nie je ideálna — **nevieme presne prečo**, keďže v tomto prostredí sa nedá spoľahlivo
  odfotiť/nahrať bežiaca animácia appky (computer-use nezachytí LSUIElement okná appky, pozri
  `PLAN-ui-redesign.md` vo `Vyvoj/`). Ďalší krok, ak sa k tomu niekto vráti: nechať používateľa
  spraviť krátky screen recording, dá sa analyzovať cez video-analyzer nástroj snímka po snímke.
- **API probe (`DictationEngine.swift`, `apiProbeTask`) hlásil falošné poplachy** — HEAD request na
  4s timeout niekedy zlyhal, hoci reálne WebSocket pripojenie o pár sekúnd nato fungovalo (doložené
  v logu 2026-09-12: probe zlyhal, o 37s nato úspešne odoslaných 401 znakov live). Opravené na
  retry — druhý pokus o 3s, hláška "API je nedostupné" sa ukáže len keď zlyhajú oba. Používateľ
  hlásil, že sa hláška objavila znova aj po tejto oprave — možné, že 3s odstup je stále príliš
  krátky, alebo ide o iný druh zlyhania než len prechodný network blip. Netestované do hĺbky.

**Nápad na ďalší krok (zatiaľ len zaznamenané, neimplementované, čaká na výsledok A/B testu):**
ak sa ukáže, že strihanie/meranie ticha je spoľahlivé, dá sa tá istá amplitúda použiť aj na iný účel
— detekciu "používateľ je príliš ďaleko od mikrofónu / nie je počuť". Namiesto strihu by v tomto
prípade appka mala **zastaviť diktovanie, upozorniť zvukom/notifikáciou** ("Si ďaleko od mikrofónu
alebo nie je ťa dobre počuť") a nepokračovať v nahrávaní zle počuteľnej reči. Netreba to riešiť skôr,
než bude jasné, že amplitúdový prah je pre tento účel dosť spoľahlivý (rovnaké riziko ako pri
strihaní — pevný prah 300 nekalibrovaný na konkrétny mikrofón, viď SilenceTrimmer komentár).
