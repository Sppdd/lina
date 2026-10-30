# Lina in production

How Lina goes from a developer build (keys in `.env`) to a Mac app that people download, sign up for, and use,
running on **Nebius Token Factory** for writing and pictures, **Gemini with Google Search grounding** for answers,
and **Supabase** for accounts, limits and the server that holds the keys.

> Facts marked *(verify)* came from search results, not from reading the provider's page directly.
> Check them on the linked pages before you rely on them.

> **Status (Phase 1 deployed, 30 Oct 2026):** the `lina` project (`aciwoqsepwuccqkvdwsq`) has the migrations, the
> Nebius and Gemini secrets and the `lina-ai` function, and release builds carry its URL. The app signs people in with
> an emailed code and sends every request through `lina-ai`. Still to do: custom SMTP, since the built-in sender only
> manages a few emails an hour. Section 8 has the deploy steps; deploy with `--use-api` if Docker isn't running.

## The short answer

Yes, Token Factory can carry Lina in production, but **the app must never hold the Nebius or Gemini keys**.
Every model call goes through a small server you own (Supabase Edge Functions). The app only knows the
signed-in user's session. That one change is what makes Lina production-ready: keys stay secret, each user has
a quota, you can change models or providers without shipping an update, and you can switch everything off if
something goes wrong.

```
 Lina.app (Swift)                     Supabase                                  Providers
 ─────────────────                    ────────                                  ─────────
 Sign in with Apple / email  ───────▶ Auth  (issues the user's session)
 session in Keychain
                                      Edge Function  lina-ai                    ┌─▶ Nebius Token Factory
 /lina, checks, images  ── user JWT ─▶  • checks the user and their quota ──────┤     chat · images · models
                         ◀─ stream ──   • picks the allowed model               └─▶ Gemini API
                                        • calls the provider with its secret         google_search grounding
                                        • records usage
                                      Postgres  profiles · plans · usage (RLS on)
 Saved history stays on the Mac
```

## 1. Supabase: how to use it

You'll set the project up; I'll write the code against it. Here's the order.

1. **Create the project** at supabase.com. Pick a region near most of your users (and near Nebius's EU or US
   datacenter if you enable Zero Data Retention there).
2. **Turn on sign-in methods** in Authentication → Providers:
   - **Apple** (best on a Mac: one click, no password). Needs your Apple Developer Team ID, a Services ID and a key;
     Supabase's [Sign in with Apple guide](https://supabase.com/docs/guides/auth/social-login/auth-apple) walks
     through it. The native macOS flow uses `ASAuthorizationController`, and Apple only gives you the user's name
     on the very first sign-in.
   - **Email** with a one-time code (works for everyone, no redirect needed). Magic links also work if we register
     a `lina://` URL scheme.
3. **Install the CLI** and link the project. You'll use it to set secrets and deploy the function:
   `brew install supabase/tap/supabase`, then `supabase login` and `supabase link --project-ref <ref>`.
4. **Set the provider keys as secrets**, from your terminal, never in the app or in chat:
   `supabase secrets set NEBIUS_API_KEY=… GEMINI_API_KEY=…`
5. **Deploy** the `lina-ai` function and the database migrations I'll add under `supabase/` in this repo:
   `supabase db push` and `supabase functions deploy lina-ai`.

**What to send me in the next request**
- The project URL (`https://<ref>.supabase.co`).
- The **publishable (anon) key**. It's safe to ship inside the app; it only works together with the rules we set.
- Which sign-in methods you want (Apple, email code, Google).
- Your Apple Developer **Team ID** and the app's **bundle ID** (today `app.lina.mac`), if you want Sign in with Apple.
- Whether launch is free-only or has a paid plan (if paid: Stripe or Paddle).

**Never send:** the `service_role` key, the database password, or the Nebius and Gemini keys.
Those live only in Supabase secrets.

## 2. The server: one Edge Function, `lina-ai`

One function with a few routes keeps it simple to deploy and audit.

