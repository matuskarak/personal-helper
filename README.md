# Osobný pomocník

macOS menu bar appka pre slabozrakých — rýchle prečítanie textu (SK/EN, s OCR fallbackom) a diktovanie do ľubovoľného poľa, s voliteľným AI doladením prepisu podľa cieľovej appky ("Smart diktovanie").

- **Bundle ID:** `sk.matuskarak.osobny-pomocnik`
- **Platforma:** macOS 14+, Swift Package Manager, žiadny Xcode projekt
- **Typ appky:** `LSUIElement` — bez Docku, len menu bar ikona
- **Distribúcia:** self-signed (`OsobnyPomocnikDev`) + Sparkle auto-update cez GitHub Releases

## Čo appka robí

1. **Čítanie textu** (Flow A) — označíš text v ľubovoľnej appke → skratka → appka ho prečíta nahlas (TTS, SK/EN auto-detekcia jazyka).
2. **OCR** (Flow B) — skratka → výber oblasti obrazovky → text sa rozpozná a prečíta.
3. **Diktovanie** (Flow C) — klikneš do poľa → skratka → nadiktuješ → text sa vloží (⌘V) do aktívneho poľa.
4. **Smart diktovanie** — voliteľné AI doladenie: transcript + screenshot cieľového okna sa pošlú na OpenAI (vision), ktorý text opraví a naformátuje podľa profilu cieľovej appky (Slack = neformálny chat tón, Mail = zdvorilý tón + štruktúra pozdrav/telo/zoznamy, ChatGPT/Claude = jasný prompt).

Appka funguje aj bez Smart diktovania — to je nadstavba, ktorá sa dá kedykoľvek vypnúť.

## Ako sa appka spúšťa (triggery)

- **Klávesové skratky** — globálny `CGEventTap` cez `HotkeyManager`, nastaviteľné v Preferences.
- **Custom URL scheme** `osobnypomocnik://<action>` (napr. `osobnypomocnik://dictate`) — registrovaný v `Info.plist` (`CFBundleURLTypes`), spracovaný cez `NSAppleEventManager` (`kAEGetURL`) v `AppDelegate.handleGetURL`. Používa sa najmä pre **Logi Options+ "Run command"** akcie (`/usr/bin/open||osobnypomocnik://dictate`) na tlačidlá myši — obchádza to, že syntetické klávesové eventy z Logi Options+ neprejdú cez `CGEventTap`.
  - Prijatie Apple Eventu vynúti aktiváciu appky (aj keď je `LSUIElement`), čo by inak rozbilo focus-based funkcie (pozícia pilulky, screenshot kontext, vkladanie textu). Appka preto priebežne sleduje posledné skutočne fokusnuté okno (`AppDelegate.lastExternalAppPID`, `applicationWillBecomeActive`) — s explicitným ignorovaním vlastného bundle ID aj `com.logi.*`/`com.logitech.*` procesov (Logi Options+ Action Ring je sám osebe overlay, ktorý by inak bol mylne označený za "cieľovú appku") — a pri triggeri jej hneď vráti fokus späť, kým nezačne s AX/paste operáciami.

## Architektúra — hlavné komponenty

