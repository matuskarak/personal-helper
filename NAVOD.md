# Osobný pomocník — návod na inštaláciu (alfa verzia)

Ďakujem, že to so mnou testuješ. Appka je v skorej testovacej verzii — funguje, ale
očakávaj drobné chyby a pošli mi všetko, čo ťa zaskočí. Celé nastavenie trvá asi 10 minút,
najdlhšie z toho je vytvorenie OpenAI účtu.

Budeš potrebovať: Mac s macOS 14 alebo novším, platobnú kartu na OpenAI (platíš len za to,
čo nadiktuješ — bežné používanie vyjde na 1–3 € mesačne) a mikrofón (zabudovaný stačí).

---

## 1. Inštalácia

1. Stiahni zip zo odkazu, ktorý som ti poslal, a rozbaľ ho (dvojklik).
2. Presuň **OsobnyPomocnik.app** do priečinka **Aplikácie**.
3. Spusti ju dvojklikom. **macOS ju odmietne otvoriť** — to je v poriadku, appka zatiaľ nie je
   registrovaná u Apple (to príde s ostrou verziou). Klikni *Hotovo* / *Zrušiť*.
4. Otvor **Systémové nastavenia → Súkromie a bezpečnosť**, zroluj úplne dole do sekcie
   *Bezpečnosť*. Uvidíš hlásenie „Aplikácii OsobnyPomocnik bolo zablokované otvorenie…"
   a vedľa tlačidlo **Otvoriť napriek tomu**. Klikni naň a potvrď heslom / Touch ID.
5. Appka sa spustí — v hornej lište vpravo pribudne jej ikonka. Žiadne okno na ploche,
   žiadna ikona v Docku — všetko sa ovláda z hornej lišty a klávesovými skratkami.

Toto robíš **len raz**. Ďalšie aktualizácie si appka sťahuje a inštaluje sama.

## 2. Prvé spustenie — povolenia

Pri prvom spustení sa otvorí okno *Vitaj v Osobnom pomocníkovi*. Prejde ťa dvomi povoleniami:

| Povolenie | Načo | Ako |
|---|---|---|
| **Prístupnosť (Accessibility)** | globálne skratky a vkladanie textu | Klikni *Povoliť* → v Systémových nastaveniach zapni prepínač pri OsobnyPomocnik |
| **Mikrofón** | diktovanie | Klikni *Povoliť* → potvrď v dialógu |

Po každom zapnutí sa vráť do appky — riadok sa sám zmení na zelenú fajku. Ak nie, klikni
*Skontrolovať znova*.

## 3. OpenAI API kľúč

Appka nemá vlastný kľúč — diktovanie ide cez tvoj OpenAI účet.

1. Vytvor si účet na **platform.openai.com/signup** (stačí Google prihlásenie).
2. V **Billing** pridaj kartu a nabi kredit — **5 $ stačí na mesiace** testovania.
3. V **API keys** klikni *Create new secret key*, pomenuj ho napr. „Osobný pomocník"
   a **hned ho skopíruj** — OpenAI ho ukáže len raz.
4. V okne appky ho vlož do poľa *sk-…* (tlačidlo *Prilepiť*), klikni **Uložiť** a potom
   **Testovať kľúč**. Musí sa objaviť zelené ✅.

Kľúč sa ukladá do Kľúčenky macOS, nie do bežného súboru.

Ostatné polia v okne (Gemini, Google čítanie, prístupový kód) **preskoč** — sú voliteľné.

Prepínač **Zdieľať anonymné štatistiky používania** nechaj prosím zapnutý — posiela mi tempo
reči, počet slov, výplňové slová, dĺžku a výsledok diktovania a typ appky (správy / e-mail /
dokument). **Nikdy nie samotný text**, mená, kľúčové slová ani kľúče. Presne z toho viem
prepis zlepšovať. Vypnúť sa dá kedykoľvek v Nastaveniach → Všeobecné.

Klikni **Zavrieť**.

## 4. Prvé diktovanie

1. Klikni do ľubovoľného textového poľa — Poznámky, Mail, prehliadač…
2. Stlač **⌘⇧D**. Nad poľom sa objaví malá pilulka s ekvalizérom — hovor.
3. Stlač **⌘⇧D** znova. Za 2–5 sekúnd sa text vloží tam, kde bol kurzor.

Ak sa pomýliš, **⌘⇧X** diktovanie zruší a nahrávku zahodí.

### Skratky (dajú sa zmeniť v Nastaveniach → Skratky)

| Skratka | Čo robí |
|---|---|
| **⌘⇧D** | Diktovanie — spustí aj zastaví nahrávanie, prepis sa vloží po zastavení |
| **⌘⇧X** | Zrušiť bežiace diktovanie |
| **⌘⇧R** | Prečítať označený text nahlas |
| **⌃⌥V** | Vložiť posledný prepis, ak sa nemal kam vložiť |

Ak si stlačil skratku bez kurzora v texte, prepis sa nestratí — appka ho drží v pamäti
a **⌃⌥V** ho vloží neskôr.

## 5. Nastavenia

Ikonka v hornej lište → **Nastavenia…**

- **Všeobecné** — všetky API kľúče a mena, v ktorej vidíš odhad ceny.
- **Diktovanie** — výber modelu (na výber sú dva: GPT je rýchlejší, Gemini presnejší na
  odborné výrazy), kľúčové slová (mená, odborné výrazy, ktoré model často komolí — sem ich
  napíš), pozícia pilulky.
- **Mikrofón** — poradie mikrofónov a **Test mikrofónu**. Odporúčam spustiť raz na začiatku.
- **Prehľad** — koľko si nadiktoval a koľko to stálo.

## 6. Keď niečo nefunguje

Skôr než mi napíšeš:

1. Otvor **Nastavenia → O aplikácii → Diagnostika**.
2. Skontroluj, že prepínač *Diagnostika* je zapnutý. Záznam neobsahuje tvoje prepisy ani kľúče —
   len priebeh appky (časy, chyby, názov appky, do ktorej si diktoval).
3. Zopakuj problém.
4. Klikni **Pripraviť na poslanie** — na plochu sa uloží súbor. Pošli mi ho spolu s tým,
   čo si robil a čo si čakal, že sa stane.

Časté veci:

- **Skratka nereaguje** → skontroluj Prístupnosť v Systémových nastaveniach → Súkromie
  a bezpečnosť. Po aktualizácii macOS sa niekedy povolenie vypne.
- **„Pripájam mikrofón…" trvá dlho** → prvé diktovanie po spustení je pomalšie, ďalšie sú
  okamžité. Ak to trvá vždy, pozri Nastavenia → Mikrofón, či je hore ten správny.
- **Pilulka hlási chýbajúci kľúč** → Nastavenia → Všeobecné → Testovať kľúč.

## 7. Aktualizácie

Appka si raz denne skontroluje novú verziu a ponúkne ju. Kedykoľvek aj ručne:
ikonka v lište → **Skontrolovať aktualizácie…**. Pri aktualizácii sa už žiadne
„Otvoriť napriek tomu" neopakuje.

Po aktualizácii sa môže objaviť dialóg **„OsobnyPomocnik chce použiť dôverné informácie
uložené v Kľúčenke"** — appka si číta tvoj API kľúč. Klikni **Vždy povoliť** (nie len
„Povoliť"), inak sa to spýta znova po každej aktualizácii. Kým dialóg neodklikneš, appka
čaká a nereaguje.

---

Ozvi sa s čímkoľvek — aj s tým, čo ti len prišlo divné alebo nepohodlné. Práve to potrebujem.
