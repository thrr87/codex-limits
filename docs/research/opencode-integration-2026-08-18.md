# OpenCode w Codex Limits: źródło telemetrii, nie jeden vendor

Data researchu i dostępu do źródeł: **2026-08-18**.\
Zakres wersji: oficjalne docs OpenCode dostępne tego dnia oraz oficjalny release [`v1.18.18`](https://github.com/anomalyco/opencode/releases/tag/v1.18.18) z 2026-08-13.\
Źródła zewnętrzne w tym dokumencie są wyłącznie pierwotne: dokumentacja i repozytorium OpenCode.

> Aktualizacja runtime 2026-08-22: opis poniżej pozostaje przyszłym kontraktem domenowym, ale rekomendowany collector `opencode serve --pure` został odrzucony po pomiarze około 736 MiB RSS, około 66 MiB zapisów inicjalizacyjnych i stałego portu 4096 mimo żądania portu 0. OpenCode jest odroczony poza v1 do czasu pojawienia się wspieranego, znacznie lżejszego źródła. Zobacz [wyniki walidacji](multi-integration-v1-validation-spikes-2026-08-22.md).

## Wniosek

**OpenCode powinien wejść do produktu jako lokalne źródło telemetrii/agregator, a nie jako provider równoległy do Anthropic, xAI czy OpenAI.**

OpenCode jest open-source'owym agentem programistycznym z TUI, aplikacją desktopową i rozszerzeniem IDE. Sam obsługuje ponad 75 providerów i modele lokalne. Jedna sesja OpenCode może używać kolejno różnych par `providerID/modelID`; oficjalny schemat zapisuje je przy odpowiedziach asystenta. To czyni OpenCode dobrym źródłem lokalnych faktów o pracy wykonanej przez OpenCode, ale nie autorytatywnym źródłem stanu kont każdego providera ([Intro](https://opencode.ai/docs/), [Providers](https://opencode.ai/docs/providers/), [schemat wiadomości `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/message.ts)).

Najmniejszy sensowny produktowy zakres to:

1. wykryć user-managed `opencode`;
2. uruchomić chroniony, lokalny `opencode serve` jako proces potomny;
3. czytać tylko `GET /global/health`, `GET /project` i `GET /session`;
4. pokazać OpenCode jako osobną sekcję **Local Activity**, z sumą tokenów, szacowanym kosztem, liczbą sesji, projektami i drzewami parent/child;
5. nie pokazywać „Usage remaining”, runway ani resetu, jeżeli źródło nie zwróciło prawdziwego okna limitu.

Nie należy w pierwszej wersji czytać `auth.json`, parsować SQLite ani pobierać treści wiadomości.

## 1. Obecny kontrakt repozytorium

Repozytorium nie ma dziś abstrakcji `Vendor` ani provider-neutralnego konta.

- [`CodexClient.swift`](../../Sources/CodexLimits/CodexClient.swift) wykrywa wyłącznie Homebrew-managed `codex` w `/opt/homebrew/bin/codex` lub `/usr/local/bin/codex`, uruchamia `codex app-server --stdio`, inicjalizuje JSONL RPC i odpytuje równolegle `account/rateLimits/read`, `account/usage/read` oraz `account/read`.
- Wynik ma postać `CodexFetchResult`, zawierającą jeden [`UsageSnapshot`](../../Sources/CodexLimits/UsageModels.swift), obserwację konta i plan.
- `UsageSnapshot` zakłada Codex-owy model produktu: `mainLimit`, `otherLimits`, historia tokenów, banked resets i Account facts.
- [`UsageMonitor.swift`](../../Sources/CodexLimits/UsageMonitor.swift) przyjmuje jedno `fetchUsage`, jeden `accountSnapshot` i jedną partycję konta. Główna analityka jest zbudowana wokół tygodniowego okna `10_080` minut.
- Lokalne fakty mają obecnie źródła tylko `codex-rollout-jsonl` i `codex-app-server-thread-list` w [`LocalActivityNormalizer.swift`](../../Sources/CodexLimits/LocalActivityNormalizer.swift).
- [`MEASUREMENT-CONTRACT.md`](../MEASUREMENT-CONTRACT.md) świadomie oddziela Account facts, Local facts i Derived estimates oraz zabrania zastępowania brakującego okna tygodniowego innym limitem bez nazwania go.

Konsekwencja: podpięcie OpenCode pod `UsageSnapshot.mainLimit` byłoby błędem domenowym. OpenCode nie dostarcza uniwersalnego odpowiednika `account/rateLimits/read`. Najmniejszym punktem rozszerzenia jest lokalna warstwa aktywności, nie obecny klient konta Codex.

## 2. Czym dokładnie jest OpenCode

| Rola | Czy OpenCode ją pełni? | Znaczenie dla integracji |
|---|---:|---|
| Agent/klient codingowy | Tak | To podstawowa rola produktu. |
| Orchestrator wielu providerów | Tak | Provider i model są wymiarami telemetrii sesji OpenCode. |
| Provider modeli | Tylko w szczególnych ofertach `opencode`/Zen i `opencode-go` | Nie należy utożsamiać całego OpenCode z tymi ofertami. |
| Lokalny serwer/API | Tak | `opencode serve` publikuje HTTP + OpenAPI 3.1. |
| SDK | Tak | Oficjalny JS/TS SDK jest generowany z OpenAPI; nie jest potrzebny aplikacji Swift. |
| Daemon systemowy | Nie jako wymagany kontrakt | TUI uruchamia własny serwer, a osobne `opencode serve` tworzy nowy serwer. |
| Źródło lokalnej telemetrii | Tak | Sesje zapisują tokeny, koszt, model/provider, projekt i relacje parent/child. |
| Uniwersalne API limitów providerów | Nie | Brak jednego endpointu quota/rate limits dla wszystkich podłączonych providerów. |

Oficjalna architektura mówi wprost, że TUI jest klientem serwera, `opencode serve` uruchamia headless HTTP server, `/doc` publikuje OpenAPI 3.1, a osobny `serve` nie dołącza się automatycznie do serwera TUI ([Server](https://opencode.ai/docs/server/)).

## 3. Dostępne powierzchnie integracji

### 3.1 HTTP server — najlepszy kontrakt produkcyjny

`opencode serve --hostname 127.0.0.1 --port 0` uruchamia serwer na porcie przydzielonym przez system i wypisuje jego URL. Release `v1.18.18` ładuje kontekst projektu per request, więc serwer nie musi startować w konkretnym repo ([implementacja `serve`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/cli/cmd/serve.ts)).

Istotne endpointy read-only:

| Endpoint | Co daje | Ograniczenie |
|---|---|---|
| `GET /global/health` | `healthy`, wersja CLI | Dobry capability/version probe. |
| `GET /project` | lista znanych projektów/worktrees | Potrzebna do iteracji po projektach. |
| `GET /session` | sesje projektu, opcjonalnie child sessions | Domyślny limit implementacji to 100; API ma `start` i `limit`, ale brak wygodnego kursora wstecz. |
| `GET /session/:id/children` | bezpośrednie dzieci sesji | Pozwala odtworzyć drzewa agentów. |
| `GET /session/:id/message` | wiadomości i parts | Zawiera potrzebne metadane, ale także prywatną treść; nie używać w minimum. |
| `GET /provider` | wszystkie/default/connected providers i modele | Katalog dostępności, nie stan kwoty konta. |
| `GET /event` | SSE bieżącej instancji | Live events dla jednego kontekstu. |
| `GET /global/event` | SSE z polem `directory` i globalnymi zdarzeniami | Dobre później do live updates i wielu projektów. |

Publiczna dokumentacja endpointów: [Server APIs](https://opencode.ai/docs/server/). Aktualny kod listowania sesji ma pola `scope`, `path`, `roots`, `start`, `search`, `limit` i routing workspace/directory ([Session API `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts), [implementacja listy](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/session.ts)).

Serwer wspiera HTTP Basic Auth przez `OPENCODE_SERVER_PASSWORD`; username domyślnie to `opencode` i może być zmieniony przez `OPENCODE_SERVER_USERNAME` ([Server authentication](https://opencode.ai/docs/server/#authentication)). Proces potomny Codex Limits powinien zawsze ustawić losowe hasło, nasłuchiwać tylko na `127.0.0.1` i nie dodawać CORS.

### 3.2 SSE — dobry etap drugi

`GET /event` wysyła najpierw `server.connected`, a potem zdarzenia busa. Oficjalny SDK eksponuje ten sam strumień jako `event.subscribe()` ([Server events](https://opencode.ai/docs/server/#events), [SDK events](https://opencode.ai/docs/sdk/#events)).

Przydatne eventy obejmują m.in. `session.created`, `session.updated`, `session.status`, `session.error`, `message.updated` i `message.part.updated`. SSE umożliwia mały koszt odświeżania, ale wymaga reconnectu, deduplikacji, bootstrapu po utracie połączenia i wersjonowania schematu. Polling read-only wystarcza w pierwszym wydaniu.

### 3.3 `opencode run --format json` — dobre do sterowania, złe do pasywnego monitoringu

CLI emituje NDJSON z `type`, `timestamp`, `sessionID` oraz eventami `step_start`, `step_finish`, `tool_use`, `text`, `reasoning` i `error`. `step_finish` zawiera tokeny i koszt ([CLI run](https://opencode.ai/docs/cli/#run), [emiter JSON `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/cli/cmd/run.ts)).

Ten strumień obejmuje jednak sesję uruchomioną lub wznowioną przez dane wywołanie `run`. Użycie go jako telemetry source zmuszałoby Codex Limits do przejęcia uruchamiania zadań, co przeczy obecnej read-only granicy produktu.

### 3.4 SDK — niepotrzebna zależność dla aplikacji Swift

`@opencode-ai/sdk` może utworzyć client albo uruchomić client+server. Jest generowany z OpenAPI ([SDK](https://opencode.ai/docs/sdk/)). Aplikacja jest natywna w Swift, a potrzebne operacje to kilka `GET`-ów i SSE obsługiwane przez `URLSession`; dodanie Node/Bun albo warstwy JS tylko dla SDK nie daje przewagi.

### 3.5 CLI helpers i SQLite — przydatne do spike'a, niewłaściwe jako stabilny kontrakt

- `opencode session list --format json` zwraca tylko `id`, `title`, `updated`, `created`, `projectId` i `directory`; celowo pomija tokeny, koszt, model i parent ([implementacja `session list`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/cli/cmd/session.ts)).
- `opencode stats` pokazuje tokeny i koszty globalnie lub per projekt/model, lecz nie ma JSON output. Jego kod czyta wszystkie sesje z bazy i agreguje dane, po czym renderuje tekst ([CLI docs](https://opencode.ai/docs/cli/#stats), [implementacja `stats`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/cli/cmd/stats.ts)). Parsowanie tekstu byłoby kruche.
- `opencode export` zwraca JSON jednej sesji, ale zawiera transcript/file data; `--sanitize` redaguje treść, lecz nadal jest to ciężki eksport, nie inkrementalna telemetria ([CLI export](https://opencode.ai/docs/cli/#export)).
- `opencode db` potrafi wykonać SQL i zwrócić JSON/TSV ([CLI db](https://opencode.ai/docs/cli/#db)), lecz nazwy tabel/kolumn są wewnętrznym schematem i mogą migrować. Bezpośrednie odczyty `opencode.db` obchodzą API, wiążą aplikację ze storage i komplikują współbieżność.
- `opencode acp` używa nd-JSON po stdio, ale jest protokołem sterowania agentem, a nie historycznym API usage ([CLI ACP](https://opencode.ai/docs/cli/#acp)).

## 4. Co można mierzyć wiarygodnie

### 4.1 Fakty dostępne bez czytania transcriptu

Schemat `Session.Info` w `v1.18.18` zawiera:

- `id`, `projectID`, `workspaceID`, `directory`, opcjonalny `parentID`;
- opcjonalny wybrany `model { id, providerID, variant }` i `agent`;
- opcjonalne skumulowane `cost`;
- opcjonalne skumulowane tokeny: `input`, `output`, `reasoning`, `cache.read`, `cache.write`;
- wersję OpenCode oraz czasy `created`, `updated`, `archived`/`compacting`.

Źródło: [oficjalny schemat sesji `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/session.ts#L224-L245).

Z tych pól da się zbudować read-only:

- listę i liczbę sesji/projektów;
- drzewa parent/child;
- sumę tokenów per sesja i globalnie;
- podział typów tokenów;
- lokalny, skumulowany koszt raportowany przez OpenCode;
- ostatnią aktywność i przybliżony czas życia sesji;
- aktualnie zapisany provider/model/variant/agent sesji.

Wartości powinny mieć provenance `OpenCode local session`, wersję CLI i `observedAt`. Nie są Account facts providera.

### 4.2 Fakty wymagające endpointu wiadomości

Metadane odpowiedzi asystenta zawierają dokładne `providerID`, `modelID`, czasy, `cost` i rozbicie tokenów. Parts mogą zawierać czasy narzędzi oraz `step-finish` z usage ([schemat wiadomości](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/message.ts)). Dzięki temu można policzyć poprawny podział sesji multi-model, turn timing, tool time i usage w czasie.

Problem: `GET /session/:id/message` zwraca jednocześnie prompts, responses i parts. Nawet jeśli dekoder Swift ignoruje te pola, wrażliwa treść przechodzi przez pamięć procesu. Obecny produkt mocno rozróżnia metadane od Source Content, więc ten endpoint powinien wymagać osobnej decyzji privacy i capability spike'a. Minimum powinno zostać przy `Session.Info`.

### 4.3 Czego nie wolno wywnioskować

- `Session.model` nie dowodzi, że cała sesja używała jednego modelu. Dokładne przypisanie jest per odpowiedź.
- Suma OpenCode nie obejmuje wywołań tego samego providera wykonanych przez Claude Code, Codex, SDK, stronę web ani inny komputer.
- Brak sesji OpenCode nie oznacza braku użycia konta providera.
- `updated - created` nie jest Active Time.
- Koszt OpenCode nie jest fakturą ani wydatkiem subscription planu.
- Limit kontekstu modelu z katalogu nie jest limitem konta ani allowance.
- OpenCode session tokens nie są porównywalne z Codex Account Token Activity bez osobnej walidacji definicji.

## 5. Jak OpenCode liczy tokeny i koszt

OpenCode normalizuje usage zwrócone przez provider/AI SDK do:

- input bez cache read/write;
- output bez reasoning;
- reasoning;
- cache read;
- cache write.

Następnie wylicza koszt z cen modelu (w tym progów kontekstowych), a reasoning tymczasowo wycenia jak output. Dla GitHub Copilot potrafi użyć `totalNanoAiu` zamiast zwykłej formuły. Brakujące lub niepoprawne liczby normalizuje do zera ([`getUsage` w `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/session.ts#L338-L411)).

To oznacza:

- tokeny są lokalnym zapisem usage zwróconego przez konkretną ścieżkę providera;
- `cost` jest kalkulacją OpenCode opartą o katalog/model metadata, z wyjątkami provider-specific;
- koszt może nie odpowiadać rzeczywistemu rachunkowi, rabatom, kredytom, abonamentowi, podatkom ani requestom poza OpenCode;
- gdy provider nie zwróci poprawnego usage albo cena jest niepełna, `0` nie musi znaczyć „darmowe”.

W UI właściwa etykieta to **Estimated API cost reported by OpenCode** albo krócej **OpenCode local cost**, z tooltipem wyjaśniającym, że nie jest to bill/allowance.

## 6. Provider i model discovery oraz auth

OpenCode korzysta z AI SDK i Models.dev; `opencode models [provider]` pokazuje modele skonfigurowanych providerów, a `--verbose` dodaje m.in. koszt. `--refresh` odświeża cache Models.dev ([Providers](https://opencode.ai/docs/providers/), [CLI models](https://opencode.ai/docs/cli/#models)).

HTTP `GET /provider` zwraca:

- pełny katalog `all`;
- default models;
- listę `connected` provider IDs.

To pozwala pokazać „OpenCode ma skonfigurowany xAI/Anthropic”, ale nie pozwala stwierdzić, że konto jest sprawne, ma dodatnie saldo albo określoną kwotę.

Poświadczenia wprowadzone przez `/connect` są przechowywane w `~/.local/share/opencode/auth.json`; OpenCode może też wykrywać zmienne środowiskowe ([Providers credentials](https://opencode.ai/docs/providers/#credentials)). Codex Limits **nie powinien czytać ani kopiować tego pliku**. Proces OpenCode może używać swoich credentials wewnętrznie, ale nasz adapter powinien wywoływać wyłącznie lokalne endpointy telemetryczne.

## 7. Limity: generic providers vs OpenCode Go/Zen

### 7.1 Generic OpenCode

W udokumentowanym lokalnym Server API nie ma odpowiednika:

- provider account balance;
- billing usage;
- remaining subscription quota;
- rate-limit windows i reset times dla wszystkich providerów.

OpenCode nie może więc być wspólnym źródłem „remaining” dla Anthropic, xAI, OpenAI, Bedrock itd. Każdy provider ma inny auth, rozliczenia i zasady. Takie integracje muszą być provider-specific albo pokazywać wyłącznie lokalną aktywność.

### 7.2 OpenCode Go

OpenCode Go jest konkretnym providerem/subskrypcją, nie całym OpenCode. Oficjalne docs `v1.18.18` podają trzy limity wartościowe:

- 5 godzin: **$12 usage**;
- tydzień: **$30 usage**;
- miesiąc: **$60 usage**.

Limity i lista modeli mogą się zmieniać, a aktualne usage oficjalnie śledzi się w console ([OpenCode Go](https://opencode.ai/docs/go/)).

Repozytorium zawiera endpoint `GET https://opencode.ai/zen/go/v1/usage`, autoryzowany Bearer API key, zwracający dla `rolling`, `weekly`, `monthly`: `status`, `percent`, `resetsAt` ([implementacja `v1.18.18`](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/console/app/src/routes/zen/go/v1/usage.ts)). Ten endpoint **nie jest wymieniony w publicznej sekcji Go Endpoints**; docs kierują użytkownika do console. Jest technicznie obiecujący, ale dopóki OpenCode go nie udokumentuje jako wspierany kontrakt, integracja produkcyjna byłaby zależna od API wewnętrznego.

Dodatkowo jego użycie wymagałoby dostępu do API key. Czytanie go z `auth.json` łamałoby obecną zasadę „nie kopiujemy credentials”. Rozsądne ścieżki na przyszłość:

1. poprosić OpenCode o udokumentowanie endpointu i stabilnego schema/versioning;
2. poprosić o read-only proxy w lokalnym server API, które zwraca usage bez ujawniania klucza;
3. ewentualnie pozwolić użytkownikowi osobno wkleić Go API key do Keychain — dopiero gdy funkcja jest świadomie zamówiona.

### 7.3 OpenCode Zen

Zen jest pay-as-you-go: docs opisują saldo, auto-reload i miesięczne spending limits ustawiane w console, ale nie dokumentują lokalnego endpointu balance/remaining dla klienta OpenCode ([OpenCode Zen](https://opencode.ai/docs/zen/)). Lokalny koszt sesji nadal nie zastępuje salda Zen.

## 8. Ocena trudności

| Element | Ocena | Dlaczego |
|---|---|---|
| Wykrycie binary i `GET /global/health` | Łatwe | Ten sam wzorzec procesu potomnego co Codex; JSON HTTP. |
| Start prywatnego `serve` na loopback | Łatwe | `--port 0`, losowe Basic Auth, jedna linia z URL. |
| Pobranie projektów i sesji | Łatwe/średnie | API jest proste, ale trzeba iterować po projektach i uwzględnić limit 100. |
| Sumy session tokens/cost | Łatwe od `v1.18.18` | Pola są już w `Session.Info`, lecz opcjonalne i wymagają tolerant decoding. |
| Drzewa parent/child | Łatwe | `parentID` jest w sesji; obecne modele Usage Receipts znają relacje. |
| Provider/model catalog | Łatwe | `GET /provider`; nie mylić z quota. |
| Live updates przez global SSE | Średnie | Reconnect, bootstrap, dedupe i wersje eventów. |
| Historia tokenów per dzień/turn/model | Średnie/trudne | Wymaga messages/parts albo wewnętrznej bazy; endpoint niesie także treść. |
| Active Time/tool time | Trudne | Wymaga parts, definicji idle/wait i walidacji semantyki. |
| Account identity/partycjonowanie | Trudne | Lokalne sesje nie dają stabilnej tożsamości kont każdego providera. |
| Rzeczywisty rachunek providera | Trudne/niemożliwe generic | Local estimated cost nie jest billing ledger. |
| Remaining/reset dla Anthropic/xAI/OpenAI przez OpenCode | Niemożliwe generic | Brak uniwersalnego local server contract. |
| OpenCode Go remaining/reset | Średnie technicznie, wysokie ryzyko kontraktu | Endpoint istnieje w kodzie, ale nie jest publicznie udokumentowany i wymaga API key. |
| Wspólny runway dla Codex + OpenCode | Niewłaściwe | Miesza account allowance Codex z local estimated cost/token activity wielu providerów. |

## 9. Minimalny wariant implementacyjny

### Produkt

Nowa pozycja **OpenCode · Local Activity**, bez allowance:

- Sessions observed;
- Local tokens: input/output/reasoning/cache read/cache write;
- OpenCode local cost;
- Projects i session trees;
- Provider/model tylko jako zaobserwowany wymiar, z `Unknown/mixed` gdy nie da się tego dowieść z samego `Session.Info`;
- source version, observed time, Coverage reason.

Nie dodawać jeszcze OpenCode do menu-barowego procentu, runway, reset reminders, banked resets, Account Token Activity ani `Usage per token` zestawionego z Codex allowance.

### Transport

1. Wykryj user-managed `opencode` w tych samych dwóch prefixach Homebrew co Codex.
2. Uruchom `opencode serve --hostname 127.0.0.1 --port 0 --pure`.
3. Ustaw losowe `OPENCODE_SERVER_USERNAME` i `OPENCODE_SERVER_PASSWORD` tylko w środowisku procesu potomnego.
4. Odczytaj linię `opencode server listening on http://...` i sprawdź `GET /global/health`.
5. Pobierz `GET /project`, a dla każdego worktree `GET /session?scope=project&directory=...&limit=<bounded high value>`.
6. Dekoduj tylko pola sesji; ignoruj title/share/metadata, jeśli nie są potrzebne UI.
7. Przechowuj klucz źródłowy `opencode:<sessionID>` oraz poprzedni cumulative counter, żeby nie dublować kolejnych odczytów.
8. Zakończ child process przy zamknięciu/zmianie executable; przy niezgodnym schema pokaż `OpenCode activity unavailable`, nie zerowy usage.

`--pure` ogranicza wpływ zewnętrznych pluginów na proces telemetryczny. Ceną jest to, że katalog custom-providerów/pluginów może nie odpowiadać interaktywnej instancji użytkownika; minimum nie potrzebuje katalogu do zsumowania już zapisanych sesji.

### Model danych

Najmniejsza zmiana nie wymaga budowy ogólnego frameworka vendorów. Wystarczy osobny read-only `OpenCodeActivitySource`, który produkuje provider-neutralne local facts oraz nowy `LocalActivitySourceKind`, np. `opencode-http-session`.

Jednocześnie OpenCode nie powinien zwracać `UsageSnapshot`. Account allowance i Local Activity muszą pozostać rozdzielone. Jeżeli bezpośrednie adaptery Claude Code i xAI później potwierdzą wspólny, powtarzalny kontrakt, dopiero wtedy warto wydzielić protokoły `AccountUsageSource` i `LocalActivitySource`.

### Jedna mała weryfikacja przed kodem produkcyjnym

Spike powinien na fixture lub świeżej, sztucznej sesji sprawdzić:

1. czy `GET /session` w minimalnie wspieranej wersji zawsze zwraca cumulative `tokens` i `cost`;
2. czy suma parent + child nie jest już zawarta w parent (ryzyko double count);
3. jak zachowują się counters po compaction, fork, archive i usunięciu;
4. czy `--pure` odczytuje tę samą historię bez ładowania zewnętrznych pluginów;
5. czy start serwera nie modyfikuje sesji poza konieczną migracją storage.

Do czasu wyniku Coverage powinno mówić **Local OpenCode sessions observed; provider account usage may differ**.

## 10. Co odłożyć

- **Nie budować generic `Vendor` na podstawie samego OpenCode.** OpenCode i xAI są bytami z innych warstw.
- **Nie parsować `opencode stats`.** Tekst nie jest kontraktem maszynowym.
- **Nie czytać SQLite w produkcji.** HTTP ma już potrzebne agregaty.
- **Nie czytać `auth.json`.** Limity nie uzasadniają obchodzenia granicy credentials.
- **Nie pobierać messages/parts w v1.** Dodać dopiero, gdy użytkownik rzeczywiście potrzebuje per-turn/per-model historii i zaakceptuje przepływ Source Content.
- **Nie implementować SSE w v1.** Dziesięciominutowy polling i manual refresh pasują do obecnego `UsageMonitor`; SSE dodać, gdy opóźnienie faktycznie przeszkadza.
- **Nie nazywać `cost` wydatkiem/billingiem.** Jest to lokalna kalkulacja OpenCode.

## Decyzja rekomendowana

**Tak dla OpenCode jako `Local Activity source`; nie dla OpenCode jako generic account vendor.**

To daje szybko wartościową obsługę sesji OpenCode używających Anthropic, xAI, OpenAI, OpenCode Go i innych modeli, bez udawania, że znamy pozostałe kwoty tych kont. Bezpośrednie integracje Claude Code i xAI powinny nadal odpowiadać za własne, autorytatywne fakty konta — o ile ich oficjalne interfejsy rzeczywiście je udostępniają.
