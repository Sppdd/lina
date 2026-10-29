// lina-ai: the only door between Lina.app and the model providers.
//
// The app sends the signed-in person's session token; this function checks it, counts the request against
// their plan (public.consume), and calls Nebius Token Factory or Gemini with keys only the server holds.
// The Nebius routes speak the OpenAI API, so the app's client only changes its base URL.
//
//   POST /v1/chat/completions   sentence checks (x-lina-task: check) and commands (x-lina-task: command), streamed
//   POST /v1/images/generations /lina image
//   GET  /v1/models             the models this server allows, for /lina model
//   POST /search                {system, prompt} → Gemini generateContent with Google Search grounding
//   GET  /usage                 today's use and the plan's limits
//
// Secrets (supabase secrets set …): NEBIUS_API_KEY, GEMINI_API_KEY.
// Optional: GEMINI_MODEL, LINA_CHECK_MODELS, LINA_COMMAND_MODELS, LINA_IMAGE_MODELS (comma-separated).
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.

const NEBIUS = "https://api.tokenfactory.nebius.com/v1";
const GEMINI = "https://generativelanguage.googleapis.com/v1beta/models";

const env = (name: string, fallback = "") => Deno.env.get(name) ?? fallback;
const list = (name: string, fallback: string[]) => {
  const v = env(name).split(",").map((s) => s.trim()).filter(Boolean);
  return v.length ? v : fallback;
};

const CHECK_MODELS = list("LINA_CHECK_MODELS", ["nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B"]);
const COMMAND_MODELS = list("LINA_COMMAND_MODELS", [
  "nvidia/nemotron-3-super-120b-a12b",
  "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B",
]);
const IMAGE_MODELS = list("LINA_IMAGE_MODELS", ["black-forest-labs/flux-schnell", "black-forest-labs/flux-dev"]);
const GEMINI_MODEL = env("GEMINI_MODEL", "gemini-3.5-flash-lite");

/** Longest text one request may carry, and the most it may ask for back. */
const MAX_INPUT_CHARS = 16_000;
const MAX_TOKENS = { check: 800, command: 1200 } as const;

type Kind = "check" | "command" | "search" | "image";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const refuse = (status: number, error: string) => json({ error }, status);

// ── Supabase: who is asking, and may they ────────────────────────────────────────────────────────────

const SUPABASE_URL = env("SUPABASE_URL");
const ANON_KEY = env("SUPABASE_ANON_KEY");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

/** The signed-in user's id, checked with Supabase Auth (so signed-out or deleted sessions are refused). */
async function userId(req: Request): Promise<string | null> {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  // The anon key is a valid JWT too; it must not count as a person.
  if (!token || token === ANON_KEY) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(8_000),
  });
  if (!res.ok) return null;
  const user = await res.json();
  return typeof user?.id === "string" ? user.id : null;
}

/** Calls a Postgres function as the server. */
async function rpc(name: string, args: Record<string, unknown>) {
  const headers: Record<string, string> = { apikey: SERVICE_KEY, "content-type": "application/json" };
  // Legacy service_role keys are JWTs and go in Authorization too; new secret keys (sb_secret_…) only in apikey.
  if (SERVICE_KEY.startsWith("eyJ")) headers.authorization = `Bearer ${SERVICE_KEY}`;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(8_000),
  });
  if (!res.ok) throw new Error(`${name} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

const NOUN: Record<Kind, [string, string]> = {
  check: ["sentence check", "sentence checks"],
  command: ["command", "commands"],
  search: ["search", "searches"],
  image: ["picture", "pictures"],
};

/** Counts one request, or returns the refusal to send back. */
async function consume(user: string, kind: Kind): Promise<Response | null> {
  const r = await rpc("consume", { p_user: user, p_kind: kind, p_units: 1 });
  if (r?.ok) return null;
  if (r?.reason === "limit") {
    const [, many] = NOUN[kind];
    return refuse(429, `You've used today's ${r.limit} ${many}. They come back at midnight UTC.`);
  }
  if (r?.reason === "blocked") return refuse(403, "This Lina account is paused. Contact support.");
  return refuse(403, "Lina couldn't find your account. Sign out and in again.");
}

/** Gives a request back when the provider failed, so people aren't charged for errors. */
async function refund(user: string, kind: Kind) {
  try {
    await rpc("consume", { p_user: user, p_kind: kind, p_units: -1 });
  } catch (e) {
    console.error("refund failed", e);
  }
}

// ── Routes ─────────────────────────────────────────────────────────────────────────────────────────────

async function chat(req: Request, user: string): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || !Array.isArray(body.messages)) return refuse(400, "Expected an OpenAI chat request.");
  const kind: "check" | "command" = req.headers.get("x-lina-task") === "check" ? "check" : "command";
  const allowed = kind === "check" ? CHECK_MODELS : COMMAND_MODELS;
  if (!allowed.includes(body.model)) {
    return refuse(403, `${body.model ?? "That model"} isn't available. Type /lina model to pick another.`);
  }
  const chars = body.messages.reduce((n: number, m: { content?: unknown }) =>
    n + (typeof m?.content === "string" ? m.content.length : 0), 0);
  if (chars > MAX_INPUT_CHARS) return refuse(413, "That's more text than Lina takes at once. Try a shorter passage.");

  const refusal = await consume(user, kind);
  if (refusal) return refusal;

  // Pass through only what the app uses, with the output capped.
  const upstreamBody = {
    model: body.model,
    messages: body.messages,
    max_tokens: Math.min(Number(body.max_tokens) || 400, MAX_TOKENS[kind]),
    temperature: body.temperature,
    stream: body.stream === true,
    stop: body.stop,
    chat_template_kwargs: body.chat_template_kwargs,
  };
  const upstream = await nebius("/chat/completions", upstreamBody, 90_000);
  if (!upstream.ok) {
    await refund(user, kind);
    return providerError(upstream, "Nebius");
  }
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "text/event-stream" },
  });
}

