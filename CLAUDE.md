# ⚠️ Aktuálne aktívna je TESTOVACIA vetva

Tento pracovný adresár je momentálne prepnutý na **`test/local-whisper-sk`** — samostatnú
git vetvu vytvorenú **len** na experiment s lokálnym (on-device) Whisper modelom pre
slovenčinu (WhisperKit + fine-tuned `NaiveNeuron/whisper-large-v3-turbo-sk`).

## Pravidlo pre Claude (a pre mňa, keď sa sem o pár dní vrátim)

- **Bežná (produkčná) verzia appky je na branchi `master`.** Ak príde požiadavka, ktorá
  NESÚVISÍ s testovaním lokálneho Whisper modelu (bugfix, nová appka feature, UI zmena,
  čokoľvek nesúvisiace s WhisperKit experimentom), **najprv prepni na `master`**
  (`git checkout master`) a rob zmenu tam, nie na tejto testovacej vetve.
- Táto vetva (`test/local-whisper-sk`) je určená VÝHRADNE na:
  - integráciu WhisperKit ako alternatívneho/paralelného transkripčného enginu,
  - testovanie presnosti slovenčiny s `NaiveNeuron/whisper-large-v3-turbo-sk` (alebo iným
    SK-ladeným checkpointom) oproti terajšiemu cloud riešeniu (OpenAI `gpt-transcribe` /
    `gpt-live-transcribe`),
  - čokoľvek iné explicitne označené ako súčasť tohto testu.
- Ak si nie si (Claude) istý, či požadovaná zmena patrí sem alebo na `master` — **spýtaj sa**,
  nepredpokladaj.
- Táto vetva sa **nemergne do `master` automaticky** — až keď používateľ vyhodnotí test a
  explicitne povie, že chce lokálny model natrvalo integrovať.

## Kontext experimentu

- **Cieľ:** zistiť, či lokálny (on-device, offline) Whisper model dosahuje na slovenčine
  dostatočnú presnosť ako alternatíva/doplnok k cloud transkripcii.
- **Model:** [`NaiveNeuron/whisper-large-v3-turbo-sk`](https://huggingface.co/NaiveNeuron/whisper-large-v3-turbo-sk)
  (fine-tuned na SloPalSpeech datasete) — potrebuje konverziu na CoreML cez
  [`whisperkittools`](https://github.com/argmaxinc/whisperkittools) pred použitím vo
  WhisperKite.
- **Runtime:** [WhisperKit](https://github.com/jkrukowski/WhisperKit) (Argmax) — Swift
  balík, beží on-device cez CoreML/Neural Engine, **len Apple Silicon** (pozri nižšie).
- **Východiskový bod pre porovnanie:** `master` branch, cloud transkripcia cez OpenAI
  (`DictationEngine.swift`, `gpt-transcribe` batch / `gpt-live-transcribe` realtime).

## Prečo len Apple Silicon (nie Windows)

WhisperKit je postavený na Apple CoreML + Neural Engine — funguje len na macOS/iOS,
**nie na Windowse ani Linuxe**. Na Windows/iné platformy by ekvivalentná lokálna cesta bola
iný runtime (napr. `whisper.cpp` s CUDA, alebo `faster-whisper`/CTranslate2) — architektúra
modelu (Whisper) je rovnaká, len spôsob behu na hardvéri je iný balík/kód. Pre tento projekt
(macOS appka) je WhisperKit správna voľba, len je to vedomá viazanosť na Apple hardvér.
