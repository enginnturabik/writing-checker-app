# Writing Checker server

The credit-metered proxy between the app and the Anthropic API. It exists for
one reason: **the API key cannot live in a shipped app.** Anyone can pull a key
out of a Play Store APK and spend your balance.

It also owns the things the client must never decide: how many credits a user
has, what a check costs, and whether a purchase was real.

## What it does

- Holds the Anthropic key and makes every marking call
- Tracks a credit balance per device in an append-only ledger
- Verifies purchases with Google Play and the App Store before crediting
- Enforces word caps, attachment size and per-device rate limits
- Records what every check actually cost, so you can watch your margin

## Running it

```bash
npm install
```

```bash
cp .env.example .env
```

Fill in `ANTHROPIC_API_KEY` and a random `AUTH_SECRET` (`openssl rand -base64 48`), then:

```bash
npm run dev
```

Point the app at it:

```bash
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8787
```

`10.0.2.2` is how the Android emulator reaches your machine. Use your LAN IP for
a physical device, and `http://localhost:8787` for web or desktop.

## API

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/health` | — | Liveness, and which verification mode is active |
| `POST` | `/v1/devices` | — | Register an install id, get a token, catalogue and trial credits |
| `GET` | `/v1/me` | Bearer | Balance and catalogue |
| `POST` | `/v1/purchases` | Bearer | Verify a one-off top-up receipt and credit it |
| `POST` | `/v1/subscriptions` | Bearer | Activate or restore a subscription |
| `POST` | `/v1/webhooks/google` | Secret | Play Real-Time Developer Notifications |
| `POST` | `/v1/webhooks/apple` | Secret | App Store Server Notifications V2 |
| `POST` | `/v1/check` | Bearer | Mark a submission; streams SSE `progress`, then `result` or `error` |

`/v1/check` answers `402` with `code: insufficient_credits` when the balance is
too low, and `429` when a limit is hit — both before a single token is bought.

## How the money stays right

**Credits are an append-only ledger.** Nothing updates a balance; every change
is a row. `SUM(delta)` is the balance, so a wrong number can always be traced to
the entry that caused it.

**Credits are reserved before the API call, not after.** A client that
disconnects mid-stream has still cost you tokens. If marking genuinely fails,
the reservation is refunded — and the refund itself is keyed by check id, so it
can only happen once.

**Every grant is idempotent.** A unique index on `(user_id, kind, ref)` means a
replayed purchase token or a re-registered device collides in the database
rather than relying on a check somebody might forget to write. Restoring
purchases after a reinstall is therefore harmless.

**The client never says how many credits it bought.** It sends a product id and
a receipt; the server looks up the credit amount in its own catalogue.

**Purchase tokens are globally unique.** Sharing a receipt between two devices
credits neither of them twice.

**A subscription grants credits; it never gates a check.** Subscribing puts an
allowance into the same ledger, so `credits.reserve` remains the single place
that decides whether a check may run. Nothing in the checking path knows
subscriptions exist.

**One credit is one US cent of upstream cost.** Credits are fungible across
tiers, so an allowance only caps spending if each tier's credit price tracks
what that tier really costs — which is why a full report is 25 credits against a
quick check's 1. Price a report at 6 and your heaviest users become your least
profitable ones. When the measured cost of a tier moves (the `cost_usd` column
on `checks` is the number to watch), move its credit price with it.

**Allowances are granted per calendar month, not per billing period.** That is
what lets one code path serve both plan shapes: a monthly plan renews as the
bucket turns over, and a yearly plan drips a twelfth of itself each month rather
than handing over a year of credits that could be spent in a week and refunded.
There is no scheduler — the grant is evaluated whenever the user is seen.

**A store notification is a hint, never the change itself.** Both webhooks read
only an identifier from the payload and then ask the store's API what is
actually true. A forged notification therefore grants nothing.

**Paid allowances roll over; the free one does not.** A paid month was paid for
whether or not it was used, so carrying it forward costs nothing. The free
weekly allowance is a *top-up to* 5 rather than an addition *of* 5, so six quiet
weeks cannot accumulate into a free full report.

## Before you take real money

1. **`PURCHASE_VERIFICATION=live`.** The default `mock` accepts any receipt and
   exists so the app-side flow can be built first. It logs a warning on every
   boot and every grant. Shipping with it means anyone can mint credits.
2. **Create the subscriptions in both stores.** Ids must match `PLANS` in
   `src/catalog.ts` exactly, and all three are **auto-renewable subscriptions**
   in one subscription group, so a user can move between them:

   | Product id | Plan | Allowance | Price |
   |---|---|---|---|
   | `sub_writer_monthly` | Writer | 120 credits/month | $3/month |
   | `sub_exam_monthly` | Exam | 250 credits/month | $6/month |
   | `sub_exam_yearly` | Exam, yearly | 250 credits/month | $49/year |

3. **Create the top-up packs.** Ids must match `PRODUCTS`, and all three are
   **consumable** — the same pack has to be buyable again:

   | Product id | Credits | Price |
   |---|---|---|
   | `credits_40` | 40 | $1 |
   | `credits_120` | 120 | $3 |
   | `credits_200` | 200 | $5 |

   The store sets the local price the user actually pays; `priceUsd` is only
   what the app falls back to when the store has not answered yet.

   **Set per-country prices.** $6/month is a coffee in the US and a real
   decision in Turkey, India or Vietnam — which is where these users are. Both
   stores support it, and leaving the US price everywhere costs most of the
   market.

4. **Google Play:** create a service account with Play Developer API access,
   grant it "View financial data" on your app, and set `GOOGLE_*`. Purchases and
   subscriptions are acknowledged automatically — Google auto-refunds anything
   left unacknowledged for three days, so this is not optional.

   Then enable **Real-Time Developer Notifications**: create a Pub/Sub topic,
   point Play at it (Monetisation setup → Real-time developer notifications),
   and add a **push subscription** to
   `https://your-host/v1/webhooks/google` with `x-webhook-secret` set to
   `WEBHOOK_SECRET`. Without this a renewal is only credited when the app next
   opens.

