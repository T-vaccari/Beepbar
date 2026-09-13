## Performance ed energia

1. Usare una build Release arm64 e un corpus sintetico locale: mai dati WeBeep reali.
2. Misurare prima di ottimizzare: avvio, apertura finestra, sync, database, filesystem e progresso tramite Points of Interest.
3. Misurare l'idle con sessioni di 30 minuti: controllo automatico disattivato e attivo senza scadenze. Un polling continuo non misura l'idle.
4. Registrare CPU media, wakeup/minuto, RSS, rete e durata; confrontare mediana e p95 dopo cinque run calde.
5. Confrontare con WeBeep Sync solo a parità di macchina, alimentazione, corpus e intervallo configurato.
6. Ottimizzare solo hotspot dimostrati e conservare sempre three-way sync, cancellazione e atomicità.
