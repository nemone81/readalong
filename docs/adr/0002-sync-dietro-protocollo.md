# ADR 0002: sincronizzazione su iCloud KVS dietro il protocollo `SyncStore`

**Stato:** accettata, 2026-10-31 (T13). **Decide:** Fabio.

## Contesto

Lo stato di lettura di un libro (`BookState`: posizione, velocità, segnalibri) deve passare tra iPhone e iPad. Per v1 basta iCloud key-value store: gratuito, niente server, niente account oltre all'Apple ID, ed è il canale previsto da spec e PLAN (decisione 4).

Si è parlato di una possibile web app futura. Se arriva, sarà **solo di lettura del testo**, senza audio: deve sapere dove si è arrivati e mostrare i segnalibri, quindi dovrebbe leggere lo stesso stato. iCloud KVS dal web non si legge.

## Decisione

- Il lettore e `ProgressStore` non parlano con iCloud: parlano con un protocollo `SyncStore` (`ios/ReadAlong/Sync/SyncStore.swift`) che non usa tipi Apple. Le operazioni sono quattro: leggi il documento di un libro, scrivilo, elenca gli id, flusso asincrono degli id cambiati da altri dispositivi. Il documento è il JSON di `BookState` (`Data`), opaco per lo store.
- L'implementazione di oggi è `CloudKeyValueStore` (`NSUbiquitousKeyValueStore`), con chiave `book.<id>` (accorciata a 64 byte, il limite di KVS; l'id completo sta nel valore).
- Il merge è fuori dallo store: `StateMerge`, funzione pura e deterministica (vedi SPEC, "Sincronizzazione"), applicata da `ProgressStore`. Uno store HTTP non deve saper fare merge: gli basta leggere e scrivere blob per chiave.
- I test usano `InMemorySyncStore`, che simula più dispositivi su un "cloud" condiviso: niente account iCloud nei test.

## Conseguenze

- Nessun server da gestire, nessun costo. Il prezzo: limiti di iCloud KVS (1 MB in tutto, 1 MB per chiave, 1024 chiavi, propagazione nell'ordine delle decine di secondi, nessuna garanzia di tempo) e la firma con l'entitlement `ubiquity-kvstore-identifier` (oggi bloccata dalla PLA Apple da accettare; simulatore e test non ne risentono).
- **I dati non sono leggibili dal web** finché non si aggiunge un'implementazione HTTP di `SyncStore` e un backend proprio. Quando servirà, il backend dovrà servire, per libro: il documento di stato (lo stesso JSON) e il testo dei capitoli, cioè i JSON delle frasi di `chapters/NN.json` (pochi KB ciascuno). **Mai gli `m4a`**: la web app non ha audio, e i file audio restano sul dispositivo.
- Passare a HTTP vuol dire scrivere una classe nuova e cambiare una riga in `ReadAlongApp`; lettore, libreria, merge e test restano. La migrazione dei dati è gratuita: al primo avvio con lo store nuovo, `ProgressStore.startSync()` riconcilia tutti gli stati locali e li carica.
- Il documento è la sola forma condivisa tra le piattaforme: cambiarne la forma richiede campi nuovi facoltativi con default (regola già usata da T7 in poi), così versioni diverse dell'app (e un eventuale client web) si leggono a vicenda.