5. **App Store:** create an In-App Purchase key in App Store Connect and set the
   `APPLE_*` values, including `APPLE_ENVIRONMENT=production` for release.

   Then set the **App Store Server Notifications V2** URL to
   `https://your-host/v1/webhooks/apple`. Apple cannot send a custom header, so
   put the secret in the path or in front of a proxy that adds it — the
   handler reads `x-webhook-secret`.

6. **Set `WEBHOOK_SECRET`.** The server refuses to boot in `live` mode without
   it, because silently unauthenticated webhooks are worse than none.
7. **Persist the database.** `DATABASE_PATH` must point at a mounted volume, or
   every balance disappears on the next deploy.
8. **HTTPS only.** The device token is a bearer credential for a balance.
9. **`AUTH_VERIFICATION=live`** with `GOOGLE_OAUTH_CLIENT_IDS` and
   `APPLE_CLIENT_IDS` set. The `mock` default trusts any `mock:<subject>`
   string, so anyone could claim anyone else's account and its credits.

## Deploying

Hosted on **Fly.io**: one machine in Frankfurt with a persistent volume. The
config is in `fly.toml` and `Dockerfile` - no local Docker needed, Fly builds
remotely.

Install the CLI once (PowerShell):

```powershell
iwr https://fly.io/install.ps1 -useb | iex
```

Then, from this directory:

```bash
fly auth signup
```

```bash
fly launch --no-deploy --copy-config --name writing-checker-api --region fra
```

Create the disk that holds every credit balance. **Without this, balances reset
on every deploy:**

```bash
fly volumes create writing_checker_data --region fra --size 1
```

Set the secrets. These never enter the image or the repository:

```bash
fly secrets set ANTHROPIC_API_KEY=sk-ant-... AUTH_SECRET="$(openssl rand -base64 48)"
```

```bash
fly deploy
```

```bash
fly status && curl https://writing-checker-api.fly.dev/health
```

Point the app at it:

```bash
flutter build appbundle --dart-define=BACKEND_URL=https://writing-checker-api.fly.dev
```

### Why one machine

SQLite is one file on one disk, so Fly will not scale this past a single
machine - which is correct: two machines with two disks would be two different
sets of balances. One shared-cpu-1x handles far more traffic than this app will
see before it is profitable, because every request spends most of its life
waiting on Anthropic rather than on the database. Move to Postgres only when a
single machine genuinely runs out, and treat that as a good problem.

`auto_stop_machines` is off on purpose. A suspended machine makes a paying user
wait on a cold boot, and cannot answer a store purchase callback.

### Backups

The volume is the whole business. Fly snapshots it daily, and:

```bash
fly ssh console -C "sqlite3 /data/app.db .dump" > backup.sql
```

## Tests

```bash
npm test
```

25 tests over the parts where a bug costs money: the ledger (idempotent grants,
reservations, refunds, draining to zero), registration, purchase replay across
devices, and the pre-flight rejections on `/v1/check`.
