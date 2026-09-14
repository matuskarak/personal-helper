# Ozvena — pokyny pre Claude

Aktívna vetva je **`master`**. Bežná práca (bugfixy, nové funkcie, UI) ide sem, žiadne
prepínanie nie je potrebné.

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
v `NAVOD.md`). Licencie, platby a predplatiteľský backend sú odložené.

**Feature flagy** žijú v `users.json` (per prístupový kód, `RemoteConfig.Entitlements`).
Tester bez kódu dostane: batch diktovanie ⌘⇧D, zrušenie ⌘⇧X, čítanie ⌘⇧R, vloženie z pamäte,
históriu, Kvalitu, Prehľad, 2 modely (gpt-transcribe, gemini-3.5-transcribe). Za kódom sú:
Smart ⌘⇧A, realtime ⌘⇧S + live vkladanie, OCR ⌘⇧O, tieňový prepis, ostatné modely katalógu.
Repo je **verejné** — kódy v users.json sú viditeľné, je to alfa-úroveň ochrany.

**Telemetria** (`Engines/Telemetry.swift`): anonymné udalosti (metriky z DictationQualityEngine,
trvanie, model, výsledok, latencia, kategória appky, feature tapy) → n8n webhook
`n8n.pixeled.sk/webhook/osobny-pomocnik-telemetry` → Data Table `osobny-pomocnik-telemetry`
(workflow `Ub6Tttj5GbNi4QiX`). Predvolene zapnuté, vypínateľné vo Všeobecné a v onboardingu.
Nikdy neposielať prepis, kľúčové slová, názvy appiek/okien, kľúče.

**Nesmie do logu:** prepisy, kľúčové slová, API kľúče, prístupový kód. Batch cesta loguje len
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