| Route | Does | Provider |
|---|---|---|
| `POST /v1/chat/completions` | Sentence checks (`x-lina-task: check`) and `/lina` question, rewrite, edit; streams back | Nebius, Nemotron Nano / Super |
| `POST /v1/images/generations` | One picture | Nebius, FLUX |
| `GET /v1/models` | The models this server allows, for `/lina model` | (allowlist) |
| `POST /search` | Grounded answer + sources + Google's Search Suggestions | Gemini + `google_search` |
| `GET /usage` | Today's use and the plan's limits, for Settings → Account | Postgres |

The Nebius routes keep the OpenAI shape, so the app's existing client only swaps its base URL and token.

Each request:
1. **Checks the user.** The function asks Supabase Auth who the token belongs to (`/auth/v1/user`) and refuses
   the anon key. The platform's own `verify_jwt` check is off in `supabase/config.toml`, because it doesn't accept
   tokens signed with Supabase's newer JWT signing keys; see
   [Securing Edge Functions](https://supabase.com/docs/guides/functions/auth).
2. **Checks the quota** with one Postgres call (`consume(user, kind, units)`), which records usage and refuses with
   HTTP 429 when the user's plan limit is reached. Rate limiting is up to us; Supabase doesn't do it for you.
3. **Caps the input** (characters per request) and **allows only listed models**, so a modified client can't run
   expensive models.
4. **Calls the provider** with the secret key, streams the answer straight back, and records tokens used.

Limits to design around ([Supabase limits](https://supabase.com/docs/guides/functions/limits), *verify*):
150 s wall clock on Free and 400 s on paid plans, a 150 s idle timeout before the first byte, and 2 s of CPU per request.
Lina's calls take seconds and mostly wait on the network, so they fit, but **always stream** so the first byte is
sent quickly.

**Database** (all with row-level security, users can read only their own rows):
`profiles` (plan, created), `usage` (user, kind, units, model, at), `plans` (daily limits per kind).
Saved history stays on the Mac for now. It's private, and Google's terms limit what we may store from searches
(see section 4).

## 3. Nebius Token Factory in production

**Models and prices** (per 1M tokens, input / output, from the
[Nemotron page](https://nebius.com/services/token-factory/models/nvidia-nemotron-models-inference), *verify*):

| Job | Model | Price |
|---|---|---|
| Sentence checks (many, short) | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` | $0.06 / $0.24 |
| …newer option to evaluate | Nemotron-3.5-Lightning | $0.06 / $0.24 |
| `/lina` question, rewrite, edit | `nvidia/nemotron-3-super-120b-a12b` | $0.30 / $0.90 |
| Pictures | `black-forest-labs/flux-schnell` | per image (check the [model catalog](https://tokenfactory.nebius.com/models)) |

**What a heavy user might cost per month**, assuming 150 sentence checks a day (about 400 tokens in and 80 out each)
and 30 commands a day (about 1,500 in and 200 out):
checks ≈ **$0.20**, commands ≈ **$0.57**. Writing is cheap; pictures and web searches are what to budget for.

**Rate limits.** Limits are per account and change dynamically; you can see yours in the console. Over the limit
returns HTTP 429, and responses carry OpenAI-style headers with what's left
([rate limits](https://docs.tokenfactory.nebius.com/ai-models-inference/rate-limits)). The function retries
429s once with backoff and shows the user "busy, try again" rather than an error. When traffic grows,
ask Nebius to raise your limits, or move the busiest model to a **dedicated endpoint** (billed per GPU-hour).

**Your users' text.** By default Token Factory **keeps inputs and outputs** to speed up inference (speculative
decoding). It doesn't train on them. For a writing app, **turn on Zero Data Retention** in your account profile and
ask Nebius for a DPA ([legal quick guide](https://docs.tokenfactory.nebius.com/legal/legal-quick-guide)).
Their docs note ZDR may affect service level, so test speed after enabling it.

**Reliability.** Timeouts on every call; if Super is slow or down, `/command` falls back to Nano; `/models` is
cached so the picker always opens.

## 4. Gemini grounding in production

**The model.** Lina now defaults to `gemini-3.5-flash-lite` with thinking kept low (it used `gemini-2.5-flash`,
and earlier settings are moved over). On the server it's the `GEMINI_MODEL` secret, so it can change without an
update. Confirm the exact model ID on the [models page](https://ai.google.dev/gemini-api/docs/models) *(verify)*.

**Price and the daily cap** ([pricing](https://ai.google.dev/gemini-api/docs/pricing), *verify*): on Gemini 3 and newer,
5,000 grounded requests a month are free across the project, then **$14 per 1,000**. There's also a **default cap of
1,500 grounded requests a day per project**. That cap is shared by all your users, so it's the first limit you'll hit:
plan a per-user search quota, and ask Google for more, or use Vertex AI's grounding at scale.
At 10 searches a day, one user costs about $4 a month in grounding alone, which makes search the feature to put
behind a paid plan.

**Rules we must follow** ([grounding docs](https://ai.google.dev/gemini-api/docs/google-search),
[Gemini API terms](https://ai.google.dev/gemini-api/terms), *verify the exact wording*):
- **Show Google's Search Suggestions** with every grounded answer, exactly as Google sends them (the
  `searchEntryPoint.renderedContent` HTML), next to the answer, and only to the person who asked. Lina's answer card
  will render that HTML in a small web view; tapping a suggestion opens Google. The source chips we show today aren't
  enough on their own.
- **Don't cache, analyze or train on grounded results.** There are narrow exceptions (such as keeping them as the
  user's own history); confirm them before syncing Saved anywhere. Keeping Saved only on the user's Mac is the safe default.
- **Google keeps grounding prompts for about 30 days**, and Zero Data Retention doesn't apply when grounding is on.
  Say so in Lina's privacy policy and in Settings → Privacy.

## 5. The Mac app

**Distribution.** Ship outside the Mac App Store, as a **Developer ID–signed, notarized** DMG with the hardened
runtime. Lina reads other apps through Accessibility and posts keystrokes, which the App Store sandbox doesn't
allow ([Apple DTS](https://developer.apple.com/forums/thread/707680)). Add **Sparkle** for updates.

**Signing fixes two daily annoyances.** A stable Developer ID signature means macOS stops asking for Accessibility
again after each update, and the user's session can live in the Keychain without prompts. The private secrets file
we use for development keys today won't be needed.

**Code changes** (next request, once Supabase details arrive):
- A `LinaService` protocol with two implementations: `DirectService` (developer keys, debug builds only) and
  `CloudService` (calls `lina-ai` with the user's session, streams responses).
- Sign-in as the onboarding's "keys" step: Sign in with Apple or an email code. Settings → Account shows the plan,
  today's usage and Sign out.
- Model and key fields disappear from release builds; `/lina model` shows only the models your server allows.
- The answer card renders Google's Search Suggestions (section 4).
- Friendly states for 401 (signed out), 402/429 (limit reached, or busy), and offline.

**Before launch:** a privacy policy and terms (what's sent where, Google's 30 days, Nebius ZDR), a support address,
opt-in crash reporting, and a Mac to run CI on. GitHub's macOS runner never started for this repo, so check
Settings → Billing and Actions, or use a self-hosted runner on your Mac.

## 6. Order of work

| Phase | What | Done when |
|---|---|---|
| 1. Accounts and gateway | Supabase project, `lina-ai` with `/check`, `/command`, `/models`, quotas; app signs in and uses it | A new user signs up and gets fixes and commands with no keys on their Mac |
| 2. Search and pictures | `/search` with Search Suggestions shown, current Gemini model, `/image`; per-plan limits | Grounded answers comply with the terms; pictures work through the gateway |
| 3. Ship | Developer ID signing, notarization, Sparkle, privacy policy, Nebius ZDR on | A signed DMG updates itself and never asks for Accessibility twice |
| 4. Grow | Paid plan (Stripe or Paddle → `plans`), raised provider limits or dedicated endpoints, usage dashboard | Search cost is covered by the plan that uses it |

## 7. Open questions for you

Starting limits are in the migration (`plans` table): Free gets 300 checks, 40 commands, 20 searches and 5 pictures
a day; Plus gets 2,000 / 400 / 150 / 40. Change them with one `update public.plans …` and no app update.


1. Free plan limits: how many checks, commands, searches and pictures per day?
2. Paid plan at launch, or later?
3. Keep "On this Mac" (local models) in release builds as a privacy option? It needs no server but can't do search or pictures.
4. Should Saved ever sync between Macs? (Affects what Google's terms allow us to store.)

## 8. Deploy, step by step

You run these on your Mac, in the repo. Nothing secret is typed into the app or committed.

1. Create the project at supabase.com, then link it:
   ```sh
   brew install supabase/tap/supabase
   supabase login
   supabase link --project-ref <your-project-ref>
   ```
2. Create the tables, limits and functions:
   ```sh
   supabase db push
   ```
3. Give the server its provider keys (only Supabase sees them):
   ```sh
   supabase secrets set NEBIUS_API_KEY=… GEMINI_API_KEY=…
   ```
   Optional: `GEMINI_MODEL`, and `LINA_CHECK_MODELS`, `LINA_COMMAND_MODELS`, `LINA_IMAGE_MODELS` (comma-separated)
   to change which models people can use.
4. Deploy the gateway:
   ```sh
   supabase functions deploy lina-ai
   ```
5. **Make the sign-in email show a code.** Supabase's default email sends a link. In the dashboard, Authentication →
   Emails → *Magic link*, paste [`supabase/templates/magic_link.html`](../supabase/templates/magic_link.html) (it shows
   `{{ .Token }}`), or run `supabase config push`. For real users, set up custom SMTP: the built-in sender is
   rate-limited and meant for testing.
6. Connect the app. Add the public values to `.env` (or the environment) and rebuild:
   ```sh
   SUPABASE_URL=https://<your-project-ref>.supabase.co
   SUPABASE_ANON_KEY=<publishable key>
   ```
   `scripts/build-app.sh` writes them into Lina's Info.plist, so a release build carries them for everyone.
7. Open Lina → Settings → Account, enter your email, type the code. `/lina help`, a sentence check and a search
   should now work with no keys on the Mac, and Settings → Account shows today's counts.

## Sources

- Nebius: [rate limits](https://docs.tokenfactory.nebius.com/ai-models-inference/rate-limits) ·
  [overview](https://docs.tokenfactory.nebius.com/ai-models-inference/overview) ·
  [Nemotron models and prices](https://nebius.com/services/token-factory/models/nvidia-nemotron-models-inference) ·
  [model catalog](https://tokenfactory.nebius.com/models) ·
  [legal quick guide (ZDR)](https://docs.tokenfactory.nebius.com/legal/legal-quick-guide) ·
  [image generation example](https://docs.tokenfactory.nebius.com/api-reference/examples/image-generation)
- Google: [Grounding with Google Search](https://ai.google.dev/gemini-api/docs/google-search) ·
  [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing) ·
  [Gemini API additional terms](https://ai.google.dev/gemini-api/terms) ·
  [zero data retention](https://ai.google.dev/gemini-api/docs/zdr) ·
  [release notes](https://ai.google.dev/gemini-api/docs/changelog)
- Supabase: [Edge Function limits](https://supabase.com/docs/guides/functions/limits) ·
  [Securing Edge Functions](https://supabase.com/docs/guides/functions/auth) ·
  [Login with Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple) ·
  [Swift reference](https://supabase.com/docs/reference/swift/start)
- Apple: [Accessibility in sandboxed apps (DTS)](https://developer.apple.com/forums/thread/707680) ·
  [Mac App Store and Accessibility](https://developer.apple.com/forums/thread/756130)
