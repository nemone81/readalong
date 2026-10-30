# Collaudo su dispositivo

Checklist da eseguire sull'iPhone (checkpoint B) con una build di sviluppo.
Ogni sezione dice da quale task viene; si spunta a mano e si annotano i difetti
sotto la voce, con data.

## T9: background, Now Playing e comandi remoti

**Preparazione.** Build di sviluppo installata, un libro con copertina e almeno
3 capitoli (il Cigno nero va bene; Pinocchio ha 2 capitoli), AirPods
accoppiate, batteria sopra il 50%, modalità Non disturbare spenta (serve la
telefonata). Avviare la lettura a metà del capitolo 2.

### Schermo bloccato
- [ ] Play, poi blocco schermo col tasto laterale: l'audio continua.
- [ ] Lasciare bloccato **1 ora** (in tasca o sul tavolo): l'audio non si
      interrompe; allo sblocco la frase evidenziata è quella che si sente.
- [ ] Lock screen: copertina del libro, titolo = nome del capitolo,
      sottotitolo con autore e titolo del libro.
- [ ] La barra di avanzamento sul lock screen corrisponde al tempo del capitolo
      (durata giusta, posizione che avanza da sola).
- [ ] Pausa dal lock screen: si ferma subito; la barra si ferma.
- [ ] Play dal lock screen: riparte dal punto giusto.
- [ ] -15 s e +15 s dal lock screen: salto di 15 secondi; la barra salta con
      l'audio (non resta indietro).
- [ ] Trascinare la barra sul lock screen (scrub): l'audio va lì.
- [ ] Con velocità diversa da 1× (quando c'è T10): la barra avanza alla
      velocità giusta, senza scatti allo sblocco.

### Control Center
- [ ] Il riquadro audio mostra copertina, capitolo e libro.
- [ ] Play/pausa, ±15 s funzionano anche da qui.

### Cambio capitolo
- [ ] A fine capitolo il lock screen passa da solo al titolo e alla durata del
      capitolo successivo.
- [ ] "Successivo" (doppio tocco sul gambo delle AirPods o comando dal volante
      in auto): va all'inizio del capitolo dopo.
- [ ] "Precedente" (triplo tocco sul gambo o volante) dopo i primi 3 secondi:
      torna all'inizio del capitolo in corso; ripetuto subito: va al capitolo
      prima.

### AirPods
- [ ] Tocco/pressione singola sul gambo: play/pausa.
- [ ] Togliere un AirPod dall'orecchio (rilevamento automatico attivo): pausa;
      rimetterlo: riprende (lo gestisce il sistema).
- [ ] **Sfilare/scollegare le AirPods** (rimetterle nella custodia, chiudere):
      l'audio va in **pausa** e NON passa all'altoparlante.
- [ ] Con cuffie a filo/adattatore (se disponibili): staccare il jack mette in
      pausa.

### Interruzioni
- [ ] **Telefonata in arrivo** durante l'ascolto: l'audio si ferma allo
      squillo. Rifiutare: l'audio riprende da solo dal punto in cui si era
      fermato.
- [ ] Telefonata accettata e chiusa dopo qualche secondo: l'audio riprende
      (se iOS lo consiglia) o resta in pausa, ma non riparte mai a chiamata in
      corso.
- [ ] Telefonata arrivata mentre era **in pausa**: a fine chiamata resta in
      pausa.
- [ ] Siri o una sveglia durante l'ascolto: pausa, poi ripresa.
- [ ] Un'altra app che suona (video, musica): ReadAlong si ferma; non riprende
      da solo finché non si preme play.

### In auto (CarPlay o Bluetooth)
- [ ] Titolo e capitolo sul display dell'auto.
- [ ] Comandi dal volante: play/pausa, traccia successiva/precedente =
      capitolo successivo/precedente.
- [ ] Spegnere l'auto (Bluetooth che si scollega): pausa, niente audio
      dall'altoparlante del telefono.

### Note
- Sul simulatore non si possono provare: blocco schermo reale, AirPods,
  cuffie sfilate, telefonate, comandi dal volante, durata di 1 ora.
