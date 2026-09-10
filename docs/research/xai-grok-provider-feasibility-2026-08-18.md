# xAI / Grok jako vendor w Codex Limits

Data researchu i dostępu do źródeł: **2026-08-18**  
Zakres: aktualny kontrakt repozytorium, xAI Inference API, Management API, SuperGrok oraz Grok Build CLI  
Źródła zewnętrzne: wyłącznie oficjalna dokumentacja xAI i oficjalne repozytorium `xai-org/grok-build`

## Werdykt

„Integracja xAI/Grok” oznacza dziś trzy różne produkty i trzy różne kontrakty:

1. **xAI Inference API** — wywołania modeli przez `https://api.x.ai/v1`; integracja generowania i kosztu pojedynczego requestu jest łatwa.
2. **xAI API billing / Management API** — historia kosztów i tokenów, saldo prepaid oraz miesięczny spend control zespołu; integracja jest umiarkowanie łatwa, ale wymaga osobnego Management Key i nie opisuje limitu subskrypcji Grok.
3. **SuperGrok / Grok Build** — konsumencki pool obejmujący produkty Grok; publiczna dokumentacja REST nie opisuje odczytu jego stanu, ale oficjalny Grok Build udostępnia przez proces CLI własne rozszerzenie ACP `x.ai/billing`, zwracające procent wykorzystania oraz bieżący okres tygodniowy lub miesięczny.

W konsekwencji:

- **łatwe:** użycie Groka do „Assisted Insights”, lista modeli, metryki i dokładny koszt requestów wykonanych przez Codex Limits;
- **średnie:** monitoring płatnego xAI API przez Management API, pasywna lista lokalnych sesji Grok Build oraz eksperymentalny odczyt subscription usage przez CLI ACP;
- **trudne:** dokładna, odporna na zmiany normalizacja lokalnych tokenów Grok Build;
- **bez publicznego, stabilnego kontraktu:** odpowiednik głównego paska „weekly usage remaining” dla SuperGrok/Grok Build. Oficjalna implementacja istnieje, lecz jest wewnętrznym, niewersjonowanym rozszerzeniem CLI, a nie udokumentowanym REST API.

Minimalna wiarygodna wersja vendora xAI powinna więc pokazywać **lokalną aktywność Grok Build**, opcjonalnie **koszty xAI API** oraz — po udanym capability probe — **subscription usage odczytane przez `grok agent stdio`**. Gdy metoda lub oczekiwane pola są niedostępne, tygodniowy limit musi pozostać jawnie niedostępny. Nie należy nazywać samej podmiany modelu w Assisted Insights „pełnym wsparciem xAI”.

## 1. Obecny kontrakt i flow Codex Limits

Repozytorium nie ma jeszcze ogólnego kontraktu vendora. Ma natomiast trzy wyraźne warstwy, które można rozdzielić na etapie kompozycji aplikacji.

### 1.1. Konto i główny limit

[`CodexClient.swift`](../../Sources/CodexLimits/CodexClient.swift) uruchamia lokalne `codex app-server --stdio`, inicjalizuje JSON-RPC i przy każdym odczycie pobiera równolegle:

- `account/rateLimits/read`;
- `account/usage/read`;
- `account/read`.

Klient uzgadnia odczyt ponownie, jeżeli w trakcie pojawi się `account/rateLimits/updated` albo `account/updated`. Następnie mapuje wynik do wspólnego w aplikacji `CodexFetchResult`/`UsageSnapshot`:

- główny limit: okno dokładnie `10080` minut, procent pozostały i data resetu;
- pozostałe okna i limity modelowe;
- dzienne buckety tokenów i summary konta;
- credits, spend control i banked resets;
- tożsamość konta i plan.

[`UsageMonitor.swift`](../../Sources/CodexLimits/UsageMonitor.swift) już przyjmuje `fetchUsage` jako closure, więc zamiana źródła konta nie wymaga na początku rozbudowanej hierarchii klas. Problemem jest semantyka: [`MEASUREMENT-CONTRACT.md`](../MEASUREMENT-CONTRACT.md) i silnik produktu traktują tygodniowy limit Codex jako główny, a historia i prognozy są oparte o spadający procent z konkretnym resetem.

**Punkt rozszerzenia:** wstrzykiwany fetch jest dobry. `UsageSnapshot` nie jest jednak neutralnym modelem dla API pay-as-you-go bez tygodniowego allowance.

### 1.2. Lokalne Taski i tokeny

[`LocalActivityCollector.swift`](../../Sources/CodexLimits/LocalActivityCollector.swift) jest obecnie Codex-specific:

- domyślny root to `~/.codex/sessions`;
- znajduje `rollout-*.jsonl` według katalogów kalendarzowych;
- używa `thread/list` i `thread/read` przez [`ThreadProjectionSource.swift`](../../Sources/CodexLimits/ThreadProjectionSource.swift) do read-only projekcji Tasków;
- inkrementalnie tailuje pliki, utrzymuje cursor/fingerprint i odtwarza stan po restarcie;
- [`RolloutTailSource.swift`](../../Sources/CodexLimits/RolloutTailSource.swift) rozumie zdarzenia Codex takie jak `session_meta`, `turn_context`, `token_count` i `compacted`;
- [`LocalActivityNormalizer.swift`](../../Sources/CodexLimits/LocalActivityNormalizer.swift) normalizuje je do tasków, parentów, agentów, tur, modeli, reasoning, tokenów, timingów i narzędzi.

Źródła i wersje schematów są na razie zamkniętymi enumami `codex-rollout-jsonl` oraz `codex-app-server-thread-list`. Normalizowany model faktów jest w znacznej mierze wielovendorowy, ale discovery, wire parser, metadane źródła i copy są Codex-specific.

**Punkt rozszerzenia:** zachować istniejące `LocalActivityFact` i agregatory, dodać osobny adapter Grok Build. Nie rozszerzać parsera rolloutów warunkami `if vendor == ...`.

### 1.3. Assisted Insights

[`CodexAssistedInsights.swift`](../../Sources/CodexLimits/CodexAssistedInsights.swift) korzysta z drugiego, izolowanego procesu Codex App Server:

- `model/list` wybiera dokładnie wspierany profil;
- efemeryczny `thread/start` uruchamia analizę w read-only sandboxie, bez MCP, apps i web search;
- `turn/start` wysyła ograniczony payload i JSON Schema;
- przed i po analizie odczytywany jest tygodniowy limit, aby policzyć narzut na allowance.

**Punkt rozszerzenia:** protokół `CodexAssistedInsightServicing` już izoluje usługę. Dla xAI można użyć natywnego `URLSession` i `POST /v1/responses` bez nowej zależności, ale utraci się Codexowy pomiar ruchu na allowance i gwarancje lokalnego sandboxa app-servera. Należy mierzyć zwrócony przez xAI koszt requestu, nie udawać procentu allowance.

### 1.4. Najmniejsza potrzebna granica vendora

Na początku wystarczy złożyć w jednym miejscu cztery zdolności:

- identyfikator/nazwa vendora;
- opcjonalny fetch faktów konta;
- opcjonalny kolektor lokalnych faktów;
- opcjonalna usługa Assisted Insights.

Każda zdolność musi móc być „unavailable” z nazwanym powodem. Wspólny protokół zakładający, że każdy vendor ma tygodniowe okno, daily token buckets, thread RPC i lokalny JSONL byłby błędny.

## 2. xAI Inference API

### 2.1. Endpoint i auth

