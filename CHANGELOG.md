# Zmeny

## Nevydané

- Smart beží na novších modeloch (GPT-6 Luna alebo Gemini 3.8 Flash, voľba v Nastavenia → Diktovanie → Smart) — staré modely OpenAI 14. 1. 2027 končia. Smart je presnejší (nevynechá mená, čísla ani dni, splní „vymaž poslednú vetu“), lacnejší, a funguje aj keď máš len jeden z kľúčov OpenAI / Gemini. Návrhy kľúčových slov idú cez ten istý model.
- Menu ukazuje, akú verziu máš, a keď je nová, ponúka „Aktualizovať na …“ až do inštalácie — aj keď okno s ponukou zavrieš; v Nastaveniach svieti „Nová verzia“. Okno aktualizácie je po slovensky a novinky sú v ňom ako zoznam.
- Prompt „Kontext zo screenshotu“ sa dá jedným klikom vrátiť na predvolený.
- Appka po diktovaní nezadrháva pri ukladaní histórie (ukladá sa na pozadí) a karta Kvalita v Nastaveniach sa otvára okamžite aj pri veľkej histórii.
- Prvé diktovanie po spustení appky (najmä s AirPods či iným Bluetooth zvukom) sa už nezasekne na pár sekúnd — appka ostane živá a ak mikrofón chvíľu trvá, pilulka ukáže „Pripravujem mikrofón…“.
- Pozastavenie hudby počas diktovania (Nastavenia → Diktovanie → Ostatné zvuky) konečne funguje: Spotify, Hudbu a TV pozastaví spoľahlivo, video v prehliadači a ostatné prehrávače klávesou Prehrať/Pozastaviť — a po diktovaní všetko znova pustí.
- Keď hrá naraz viac prehrávačov (napr. YouTube v prehliadači aj appka YouTube Music), pozastaví sa jeden a zvyšok sa počas diktovania stíši.
- Keď máš slúchadlá (Bluetooth, USB, jack), stíšenie aj pozastavenie sa vynechá — mikrofón hudbu nepočuje (dá sa vypnúť).
- Úprava označeného textu hlasom: označ text, stlač ⌘⇧A, povedz čo s ním (napr. „sprav to formálnejšie“, „daj to do odrážok“, „pridaj tam, že…“) a znova ⌘⇧A — upravený text sa ukáže v okne kontroly a po vložení nahradí označený text. ⌘⇧A teda diktovanie aj spúšťa.
- Smart pri odpovedi v e-mailovom vlákne už nepridáva „Ďakujem“, „Majte sa“ či „S pozdravom“, ktoré si nenadiktoval; pri novom e-maile funguje ako doteraz.
- Pilulka diktovania sa zbaľuje a rozbaľuje plynulo, bez poskakovania a orezania (najmä pri živom vkladaní ⌘⇧S).
- Keď prepis zlyhá na strane poskytovateľa (výpadok, denný limit), diktovanie sa dokončí cez druhého — Gemini ↔ OpenAI, ak máš zadané oba kľúče — namiesto chyby; pilulka to na pár sekúnd oznámi. Vypnúť sa dá v Nastavenia → Diktovanie.
- Dvojité stlačenie skratky pri zastavení už omylom nespustí nové diktovanie (počas 1 s po zastavení sa skratka ignoruje).
- Pilulku diktovania sa dá znova posúvať myšou; klik počas nahrávania ju už neskryje (diktovanie zrušíš ⌘⇧X).
- Diktovanie sa vloží aj do appiek ako Claude, Slack či Arc, kde sa text predtým občas nevložil a skončil v pamäti.
- Keď diktovanie zastavíš a hneď spustíš nové, predchádzajúci text sa vloží, ak si stále v tej istej appke (predtým išiel do pamäte ⌃⌥V).
- Neskorý prepis (pomalý server) sa už nevloží do inej appky, do ktorej si sa medzitým prepol — ostane v pamäti.
- Nové diktovanie po hláške „model nevrátil žiadny text“ sa už zobrazí správne, pilulka nezmizne.
- Hlášky v pilulke už nezmiznú predčasne.
- Upozornenie „API je nedostupné“ sa už neukazuje naslepo: pri bežnom diktovaní len keď nie si pripojený k internetu, pri realtime len keď server naozaj neodpovie do 7 s.
- Dvojklik na čakajúcu nahrávku ju neprepíše dvakrát.
- Ovládanie čítania: ⏯ (alebo ťuknutie na AirPods) pozastaví/pustí, ⏮ číta od začiatku; ⌘⇧R počas čítania bez nového výberu textu pozastaví/pustí.
- Smart diktovanie (⌘⇧A) formátuje podľa appky: e-mail dostane oslovenie, odseky, pozdrav a tučne zvýraznené dôležité veci, chat zostane krátky, poznámky majú odrážky. Hlasom stačí povedať „toto zvýrazni“ alebo „dôležité:“. Do Mailu, Gmailu či Notes sa vloží už naformátovaný text.
- Podpis v e-mailoch: v Nastaveniach → Smart ukončenie si nastavíš vlastný podpis, ktorý Smart pridá na koniec e-mailu.
- Smart v AI chatoch (ChatGPT, Claude…) nadiktovaný prompt len učeše — predtým ho niekedy rovno „splnil“ (napísal celý článok namiesto zadania).
- Smart tón „Uhladiť“ spoľahlivejšie vyhodí výplňové slová (teda, vlastne, nejakých…); v e-maile je poďakovanie s rozlúčkou v jednom riadku a text pod oslovením začína malým písmenom.
- Čítanie má nastavenie hlasitosti (Nastavenia → Čítanie), pri hlase Google sa mení hneď počas čítania.
- Smart formátuje spoľahlivejšie: zachová „približne“ pri sumách a termínoch, aj zdvorilé „prosím“; keď sa v reči opravíš („v utorok, nie, v stredu“), ostane len oprava; „S pozdravom“ a meno sú pod sebou; otázka pre AI ostane otázkou; funguje „vymaž poslednú vetu“; menej zbytočného tučného v poznámkach.
- Smart má predvolený model gpt-4.1 — v teste na 28 diktovaniach jediný bez chýb vo formátovaní (lacnejšie modely písali malé písmená, zdvojené odrážky a nechávali pokyny v texte).
- Keď server OpenAI na chvíľu zlyhá, Smart to automaticky skúsi ešte raz.
- Prehľad ukazuje, koľko ticha sa z nahrávok vystrihlo a koľko sa tým ušetrilo na prepise.
- Kontrola pred vložením (Smart): voliteľne sa výsledok najprv ukáže v okne, kde ho upravíš, vložíš (⌘↩), vložíš pôvodný prepis alebo zrušíš. V nastaveniach si zvolíš nikdy / len v AI chatoch / vždy a či chceš vidieť, čo AI zmenila, a pôvodný text.
- Smart v AI appkách (ChatGPT, Claude, Cursor…) upraví nadiktovaný prompt podľa typu modelu — iné pravidlá pre textový chat, premýšľajúci model, obrázky, video a programovacieho agenta. Stačí povedať napr. „promptujem pre image model“.
- Hlasové pokyny v Smart („toto zvýrazni“, „daj to tučne“, „nový odsek“, „odrážka“, „začni tučné … koniec tučného“) sa spoľahlivo vykonajú a samotný pokyn už nezostane v texte.
- Okno kontroly pred vložením má nový vzhľad podľa dizajnu Ozveny.
- Smart má nastavenie Tón: zachovať môj štýl / uhladiť bez výplňových slov (predvolené) / formálne a vecne.
