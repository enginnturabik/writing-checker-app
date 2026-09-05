# Writing Checker

A mobile app that marks writing in any language and explains every correction
the way a teacher would — in the learner's own native language.

A Turkish speaker learning French writes *"Le marché etait tres grande"*, and
gets back **"était très grand"** with the reason written in Turkish, plus a note
that this particular mistake is one Turkish speakers tend to make in French.

> **Status: work in progress.** The marking pipeline, credit system, accounts
> and purchase flow are built and tested end to end. Store publishing is not
> done — see [What is left](#what-is-left).

---

## Why it is built this way

The interesting problem here is not "call an LLM". It is everything around it:
an API key that cannot ship inside an app, a balance that has to survive a
reinstall, and a payment that must never be taken without being credited.

### The API key never reaches the phone

```
Flutter app  ──►  Node server  ──►  Anthropic API
(device token)    (holds the key)
```

Anyone can pull a key out of a Play Store APK and spend the balance behind it.
So the app authenticates with a device token and never sees a key; the server
holds it, decides what each check costs, and makes every model call.

### Credits are an append-only ledger

Nothing ever updates a balance. Every change is a row, and `SUM(delta)` is the
balance — so a wrong number can always be traced to the entry that caused it.

Credits are **reserved before** the model call, not after: a client that
disconnects mid-stream has still cost real money. If marking genuinely fails,
the reservation is refunded, and the refund is keyed by check id so it can only
happen once.

Every grant is idempotent through a unique index on `(user_id, kind, ref)`, so a
replayed purchase token collides in the database rather than relying on a check
somebody might forget to write.

### A payment is completed only after it is credited

```
store receipt → server verifies with Google/Apple → ledger → THEN completePurchase
```

If the server is unreachable at that moment the receipt is deliberately left
uncompleted, so the store replays it on the next launch. Completing first would
consume the receipt and the user would have paid for nothing. There is a test
locking this in.

The client is never trusted for the credit amount — it sends a product id and a
receipt, and the server looks up what that product is worth in its own
catalogue.

### Credits survive a reinstall without letting trials be farmed

Signing in with Google or Apple binds the balance to an identity. On a reinstall
the new anonymous account is merged into the real one: **purchased** credits are
carried across, the fresh trial is left behind, and the retired account keeps a
`merged_into` pointer so the same device lands back home if it re-registers.
Twelve tests cover this, including the case of reinstalling repeatedly to try to
mint new trials.

---

## What it does

- Type, paste, import (`.txt` / `.docx` / `.pdf`) or **photograph handwriting**
- Marks in any language, detected from the writing when not specified
- Every correction carries a category, a severity and an explanation written in
  the learner's native language
- Calls out **first-language interference** — the mistakes speakers of *your*
  language specifically make in the one you are learning
- Scores, a CEFR estimate, and a history of past checks kept on the device

Three levels of marking, priced by what they actually cost to run:

| Tier | Credits | Model |
|---|---|---|
| Quick check | 1 | Haiku 4.5 |
| Advanced check | 3 | Sonnet 5 |
| Full report | 6 | Opus 5 |

Credits are bought in packs ($1 / $3 / $5) as consumable in-app purchases. Three
free checks on first install.

---

## Stack

**App** — Flutter, `provider` for state, `in_app_purchase`, `google_sign_in`,
`sign_in_with_apple`, secure storage for anything sensitive.

**Server** — Node 22+ / TypeScript, Hono, SQLite via Node's built-in driver (no
native module to compile anywhere), `jose` for JWTs, Zod for request validation.

**Model** — Anthropic Messages API with streaming, structured JSON output
(`output_config.format`) and prompt caching on the system prompt.

---

## Layout

```
lib/                    Flutter app
  models/               Requests, results, account, history
  services/             Backend client, purchases, sign-in, prompt builder
  state/                AppState — single source of truth
  ui/screens/           Editor, result, history, credits, settings
server/src/
  catalog.ts            Tiers, packs and model pricing — the business model
  credits.ts            The append-only ledger
  identities.ts         Sign-in and the account merge
  limits.ts             Word caps, attachment size, rate limits
  marking/              Prompt construction and the Anthropic call
  purchases/            Google Play and App Store verification
  routes/               HTTP surface
```

---

## Running it

The server holds the key, so it starts first.

```bash
cd server && npm install && cp .env.example .env
```

Put an Anthropic key and a random `AUTH_SECRET` in `server/.env`, then:

```bash
npm run dev
```

```bash
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8787
```

`10.0.2.2` is how the Android emulator reaches the host. On Windows there is a
`Start Writing Checker.bat` that starts both halves and opens the app.

## Tests

```bash
cd server && npm test
```

```bash
flutter test
```

112 tests, concentrated on the parts where a bug costs money or loses a user's
balance: the ledger, purchase replay across devices, the account merge, and the
pre-flight rejections that happen before a single token is bought.

---

## What is left

- Store products created in Play Console and App Store Connect
- `PURCHASE_VERIFICATION=live` and `AUTH_VERIFICATION=live` with real store and
  OAuth credentials (both default to `mock`, which accepts anything, so the
  client flow could be built first)
- Server deployed — `Dockerfile` and `fly.toml` are written and ready
- Privacy policy, account deletion, and the third-party-AI disclosure both
  stores require

## Notes

`.env` is gitignored and no key is in this repository; `server/.env.example`
documents what is needed. The server logs a warning on every boot while
verification is in `mock` mode, because shipping that way would let anyone mint
credits.