Oficjalny REST base to `https://api.x.ai`; przykłady OpenAI SDK używają `https://api.x.ai/v1`. Każdy request ma `Authorization: Bearer <XAI_API_KEY>`. API key jest związany z teamem i ma ACL osobno dla endpointów i modeli. Zwykły klucz inference nie jest Management Key. Źródła: [Inference REST API overview](https://docs.x.ai/developers/rest-api-reference/inference), [Quickstart](https://docs.x.ai/developers/quickstart), [Accounts and Authorization](https://docs.x.ai/developers/rest-api-reference/management/auth).

Przydatne read-only endpointy inference:

- `GET /v1/api-key` — metadane aktywnego klucza, team/user ID, ACL i flagi blokady;
- `GET /v1/models` i `GET /v1/models/{id}` — lista modeli, kontekst i ceny;
- `GET /v1/language-models` — bogatsze capabilities, aliases, modalities, fingerprint i ceny;
- `POST /v1/responses` — rekomendowany interfejs generowania;
- `POST /v1/chat/completions` — interfejs zgodności, obecnie oznaczony jako deprecated przez xAI.

Źródła: [Other inference endpoints](https://docs.x.ai/developers/rest-api-reference/inference/other), [Models API](https://docs.x.ai/developers/rest-api-reference/inference/models), [Responses vs Chat Completions](https://docs.x.ai/developers/model-capabilities/text/comparison).

### 2.2. Zgodność z OpenAI API

xAI deklaruje pełną zgodność REST z OpenAI API, publikuje przykłady dla OpenAI Python/JS SDK i akceptuje typowe formaty Chat Completions oraz Responses. To upraszcza transport, streaming i structured output. Nie oznacza to jednak zgodności z Codex App Server — xAI REST nie ma odpowiedników `account/rateLimits/read`, `thread/list` ani Codex rolloutów.

Praktyczne granice zgodności:

- Responses API jest kierunkiem rozwoju; Chat Completions jest legacy/deprecated;
- Chat Completions nie zwraca reasoning content i obsługuje tylko client-side function calling, podczas gdy Responses ma agentic tools i stateful conversations;
- wcześniejsza zgodność Anthropic Messages jest oficjalnie całkowicie deprecated;
- niektóre parametry OpenAI są model-dependent; przykładowo `logprobs` i `top_logprobs` są ignorowane przez Grok 4.20+;
- stateful Responses domyślnie przechowuje odpowiedzi po stronie xAI.

Źródła: [Responses vs Chat Completions](https://docs.x.ai/developers/model-capabilities/text/comparison), [Legacy and deprecated endpoints](https://docs.x.ai/developers/rest-api-reference/inference/legacy), [Models](https://docs.x.ai/developers/models).

### 2.3. Modele i discovery

Na dzień researchu katalog rekomenduje **`grok-4.6` dla code i chat**. Ma 500k context, configurable reasoning i ceny dla krótkiego kontekstu $2/1M input, $0.50/1M cached input i $6/1M output; po przekroczeniu progu 200k cały request przechodzi na ceny long-context $4/$1/$12. Nadal widoczne są m.in. `grok-build-0.1`, `grok-4.5`, `grok-4.3` i modele 4.20. Źródła: [Models](https://docs.x.ai/developers/models), [Pricing](https://docs.x.ai/developers/pricing).

Nie należy hardkodować modelu jako trwałego kontraktu. `GET /v1/models` zwraca tylko modele dostępne dla danego klucza wraz z bieżącym context length i cenami; aliasy mogą przesuwać się na nową wersję, a dated IDs służą do powtarzalności. Minimalna integracja powinna wybierać wspierany model dynamicznie i przechowywać efektywny model ID zwrócony w odpowiedzi.

### 2.4. Streaming

Modele tekstowe wspierają SSE po ustawieniu `stream: true`; obrazowe modele output nie wspierają tego trybu. Dla Responses pojawiają się typowane eventy, a dla Chat Completions delty. Reasoning może wymagać dłuższego timeoutu. Źródło: [Streaming](https://docs.x.ai/developers/model-capabilities/text/streaming).

Dla Codex Limits streaming nie jest potrzebny w pierwszej wersji Assisted Insights, ponieważ obecny UI oczekuje końcowego, ustrukturyzowanego wyniku. Jeżeli zostanie dodany, parser SSE powinien być osobnym, małym elementem transportu i zawsze obsłużyć zakończenie bez usage.

### 2.5. Token usage i dokładny koszt

Odpowiedzi Chat Completions zwracają:

- `prompt_tokens`, `completion_tokens`, `total_tokens`;
- `prompt_tokens_details.cached_tokens`;
- `completion_tokens_details.reasoning_tokens`.

Responses zwraca odpowiednio `input_tokens`, `output_tokens`, `total_tokens`, cached i reasoning details. xAI dodaje `cost_in_usd_ticks`; `1 USD = 10_000_000_000 ticks`. Jest to faktyczny koszt danego requestu po cache discounts i z kosztami server-side tools. Pole jest per-request, nie cumulative. Źródła: [Usage and prompt-cache pricing](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/usage-and-pricing), [Cost Tracking](https://docs.x.ai/developers/cost-tracking), [Chat REST reference](https://docs.x.ai/developers/rest-api-reference/inference/chat).

W streamie:

- xAI SDK podaje rosnący koszt w chunkach i finalnym response;
- OpenAI SDK/raw REST wymaga `stream_options: {"include_usage": true}`;
- końcowy chunk z pustym `choices` zawiera usage i finalny koszt.

To jest bardzo dobry kontrakt dla kosztu Assisted Insights wykonywanego przez aplikację. Nie jest to historia całego konta i nie daje procentu pozostałego tygodniowego poolu.

### 2.6. Structured outputs

xAI wspiera `json_schema` i gwarantuje zgodność dla wspieranego podzbioru JSON Schema. Działa to także z Responses API. Obecne schematy wyników Codex Assisted Insights można więc wykorzystać bez budowania parsera tekstu. Źródło: [Structured Outputs](https://docs.x.ai/developers/model-capabilities/text/structured-outputs).

### 2.7. Retencja i prywatność

Domyślnie xAI przechowuje API inputs/outputs przez 30 dni do audytu i deklaruje, że nie trenuje na nich bez jawnej zgody. Responses jest domyślnie stateful; `store: false` wyłącza server-side conversation state, a Zero Data Retention jest ustawieniem całego teamu i wyłącza m.in. stateful Responses, Files, Collections, Batch oraz deferred completions. Każda odpowiedź ma `x-zero-data-retention: true|false`. Źródła: [API Security FAQ](https://docs.x.ai/developers/faq/security), [Generate Text](https://docs.x.ai/developers/model-capabilities/text/generate-text).

Dla lokalnego produktu wysyłającego metadane zalecane jest `store: false`, brak server-side tools i jawny opis tego, co wychodzi z Maca. ZDR należy raportować na podstawie headera, a nie zgadywać z planu.

## 3. Rate limits

xAI API ma per-team, per-model limity w dwóch wymiarach:

- RPS, wyliczany także z budżetu RPM;
- TPM, do którego wchodzą prompt, completion, reasoning oraz cached prompt tokens.

Limity zależą od tieru opartego o skumulowany spend i mogą być indywidualnie podniesione. Przekroczenie daje `429`; oficjalna rekomendacja to exponential backoff. `grok-4.6` ma obecnie opublikowane dla tierów T0–T4 wartości 150/172/208/312/500 RPS i 50M/53M/60M/74M/100M TPM, ale produkt powinien używać model/team discovery, nie kopiować tej tabeli. Źródło: [Rate Limits](https://docs.x.ai/developers/rate-limits).

Management API pozwala dodatkowo nadać konkretnemu API key ograniczenia `qps`, `qpm` i `tpm`, a team model listing zwraca konfiguracje modeli/rate limits. Źródła: [Management API guide](https://docs.x.ai/developers/management-api-guide), [Management auth reference](https://docs.x.ai/developers/rest-api-reference/management/auth).

**Ważna luka:** w przeglądanych oficjalnych materiałach xAI nie dokumentuje kontraktu response headers typu „remaining requests/tokens/reset” ani publicznego endpointu bieżącego licznika rate-limit. Dokumentuje caps, status `429`, console i backoff. Nie należy implementować paska pozostałego RPS/TPM na podstawie nieudokumentowanych headerów. Rate limit jest też przepustowością, a nie allowance analogicznym do tygodniowego Codex.

## 4. Management API: historia API, saldo i spend control

Management API ma osobny base `https://management-api.x.ai` i wymaga osobnego **Management Key**. Klucz powstaje w xAI Console → Settings → Management Keys; użytkownik musi mieć odpowiednie uprawnienia. Zwykły `XAI_API_KEY` nie wystarczy. Źródła: [Management REST overview](https://docs.x.ai/developers/rest-api-reference/management), [Management API guide](https://docs.x.ai/developers/management-api-guide).

Najważniejsze read-only endpointy billing:

- `POST /v1/billing/teams/{team_id}/usage` — historia API dla przedziału, granularity, wartości, group-by i filtrów; odpowiedź ma `timeSeries` oraz `limitReached`;
- `GET /v1/billing/teams/{team_id}/prepaid/balance` — bieżące saldo prepaid i zmiany;
- `GET /v1/billing/teams/{team_id}/postpaid/spending-limits` — miękki/efektywny miesięczny limit;
- `GET /v1/billing/teams/{team_id}/postpaid/invoice/preview` — bieżące koszty i cykl billingowy;
- `GET /v1/billing/teams/{team_id}/invoices` — faktury.

Usage query może agregować np. `usd` dziennie i grupować po opisie/modelu; Console Usage Explorer potrafi także pokazać cost, tokens, billing items oraz grupy/filtry po API key, modelu, IP, clusterze i typie tokenu. Źródła: [Billing Management API](https://docs.x.ai/developers/rest-api-reference/management/billing), [Usage Explorer](https://docs.x.ai/console/usage), [Manage Billing](https://docs.x.ai/console/billing).

### Dopasowanie do Codex Limits

To źródło może zasilić:

- dzienne tokeny lub USD dla xAI API;
- saldo prepaid;
- miesięczny spend limit i wykorzystanie;
- breakdown po modelu/API key.

Nie może uczciwie zasilić obecnego głównego `UsageWindow`, jeśli użytkownik nie ma prawdziwego procentowego limitu z czasem resetu. Saldo prepaid nie jest procentem tygodniowego allowance, a miesięczny soft limit nie obejmuje prepaid i może być zmieniany. Należy pokazać je jako osobne Account Facts/graphs, nie przepuszczać przez Codexowy forecast „will it last until weekly reset”.

### Koszt wdrożeniowy i ryzyko

Sam HTTP/JSON jest prosty. Trudniejsze są:

- onboarding drugiego sekretu o szerszych uprawnieniach;
- bezpieczne przechowywanie w macOS Keychain;
- wybór teamu i rozdzielenie historii przy zmianie teamu;
- paginacja/cardinality (`limitReached`) i waluty/jednostki;
- fakt, że część użytkowników nie ma dostępu do Management Keys.

Minimalny tryb powinien być całkowicie opcjonalny i read-only. Nie potrzebujemy endpointów tworzenia kluczy, top-up ani zmiany spending limitów.

## 5. SuperGrok i Grok Build to nie to samo co billing xAI API

Oficjalny consumer FAQ mówi, że płatne plany SuperGrok mają jeden procentowy tygodniowy pool, współdzielony przez produkty Grok; Settings → Usage pokazuje procent użyty, breakdown m.in. API/Build/Chat/Imagine/Voice, reset oraz Extra Usage Credits. Różne akcje zużywają różną ilość compute. Źródła: [Grok overview](https://docs.x.ai/grok/overview), [Grok Website / Apps FAQ](https://docs.x.ai/grok/faq).

Jednocześnie oficjalna dokumentacja developerska opisuje xAI API jako teamowy produkt rozliczany przez prepaid credits albo monthly invoicing. Źródło: [Manage Billing](https://docs.x.ai/console/billing).

Grok Build może działać w dwóch trybach auth:

- browser/device OIDC przez Grok/`cli-chat-proxy.grok.com` z odświeżalną sesją;
- `XAI_API_KEY` i bezpośredni `api.x.ai` dla scripts/CI.

Kolejność poświadczeń jest per-model: `model.api_key` → `model.env_key` → aktywny session token → `XAI_API_KEY`. Źródła: [Grok Build overview](https://docs.x.ai/build/overview), [Enterprise Deployments / Authentication](https://docs.x.ai/build/enterprise).

**Wniosek:** produkt musi zapamiętać rodzaj auth/źródło billingu. Nie wolno zakładać, że:

- saldo prepaid xAI API jest tygodniowym limitem SuperGrok;
- zwykły API key daje dostęp do konsumenckiego poolu;
- lokalna sesja Grok Build zawsze obciąża ten sam ledger;
- „API” pokazane w konsumenckim breakdown oznacza wszystkie requesty wszystkich teamowych API keys.

Publiczna dokumentacja nadal **nie opisuje REST endpointu** do odczytu procentu weekly pool/resetu ani komendy `grok usage`. Jest jednak ważna oficjalna powierzchnia implementacyjna: Grok Build w commitcie `d71f6e0` definiuje custom ACP `x.ai/billing`. Handler wymaga auth zarządzanego przez Grok Build i sam wywołuje backend billingowy przez CLI proxy; pager Grok Build korzysta z tej metody zarówno przy starcie, jak i podczas odświeżania usage.

Odpowiedź preferuje nowy shape:

- `config.creditUsagePercent` — wykorzystanie w zakresie `0...100`;
- `config.currentPeriod.type` — m.in. `USAGE_PERIOD_TYPE_WEEKLY` lub `USAGE_PERIOD_TYPE_MONTHLY`;
- `config.currentPeriod.start` / `end` — granice okresu i reset;
- opcjonalnie `prepaidBalance`, `onDemandCap`, `onDemandUsed`, `isUnifiedBillingUser` oraz `subscriptionTier`.

Oficjalny pager clampuje procent do `0...100`, bierze reset z `currentPeriod.end`, a po typie okresu wybiera etykietę „Weekly limit” lub „Monthly limit”. Zachowuje też fallback do oznaczonych jako deprecated pól `monthlyLimit`, `used` i `billingPeriodEnd`. To silny dowód, że kontrakt działa w bieżącym produkcie, ale jednocześnie sygnał ewolucji shape'u.

Źródła: [`billing.rs`, commit `d71f6e0`](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-shell/src/extensions/billing.rs), [wywołanie ACP w pagerze](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/app/effects/mod.rs), [mapowanie billing → `CreditBalance`](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/app/effects/helpers.rs), [etykiety weekly/monthly](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/views/credit_bar.rs).

### Ocena stabilności `x.ai/billing`

To jest **oficjalny, lecz wewnętrzny i niewersjonowany kontrakt**:

- znajduje się w oficjalnym repozytorium i korzysta z niego oficjalny pager, więc nie jest reverse engineeringiem;
- `x.ai/*` jest vendor extension ACP, a metoda i schema nie są opisane w publicznych docs jako kompatybilne API;
- handler ukrywa prywatny proxy/backend, który może zmieniać się razem z CLI;
- schema ma równolegle nowe i deprecated pola, więc integracja musi tolerować migracje;
- dostęp zależy od wariantu auth i subskrypcji; dla trybu tylko `XAI_API_KEY` nie wolno zakładać konsumenckiego subscription poolu;
- obecny typ odpowiedzi ignoruje obecne w backendowym przykładzie `productUsage`, więc nie należy obiecywać breakdownu per produkt.

Wniosek wdrożeniowy: wolno wywoływać `x.ai/billing` **przez oficjalny proces `grok agent stdio`**, z wersją CLI zapisaną w provenance, bounded timeoutem, walidacją pól i fallbackiem `unavailable`. Nie wolno odtwarzać ukrytego requestu HTTP z kodu handlera, wywoływać `cli-chat-proxy` bezpośrednio ani wyciągać tokena z `~/.grok/auth.json`.

## 6. Grok Build: lokalne Taski, tokeny i ACP

### 6.1. Oficjalne powierzchnie

Grok Build jest oficjalnym coding agentem z TUI, trybem headless oraz Agent Client Protocol. `grok agent stdio` uruchamia ACP po JSON-RPC; dokumentowany flow obejmuje auth, `session/new`, `session/prompt` i `session/update`. Źródła: [Grok Build overview](https://docs.x.ai/build/overview), [Headless & Scripting](https://docs.x.ai/build/cli/headless-scripting).

CLI zapisuje sesje pod `~/.grok/sessions/<encoded-cwd>/<session-id>/` (albo pod `$GROK_HOME`):

- `summary.json` — title, timestamps, model, message count i parent session;
- `updates.jsonl` — autorytatywny stream ACP do restore;
- `chat_history.jsonl` — raw messages do modelu;
- `plan.json`, `rewind_points.jsonl`, `signals.json` i katalog `subagents/`.

Źródło: oficjalny [Grok Build sessions guide, commit `d71f6e0`](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md).

`signals.json` zawiera m.in. liczbę tur i tool calls, model IDs, bieżące wykorzystanie context window, compactions i latencje. Oficjalne źródło pokazuje jednak, że część per-turn token fields jest transportowa albo zapisywana inną ścieżką, więc nie wolno zakładać, że jeden cumulative counter z `signals.json` odpowiada Codex `total_token_usage`. Źródło: [`signals.rs`, commit `d71f6e0`](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-shell/src/session/signals.rs).

Grok Build ma także opt-in external OpenTelemetry. Schema `v1` w statusie alpha udostępnia:

- metric `grok_code.token.usage` z typami `input`, `output`, `reasoning`, `cache_read` i modelem;
- event `grok_code.api_request` z duration i tymi czterema licznikami;
- session/turn/tool/error events.

Stream jest off by default, wymaga podwójnego opt-in i wskazania własnego OTLP collectora. Źródło: oficjalny [Monitoring Usage guide, commit `d71f6e0`](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/docs/user-guide/24-monitoring-usage.md).

### 6.2. Billing przez custom ACP

`grok agent stdio` daje aplikacji transport JSON-RPC, na którym można wysłać pusty `ExtRequest` do `x.ai/billing`. Oficjalny pager robi to także na poziomie aplikacji, bez konieczności tworzenia lub wznawiania sesji zadaniowej. To lepsza granica niż czytanie auth file albo kopiowanie wewnętrznego HTTP: CLI pozostaje właścicielem logowania, odświeżania tokena i komunikacji z backendem.

Adapter powinien parsować minimalny, preferowany podzbiór (`creditUsagePercent`, `currentPeriod.type/start/end`) i traktować pozostałe pola jako opcjonalne. Należy osobno obsłużyć: brak binarki, niezalogowanie, brak subskrypcji/config, `method_not_found`, timeout, parse error oraz nieznany typ okresu. Pole procentowe oznacza **used**, podczas gdy obecny Codex snapshot przechowuje głównie **remaining**; konwersja to `100 - used`, po clampie i z zachowaniem surowej wartości/provenance.

Ta funkcja jest wdrażalna teraz, ale powinna otrzymać etykietę compatibility/experimental, testy fixtures przypięte do wersji CLI i telemetrykę błędów schematu bez zapisywania sekretów.

### 6.3. Co jest łatwe

Pasywny collector może bez uruchamiania/resumowania sesji:

- znaleźć katalogi sesji;
- odczytać allowlistę z `summary.json` (session ID, parent, cwd-derived project label, timestamps, model);
- wykryć subagent tree;
- odczytać niesensytywne liczniki z `signals.json`;
- zachować provider/source version i nie kopiować raw messages.

To wystarczy na listę lokalnych Tasków, modele, liczbę tur/tool calls, context usage i częściowe timing/agent facts.

### 6.4. Co jest trudne

Pełne lokalne Usage Receipts są trudniejsze niż sam discovery:

- układ sesji jest dokumentowany, ale nie jest osobnym stabilnym analytics API;
- `updates.jsonl` jest streamem odtwarzania UI i może zawierać prompty, odpowiedzi, tool args, paths i outputs;
- `chat_history.jsonl` jest Source Content i nie powinien być skanowany w tle;
- `signals.json` nie daje prostego, kompletnego cumulative input/output/cached/reasoning kontraktu odpowiadającego obecnemu Codex parserowi;
- external OTEL ma najlepszy jawny token schema, ale jest alpha i wymaga konfiguracji użytkownika oraz odbiornika OTLP;
- nowy proces ACP nie jest udokumentowany jako globalny read-only feed cudzych aktywnych sesji; ACP służy do tworzenia/ładowania i prowadzenia sesji.

Najbezpieczniejszy plan to najpierw pasywnie odczytać tylko `summary.json`/`signals.json`, oznaczyć Coverage zgodnie z faktycznymi polami, a dokładne token receipts odłożyć do osobnego spike'u opartego na syntetycznych fixtures aktualnej wersji CLI. Dla enterprise można później dodać jawnie włączany OTEL zamiast śledzić prywatne detale wszystkich JSONL.

## 7. Macierz dopasowania do funkcji Codex Limits

| Funkcja produktu | Oficjalne źródło xAI/Grok | Dopasowanie | Trudność |
|---|---|---|---|
| Assisted Insights | `POST /v1/responses`, JSON Schema, per-request cost | Bardzo dobre | Łatwe |
| Lista modeli/capabilities/cen | `GET /v1/models`, `/v1/language-models` | Bardzo dobre | Łatwe |
| Streaming odpowiedzi | SSE | Dobre, lecz niepotrzebne w MVP | Łatwe |
| Koszt analiz wykonanych przez aplikację | `usage.cost_in_usd_ticks` | Dokładny | Łatwe |
| Historia tokenów/USD całego xAI API teamu | Management billing usage | Dobre | Średnie |
| Prepaid balance | Management prepaid balance | Dokładne Account Fact | Średnie |
| Miesięczny spend control | Management spending limits/invoice preview | Dobre, ale nie weekly allowance | Średnie |
| Statyczne rate-limit caps | Console/Management team models | Dobre | Średnie |
| Bieżące remaining RPS/TPM/reset | Brak dokumentowanego licznika/header contract | Niedostępne | Trudne/blocked |
| SuperGrok/Grok Build weekly lub monthly % i reset | Custom ACP `x.ai/billing` w oficjalnym CLI | Dobre przy zgodnej wersji CLI i auth; brak stabilnego publicznego API | Średnie/ryzykowne |
| Lokalne sesje Grok Build | `~/.grok/sessions`, summary/signals | Dobre dla metadanych | Średnie |
| Dokładne lokalne token receipts | External OTEL alpha lub wersjonowany parser plików | Częściowe | Trudne |
| Globalny live Task feed | Brak udokumentowanego odpowiednika Codex app-server projections/events | Brak | Trudne |

## 8. Proponowany minimalny wariant

### Etap 1 — Grok Build Local (najmniejszy sensowny vendor)

1. Wykryj oficjalny `grok` i `$GROK_HOME`/`~/.grok`.
2. Uruchom krótkotrwały `grok agent stdio` i wykonaj capability probe `x.ai/billing`; nie twórz ani nie wznawiaj Taska.
3. Gdy odpowiedź zawiera poprawne `creditUsagePercent` i `currentPeriod`, pokaż used/remaining, typ okresu i reset jako dane compatibility-gated. W przeciwnym razie pokaż named `unavailable`.
4. Dodaj osobny, pasywny collector `summary.json` + allowlista z `signals.json`.
5. Mapuj tylko fakty faktycznie obecne: session/parent/subagent, project label, timestamps, model, turns/tools, context usage.
6. Oznacz token totals jako unavailable, dopóki osobny spike nie potwierdzi kontraktu.
7. Partycjonuj historię przez `provider + lokalna tożsamość źródła`; nie czytaj ani nie kopiuj `auth.json`.

To dostarcza realnej wartości lokalnej bez sekretów, prywatnych endpointów i nowego runtime.

### Etap 2 — xAI API Billing (opt-in)

1. Użytkownik jawnie dodaje Management Key do macOS Keychain i wybiera team.
2. Czytaj wyłącznie `usage`, `prepaid/balance`, `spending-limits` i ewentualnie invoice preview.
3. Pokazuj dzienne USD/tokens, saldo i miesięczny limit jako osobne fakty.
4. Nie twórz paska weekly forecast z tych danych.

Nie implementować zarządzania kluczami, top-upów ani zmian limitów — Codex Limits ma read-only boundary.

### Etap 3 — Grok jako Assisted Insights (opcjonalny i niezależny)

1. Użyj `URLSession`, `POST /v1/responses`, dynamicznego model discovery i istniejącego JSON Schema.
2. `store: false`, bez tools i z bounded payloadem.
3. Zapisz input/output/cached/reasoning tokens, model i `cost_in_usd_ticks` dla tej analizy.
4. Pokaż użytkownikowi, że koszt obciąża xAI API, chyba że xAI zwróci oficjalną, jednoznaczną informację o innym ledgerze.

### Etap 4 — stabilizacja subscription usage

Wersję opartą o `x.ai/billing` utrzymywać jako compatibility-gated: probe przy starcie, jawne provenance z wersją CLI, fixtures dla nowego i legacy shape'u oraz bezpieczny fallback. Awansować ją do stabilnego kontraktu dopiero, gdy xAI udokumentuje endpoint/metodę i zasady kompatybilności albo opublikuje wersjonowaną maszynową komendę usage. Zawsze zachować osobny `provider` i `limitId`.

## 9. Czego nie robić

- Nie traktować OpenAI compatibility jako zgodności z Codex App Server.
- Nie skrobać `grok.com` ani nie wywoływać prywatnego `cli-chat-proxy` bezpośrednio; używać wyłącznie CLI-owned `x.ai/billing`.
- Nie wyciągać bearer tokena z `~/.grok/auth.json` i nie kopiować go do stanu aplikacji.
- Nie przeliczać tokenów na procent SuperGrok: consumer allowance jest compute-weighted per product.
- Nie traktować RPS/TPM jako allowance remaining.
- Nie scalać prepaid balance, monthly postpaid limit i SuperGrok weekly pool w jeden wykres.
- Nie skanować `chat_history.jsonl`/pełnych `updates.jsonl` w tle tylko po to, żeby zbudować listę Tasków.
- Nie hardkodować `grok-4.6` ani tabeli cen/rate limits bez model discovery.

## 10. Szacunek relatywny

| Zakres | Rozmiar | Główne ryzyko |
|---|---:|---|
| xAI Responses dla Assisted Insights | S | sekret, retencja, error mapping |
| Model discovery + per-request usage/cost | S | zmiany katalogu, final stream chunk |
| Grok Build summary/signals collector | M | schema/version/Coverage |
| Management API usage/balance/spend | M | Management Key, team identity, Keychain |
| Dokładne local token receipts z plików | L | niepełna/stabilna semantyka tokenów |
| OTEL collector w desktop app | L | setup, OTLP/protobuf, alpha schema |
| Grok subscription allowance przez `x.ai/billing` | M | oficjalna implementacja, ale wewnętrzny/niewersjonowany schema i zależność od CLI auth |
| Bezpośrednie odtworzenie prywatnego billing HTTP | Nie wdrażać | niestabilny backend i ryzykowny auth contract |

## 11. Decyzja rekomendowana

Włączyć xAI do szerszego projektu multi-vendor w dwóch jawnych wariantach:

- **Grok Build (local):** lokalne sesje i Coverage;
- **xAI API (team billing):** usage, koszty, saldo i spend control.

Nie udawać, że którykolwiek z nich jest bezwarunkowym odpowiednikiem obecnego Codex subscription monitor. Najpierw wdrożyć Grok Build local metadata oraz bounded probe `x.ai/billing`; oba używają oficjalnego CLI, nie wymagają kopiowania sekretów i wykorzystują istniejący model faktów. Management API dodać jako opt-in. Pasek subscription usage można pokazać eksperymentalnie po poprawnej odpowiedzi ACP, ale przy każdym braku metody/auth/schematu ma przechodzić w `unavailable`, a nie zgadywać. Publicznego, wersjonowanego REST API nadal brak.
