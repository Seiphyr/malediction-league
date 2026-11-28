# Prove da fare a mano

Aggiornata il 24 novembre 2026.

## Come usare questa lista

Qui dentro c'è **solo quello che un test automatico non può dimostrare**. Tutto il resto è
già coperto: 2868 verifiche su 35 suite, più 23 controlli dentro la migrazione e 28
asserzioni di comportamento sul database. Rifare a mano quelle è tempo buttato.

Quattro cose, e sono queste, che la macchina non sa fare:

1. **Due persone diverse.** Ogni suite gira con account finti dentro una pagina sola. Un
   invito è per definizione una cosa fra due persone, quindi ogni riga marcata **[2 ACCOUNT]**
   è provabile solo da te con un secondo account vero (un indirizzo mail diverso, o un amico).
2. **Una fotocamera vera.** Un QR l'ho verificato leggendolo a livello di matrice e con un
   decodificatore software. Che si legga con un telefono a mezzo metro, in penombra, su uno
   schermo con le impronte sopra, lo dice solo un telefono.
3. **I dati veri.** Le suite usano eventi finti. Il Play Network vero ha titoli lunghi,
   accenti, orari strani, eventi senza partecipanti.
4. **Le cose irreversibili.** Non tocco in produzione niente che un'altra persona possa
   vedere, né niente che non si possa annullare. Tutte le righe marcate **[SOLO TU]**.

Legenda: ☐ da fare · **[2 ACCOUNT]** serve un secondo account · **[SOLO TU]** non lo faccio io ·
**[TELEFONO]** serve un dispositivo vero.

---

## 1. Inviti a un evento

Il caso per cui esiste tutta la funzione: un torneo Clash di una community **privata**, e
una persona che si è iscritta sul Play Network ma non riesce a trovare la pagina.

☐ Apri un tuo torneo Clash, tab **Invite**. Deve esserci la lista (vuota) e il campo per
coniare. **Non** deve esserci nessun QR e nessun codice pubblico.
→ *se vedi un QR qui, è un bug: quel codice non fa entrare nessuno in un Clash.*

☐ Conia un invito scrivendo un nome nel campo. Il codice compare nella lista con il nome
accanto e lo stato **Unused**.
→ *il nome non è un vezzo: senza, la lista sono sei codici indistinguibili e «Ritira» non si
può usare con criterio.*

☐ Conia un secondo invito **senza** scrivere niente. Deve funzionare: il nome è facoltativo.

☐ **[2 ACCOUNT]** Manda il link del primo invito all'altro account. Toccandolo deve finire
**direttamente sulla pagina dell'evento**, senza nessuna finestra di conferma, con un
messaggio che dice che l'evento è aperto per lui.
→ *nessuna conferma è voluto: ha già toccato il link, quel tocco è l'accettazione.*

☐ **[2 ACCOUNT]** Controlla la lista giocatori del torneo: l'altro account **non deve
esserci**. Un invito a un Clash apre la porta, non dà la sedia — il campo di gara resta
quello del Play Network.

☐ **[2 ACCOUNT]** Dal tuo lato, il tab Invite ora deve dire **Used** con il nome di chi l'ha
usato.

☐ **[2 ACCOUNT]** Dai lo **stesso** link a un terzo account (o riprova dal primo dopo averlo
usato con un altro): deve dire che è già stato usato, e suggerire di chiederne un altro.

☐ **[2 ACCOUNT]** L'altro account riapre il **proprio** link: deve rifunzionare. Un invito si
consuma per gli altri, non per chi l'ha usato.

☐ **[SOLO TU]** **[2 ACCOUNT]** Ritira l'invito già usato. Il messaggio deve dirti
esplicitamente che **il giocatore resta nella lista** (se era un Demo con posto). Poi l'altro
account riapre il link: deve dire che è stato ritirato, non che l'evento è scomparso.
→ *questa è la frase che non deve sbagliare: senza, credi di aver tolto una persona dal torneo.*

