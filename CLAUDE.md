# Osobný pomocník — pokyny pre Claude

Aktívna vetva je **`master`**. Bežná práca (bugfixy, nové funkcie, UI) ide sem, žiadne
prepínanie nie je potrebné.

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

## Stav: alfa pre známych (od 2. 9. 2026, v0.2.0)

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

## Aktuálne priority

1. **Flow test alfy** na čistom účte podľa `NAVOD.md`, potom rozoslať známym.
2. **Zber dát od testerov (GDPR)** — návrh opt-in exportu metrík/prepisov na zlepšenie enginu;
   zatiaľ nerozhodnuté, čo presne sa zbiera.
3. Rýchlosť diktovania; výkon menu a Nastavení.