async function images(req: Request, user: string): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || typeof body.prompt !== "string") return refuse(400, "Expected an image request.");
  if (!IMAGE_MODELS.includes(body.model)) return refuse(403, `${body.model ?? "That model"} isn't available for pictures.`);
  if (body.prompt.length > 2_000) return refuse(413, "Describe the picture in fewer words.");

  const refusal = await consume(user, "image");
  if (refusal) return refusal;
  const upstream = await nebius("/images/generations", {
    model: body.model,
    prompt: body.prompt,
    response_format: "b64_json",
    response_extension: "png",
    width: Math.min(Number(body.width) || 1024, 1024),
    height: Math.min(Number(body.height) || 1024, 1024),
    num_inference_steps: body.num_inference_steps,
  }, 120_000);
  if (!upstream.ok) {
    await refund(user, "image");
    return providerError(upstream, "Nebius");
  }
  return new Response(upstream.body, { status: 200, headers: { "content-type": "application/json" } });
}

async function models(): Promise<Response> {
  // The app sorts writing and image models itself; list only what this server will run.
  const ids = [...new Set([...COMMAND_MODELS, ...CHECK_MODELS, ...IMAGE_MODELS])];
  return json({ object: "list", data: ids.map((id) => ({ id, object: "model" })) });
}

async function search(req: Request, user: string): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || typeof body.prompt !== "string" || typeof body.system !== "string") {
    return refuse(400, "Expected {system, prompt}.");
  }
  if (body.prompt.length + body.system.length > MAX_INPUT_CHARS) return refuse(413, "That question is too long.");

  const refusal = await consume(user, "search");
  if (refusal) return refusal;

  const generationConfig: Record<string, unknown> = { temperature: 0.3, maxOutputTokens: 600 };
  // A mid-sentence answer has to be quick: keep thinking short.
  if (GEMINI_MODEL.includes("2.5")) generationConfig.thinkingConfig = { thinkingBudget: 0 };
  else if (GEMINI_MODEL.includes("gemini-3")) generationConfig.thinkingConfig = { thinkingLevel: "low" };

  const upstream = await fetch(`${GEMINI}/${GEMINI_MODEL}:generateContent`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": env("GEMINI_API_KEY") },
    body: JSON.stringify({
      system_instruction: { parts: [{ text: body.system }] },
      contents: [{ role: "user", parts: [{ text: body.prompt }] }],
      tools: [{ google_search: {} }],
      generationConfig,
    }),
    signal: AbortSignal.timeout(40_000),
  });
  if (!upstream.ok) {
    await refund(user, "search");
    return providerError(upstream, "Gemini");
  }
  // Sent back as Google sent it, including the Search Suggestions the app must show. Nothing is stored here:
  // Google's terms don't allow keeping grounded results on our side.
  return new Response(upstream.body, { status: 200, headers: { "content-type": "application/json" } });
}

async function usage(user: string): Promise<Response> {
  return json(await rpc("usage_today", { p_user: user }));
}

// ── Plumbing ───────────────────────────────────────────────────────────────────────────────────────────

async function nebius(path: string, body: unknown, timeout: number, retried = false): Promise<Response> {
  const res = await fetch(`${NEBIUS}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${env("NEBIUS_API_KEY")}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeout),
  });
  // Token Factory's limits are per account; one short retry smooths over a burst.
  if (res.status === 429 && !retried) {
    await res.body?.cancel();
    await new Promise((r) => setTimeout(r, 800));
    return nebius(path, body, timeout, true);
  }
  return res;
}

async function providerError(res: Response, provider: string): Promise<Response> {
  const text = await res.text().catch(() => "");
  console.error(`${provider} ${res.status}: ${text.slice(0, 500)}`);
  if (res.status === 429) return refuse(503, "Lina is busy right now. Try again in a moment.");
  return refuse(502, `${provider} couldn't answer (${res.status}). Try again.`);
}

Deno.serve(async (req) => {
  const path = new URL(req.url).pathname.replace(/^\/(functions\/v1\/)?lina-ai/, "") || "/";
  try {
    const user = await userId(req);
    if (!user) return refuse(401, "Sign in to Lina again.");

    if (req.method === "POST" && path === "/v1/chat/completions") return await chat(req, user);
    if (req.method === "POST" && path === "/v1/images/generations") return await images(req, user);
    if (req.method === "GET" && path === "/v1/models") return await models();
    if (req.method === "POST" && path === "/search") return await search(req, user);
    if (req.method === "GET" && path === "/usage") return await usage(user);
    return refuse(404, `No route ${req.method} ${path}`);
  } catch (e) {
    console.error(e);
    if (e instanceof DOMException && e.name === "TimeoutError") return refuse(504, "That took too long. Try again.");
    return refuse(500, "Lina's server hit a problem. Try again.");
  }
});