☐ Apri un evento **chiuso** e uno **segnalato/rimosso**: il tab Invite **non deve esistere**.
→ *il database rifiuta di coniare per quelli, quindi la pagina non deve promettere.*

## 2. Inviti a una community

☐ Vai su una tua community › **Manage**. Sotto il pannello del codice pubblico deve essercene
un secondo, **One-use invites**.

☐ Conia un invito. La riga deve mostrare una **scadenza** (30 giorni). Un invito a un evento
non ne ha, uno a una community sì.

☐ **[2 ACCOUNT]** Manda il link. La finestra deve **dire il nome della community** — anche se
è privata.
→ *prima diceva «Una community privata.» e nient'altro: la pagina non ha modo di leggere una
community privata, solo il database ce l'ha.*

☐ **[2 ACCOUNT]** Accetta: deve diventare membro. Controlla la lista membri.

☐ **[2 ACCOUNT]** Riusa lo stesso codice da un altro account: rifiutato.

☐ **[SOLO TU]** Ritira un invito già usato: il messaggio deve dire che **resta membro**.
Ritirare chiude il codice, non caccia nessuno.

## 3. I codici e le due strade

Da oggi un codice non ha più bisogno di sapere cos'è. Queste provano che è vero.

☐ Prendi il codice di un **evento** e scrivilo nella casella del codice delle community
(Communities, o «Da dove iniziare»). Deve rispondere **sull'evento** — non «nessuna community
con quel codice».
→ *prima era un vicolo cieco, ed era l'unica casella del sito dove si potesse scrivere un
codice a mano.*

☐ Prendi il codice di un **invito a una community** e mettilo nel link di un **evento**
(`#/ev/CODICE` a mano nella barra indirizzi). Deve aprire la finestra della community col suo
nome.

☐ Prendi un codice di invito **ritirato** e mettilo sul link della community (`#/join/CODICE`).
Deve dire che è stato ritirato — **non** aprire «Entrare in questa community?».
→ *questo è il buco che il test nuovo ha trovato a lavoro già fatto.*

☐ Scrivi sei caratteri inventati. Deve dire che non c'è niente con quel codice, senza
raccontare altro.

☐ Il codice stampato di un Demo pubblico deve funzionare **esattamente come prima**: chiede
conferma e ti mette in lista. Questa è la promessa che non si doveva rompere.

## 4. Il giro dell'accesso

Il pezzo più fragile, perché passa per la posta e per una seconda scheda del browser.

☐ **[2 ACCOUNT]** Esci dall'account. Tocca un link d'invito a un **evento**. La pagina di
iscrizione deve dire che entrerai **nell'evento**. Iscriviti e torna: devi finire sull'evento.

☐ **[2 ACCOUNT]** Lo stesso con un invito a una **community**: la pagina di iscrizione deve
dire **community**, non evento.
→ *prima lo indovinava dall'indirizzo del link, non dal codice: un invito a una community
inoltrato sul link di un evento prometteva la cosa sbagliata.*

☐ **[2 ACCOUNT]** Lo stesso ma completando l'iscrizione dalla **mail di conferma**, che apre
una scheda nuova. Quella scheda non ha visto il link: deve comunque portarti sulla strada
giusta, e deve **chiedere** prima di farti entrare.

☐ Tocca un link d'invito **già ritirato** mentre sei disconnesso: deve rifiutare **prima** di
farti creare un account per niente.

☐ **[TELEFONO]** Tutto il giro di sopra da telefono, dove la mail apre il browser di sistema e
non quello in cui hai iniziato.

## 5. Il QR e il telefono

☐ **[TELEFONO]** Apri il tab Invite di un Demo e **inquadra il QR** con la fotocamera di un
telefono. A ~30 cm e a ~1 m.

☐ **[TELEFONO]** Lo stesso con lo schermo a luminosità bassa, e con il telefono inclinato.