| Vrstva | Súbor | Zodpovednosť |
|---|---|---|
| Vstupný bod | `App/AppDelegate.swift` | Lifecycle, URL scheme handler, permissions, dispatch akcií |
| Skratky | `HotkeyManager/HotkeyManager.swift`, `Shortcut.swift` | Globálny `CGEventTap`, viacnásobné skratky per akcia |
| Diktovanie | `Engines/DictationEngine.swift` | Nahrávanie (`DeviceCapture`), realtime (`gpt-live-transcribe` cez WebSocket) aj batch (`gpt-transcribe` REST) prepis, VAD citlivosť, live-insert |
| Smart diktovanie | `Engines/SmartRewriteEngine.swift` | OpenAI Chat Completions (vision) rewrite — Structured Outputs so strict JSON schema, natvrdo zabudovaný anti-refusal/anti-answer hard-rule (nezávislý od používateľom editovateľného promptu) |
| Kontext pre Smart | `Engines/SmartContextCapture.swift` | `ScreenCaptureKit` screenshot aktívneho (najväčšieho on-screen) okna + bundle ID + titulok |
| Aplikačné profily | `Engines/AppProfile.swift` | Per-appka inštrukcie/kľúčové slová/kategória (Slack, Mail, ChatGPT, Claude, fallback) — `AppProfileStore` |
| Fokus/pozícia | `Engines/FocusValidator.swift`, `UI/DictationIndicator.swift` | AX API na zistenie fokusnutého poľa → pilulka sa ukotví nad ním |
| Vloženie textu | `Engines/TextInserter.swift` | Zápis do schránky + `⌘V`, s obnovením pôvodného obsahu schránky |
| História | `Engines/DictationHistoryStore.swift` | Lokálny JSON súbor (`~/Library/Application Support/OsobnyPomocnik/`), bez limitu (bezpečnostný strop 20 000 záznamov), voliteľné ukladanie screenshotov |
| Kvalita diktovania | `Engines/DictationQualityEngine.swift` | Lokálne, zadarmo: filler slová (SK+EN lexikón), tempo (wpm), dĺžka viet, opakovania, Levenshtein distance raw↔rewrite |
| Čítanie textu | `Engines/TextExtractor.swift`, `Engines/TTSEngine.swift`, `Engines/GoogleCloudTTSEngine.swift` | Získanie označeného textu (AX/clipboard), on-device alebo cloud TTS |
| OCR | `Engines/OCREngine.swift`, `UI/OCROverlayWindow.swift` | Výber oblasti obrazovky → Vision framework OCR |
| Pamäť diktovania | `Engines/DictationMemoryStore.swift`, `RecentTextStore.swift` | Fallback úložisko, keď sa diktovanie nedá vložiť priamo (žiadne fokusnuté pole) |
| Nastavenia | `UI/PreferencesView.swift` | Sidebar + kartový layout: Diktovanie (Smart, VAD, profily, história, kvalita), Čítanie, Skratky, Účet |
| Vzdialená konfigurácia | `Engines/RemoteConfig.swift` | `users.json` v GitHub repe — prístupové kódy + per-osoba feature flagy (napr. Smart diktovanie), hodinovo cachované |
| Update | `Engines/UpdaterController.swift` | Sparkle, podpísaný `appcast.xml` |

## Dáta a privacy

Všetko je **lokálne** (žiadny vlastný backend, žiadny cloud okrem priamych OpenAI/Google API volaní iniciovaných používateľom):

- **História diktovania** — `~/Library/Application Support/OsobnyPomocnik/dictation-history.json`. Bez pevného časového/počtového limitu (zámerne, kvôli budúcemu AI enginu na analýzu — pozri nižšie), len bezpečnostný strop 20 000 záznamov.
- **Screenshoty Smart diktovania** (voliteľné, defaultne vypnuté) — `~/Library/Application Support/OsobnyPomocnik/screenshots/<entry-id>.jpg`, životnosť viazaná na záznam histórie.
- **API kľúče** — Keychain (`KeychainHelper.swift`).
- Appka sama nič neposiela na vlastný server — jediná externá komunikácia je: OpenAI (diktovanie, Smart rewrite), Google Cloud TTS (voliteľné), GitHub raw JSON (RemoteConfig, appcast).

## Stav projektu (čo je hotové)

**MVP (v1) — hotové:** čítanie označeného textu, OCR, diktovanie s vložením do aktívneho poľa, menu bar UI, SK+EN, pilulka ukotvená nad aktívnym poľom, história diktovania.

**Ďalšie hotové veci nad rámec pôvodného MVP:**
- Smart diktovanie (AI rewrite podľa cieľovej appky, s vision kontextom zo screenshotu)
- Kvalita diktovania — lokálna analýza (filler slová, tempo, štruktúra) bez AI nákladov
- Poradie/fallback mikrofónov, tester + pasívna kontrola kvality mikrofónu
- Prehľad (Usage) — štatistiky, graf trendu, EUR/USD náklady
- Onboarding, Developer Mode + log viewer, Sparkle auto-update
- Prístupové kódy pre kamarátov cez `users.json` (bez vlastného backendu)
- Trigger cez Logi Options+ ("Run command" → custom URL scheme) s plnou focus-tracking logikou

**Backlog / otvorené:** hover-to-read, karaoke zvýrazňovanie v zdrojovej appke (technicky blokované vo WebKit/Chromium), viacero skratkov pre jednu akciu, fáza 2 enginu na analýzu diktovania (AI sémantika, kompozitné skóre, návrhy úprav profilov), backend API proxy pre štátom preplácanú verziu.

Detailný changelog, rozhodnutia a technické poznámky (prečo `turn_detection` musí byť `null` pri `gpt-live-transcribe`, prečo karaoke nejde vo WebKite, brainstorm filtrovania audia...) sú v Notion stránke **[🧑‍🦯 Osobný pomocník](https://www.notion.so/Osobn-pomocn-k-d9f755b133a84e4f8c73050ee60969c1)** — tento README je technický prehľad kódu, Notion je produktový/rozhodovací log.

## Build & run

```bash
make run        # debug build + spustenie
make release     # optimalizovaný build
```

`build-app.sh` balí SPM executable do `.app` bundlu s pevným bundle ID a self-signed podpisom (nutné, aby macOS TCC povolenia — mikrofón, accessibility, screen recording — vydržali medzi buildmi).