☐ **[TELEFONO]** Stampa la pagina (il bottone Print) e inquadra il QR **sulla carta**.
→ *la carta è il caso vero: un QR su un volantino al tavolo.*

☐ **[TELEFONO]** Guarda il tab Invite a larghezza telefono: il QR non deve uscire dal
riquadro né spingere via il codice.

## 6. I codici che nascono nel database

☐ Crea una community nuova. Deve nascere con un codice valido. (Ora il codice lo fa il
database, non il browser.)

☐ Su una community › Manage, premi **Generate new code**. Il codice che ti viene mostrato
deve essere **quello che funziona davvero**: copialo, esci, e provalo da un altro account.
→ *il motivo di tutto questo: prima il browser generava il codice e te lo mostrava, e il
database poteva rifiutarlo — ti avrebbe fatto stampare un codice morto.*

☐ Passa una community da pubblica a **privata**. Il database le cambia il codice da solo:
verifica che la pagina ti mostri **quello nuovo**, non il vecchio.

## 7. Con i dati veri del Play Network

☐ Importa un evento con un titolo **lungo** e con accenti: controlla che non sfondi la riga
nel tab Invite, nella lista eventi e nella finestra di conferma.

☐ Un evento **senza iscritti**: la finestra di conferma deve dire che non c'è nessuno in
lista, non «0 giocatori».

☐ Un evento che inizia **oggi** e uno che è **già passato**.

## 7b. L'invitato vede la pagina per intero

☐ **[2 ACCOUNT]** Con un invito a un torneo Clash, l'altro account apre la pagina: oltre alla
scheda deve vedere anche **la lista dei mazzi**.
→ *prima del 14 dicembre la pagina si apriva e poi quel pannello rispondeva «torneo non
trovato» — l'unica cosa che l'invito era stato fatto per fargli guardare.*

☐ **[2 ACCOUNT]** Un terzo account **senza invito** apre lo stesso indirizzo: non deve vedere
né la pagina né i mazzi.

☐ **[SOLO TU]** **[2 ACCOUNT]** Ritira l'invito e fai ricaricare: deve tornare a non vedere
nulla. La vista si chiude nello stesso istante in cui si chiude il codice.

## 8. Dopo ogni pubblicazione

Due passi, e servono entrambi — l'ho imparato sbagliando.

☐ L'impronta del file servito dal sito deve combaciare con quella del repo:

```powershell
cd "C:\Users\arche\.claude\SEEKERSLEAGUE"; $w = git hash-object index.html; $l = (curl.exe -sL "https://seekers-league.com/?fresh=$(Get-Date -UFormat %s)" | git hash-object --stdin); "repo $w"; "live $l"; if ($w -eq $l) { "COMBACIA" } else { "ANCORA VECCHIO" }
```

☐ Poi **forza il browser oltre la sua copia**: apri `seekers-league.com/?fresh=` più un
numero qualsiasi. Senza questo guardi la tua cache e credi che non sia cambiato niente.
→ *deve essere una domanda (`?fresh=`), non un pezzo di indirizzo, o il link del QR si
allunga.*

## 9. Le cose che non faccio io in produzione

Per memoria, così sai cosa resta in mano tua: **ritirare** un invito, **rimuovere** o
**segnalare** un evento, **scartare** un torneo, **cambiare** una community in privata,
**mandare** qualsiasi cosa che un'altra persona veda, e qualunque passaggio che chieda una
password, un codice usa-e-getta o un pagamento.

## 10. Da aggiornare

☐ Il filtro anti-spam sulla pubblicazione: verifica che un account appena creato non riesca a
pubblicare un evento a tutti, e che il messaggio dica cosa manca.

☐ `BETA-CHECKLIST.md` è fermo a novembre: va riallineato o unito a questo file.

☐ **Backup**: `index.src.html` e i file `.sql` **non sono in git**. Esistono solo nella
cartella del progetto, senza copia. Sono il sorgente commentato e tutta la storia del
database.
