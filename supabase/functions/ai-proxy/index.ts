// Baytak AR - production AI proxy (Supabase Edge Function).
//
// The launch-grade replacement for shipping provider keys inside the app:
// the app sends normal OpenAI-style chat/completions bodies HERE, and this
// function attaches the right provider key SERVER-SIDE and forwards the
// call. Keys live in Supabase secrets, never in an APK.
//
//   supabase functions deploy ai-proxy
//   supabase secrets set OPENAI_API_KEY=sk-...
//   supabase secrets set NVIDIA_API_KEY=nvapi-...
//   supabase secrets set GEMINI_API_KEY=AIza...          # optional
//   supabase secrets set REQUIRE_LICENSE=true            # default ON
//   supabase secrets set DEVICE_DAILY_LIMIT=300          # per device/day
//   supabase secrets set LICENSE_DAILY_LIMIT=4000        # per store/day
//
// SECURITY MODEL (audited b26). Assume the anon key AND the license key
// are PUBLIC - both ship in the app and can be extracted. They are NOT
// what protects the paid card. Two real controls bound the damage:
//   1. a GLOBAL per-license daily ceiling, checked BEFORE forwarding, so
//      no amount of client-side identifier rotation can exceed the
//      store's daily budget;
//   2. a strict model ALLOWLIST + output-token CLAMP + field WHITELIST,
//      so an attacker cannot pick the costliest model or unbounded output.
// The per-device quota (device id is a client header, therefore spoofable)
// is only a courtesy fairness limit, never the financial backstop.
// ALSO set a hard usage limit on the OpenAI account itself (dashboard) -
// that is the ultimate backstop this function cannot provide.

import { createClient } from "jsr:@supabase/supabase-js@2";

const PROVIDERS = {
  openai: {
    url: "https://api.openai.com/v1/chat/completions",
    keyEnv: "OPENAI_API_KEY",
  },
  gemini: {
    url:
      "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    keyEnv: "GEMINI_API_KEY",
  },
  nvidia: {
    url: "https://integrate.api.nvidia.com/v1/chat/completions",
    keyEnv: "NVIDIA_API_KEY",
  },
} as const;

// Exactly the model ids the app can send (mirror lib/services/ai_client
// .dart). Anything else is rejected before a provider is ever contacted.
const ALLOWED_MODELS = new Set<string>([
  // OpenAI tiers the app's OPENAI_MODEL may name
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.4-mini",
  // NVIDIA vision + text chains
  "qwen/qwen3.5-397b-a17b",
  "nvidia/nemotron-nano-12b-v2-vl",
  "meta/llama-3.2-90b-vision-instruct",
  "mistralai/mistral-large-3-675b-instruct-2512",
  "deepseek-ai/deepseek-v4-pro",
  "nvidia/nemotron-3-super-120b-a12b",
  // Gemini fallback
  "gemini-3.5-flash",
  "gemini-2.5-flash",
]);

const MAX_OUTPUT_TOKENS = 16384;
const MAX_BODY_BYTES = 400 * 1024; // ~180 KB image data-URI + prompt headroom

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-license-key, x-device-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

function posInt(name: string, dflt: number): number {
  const n = Number(Deno.env.get(name) ?? "");
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : dflt;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  // ---- body size guard (before buffering the whole thing) ---------------
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) {
    return json(413, { error: "payload_too_large" });
  }
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json(413, { error: "payload_too_large" });
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  const model = String(body["model"] ?? "");
  if (!ALLOWED_MODELS.has(model) || !Array.isArray(body["messages"])) {
    return json(400, {
      error: "model_not_allowed",
      message: "Unknown model or missing messages.",
    });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const day = new Date().toISOString().slice(0, 10);
  const licenseKey = (req.headers.get("x-license-key") ?? "").slice(0, 128);

  // ---- per-store license (secure by default) ----------------------------
  const reqLicRaw = (Deno.env.get("REQUIRE_LICENSE") ?? "").trim().toLowerCase();
  const licenseOff = reqLicRaw === "false" || reqLicRaw === "0" ||
    reqLicRaw === "off";
  if (reqLicRaw !== "" && !licenseOff && reqLicRaw !== "true") {
    return json(500, {
      error: "config_error",
      message: "REQUIRE_LICENSE must be 'true' or 'false'.",
    });
  }
  if (!licenseOff) {
    if (!licenseKey) {
      return json(402, {
        error: "license_required",
        message: "This build has no store license configured.",
      });
    }
    const { data, error } = await admin
      .from("licenses")
      .select("active")
      .eq("key", licenseKey)
      .maybeSingle();
    if (error) {
      return json(503, {
        error: "license_check_unavailable",
        message: "Could not verify the license; try again.",
      });
    }
    if (!data || data.active !== true) {
      return json(402, {
        error: "license_invalid",
        message: "The store license is missing or deactivated.",
      });
    }
  }

  // ---- daily ceilings, READ-then-check (bumped only on a BILLED call) ----
  // The counters are incremented AFTER a successful upstream response, so
  // the app's fallback chain (several candidates per analysis, most of
  // which may fail fast) consumes at most ONE unit per completed analysis
  // - and failed/unbilled attempts cost nothing. We READ current counts
  // here to reject over-budget callers before spending money.
  const deviceId = (req.headers.get("x-device-id") ?? "unknown").slice(0, 64);
  const deviceLimit = posInt("DEVICE_DAILY_LIMIT", 300);
  const licenseLimit = posInt("LICENSE_DAILY_LIMIT", 4000);
  const licBucket = `lic:${licenseKey || "no-license"}`;
  const devBucket = `dev:${deviceId}`;

  const { data: counts, error: readErr } = await admin
    .from("proxy_usage")
    .select("device_id,count")
    .in("device_id", [licBucket, devBucket])
    .eq("day", day);
  if (readErr) {
    return json(503, {
      error: "quota_unavailable",
      message: "Usage counter unavailable; request denied (fail-closed).",
    });
  }
  const used = (id: string) =>
    (counts ?? []).find((r) => r.device_id === id)?.count ?? 0;
  if (used(licBucket) >= licenseLimit) {
    return json(429, {
      error: "license_quota_exceeded",
      message: `The store's daily AI budget (${licenseLimit}) is reached.`,
    });
  }
  if (used(devBucket) >= deviceLimit) {
    return json(429, {
      error: "quota_exceeded",
      message: `Daily AI quota (${deviceLimit}) reached for this device.`,
    });
  }

  // ---- provider routing + strict body rebuild ---------------------------
  const which = model.startsWith("gpt-")
    ? PROVIDERS.openai
    : model.startsWith("gemini-")
    ? PROVIDERS.gemini
    : PROVIDERS.nvidia;
  const key = Deno.env.get(which.keyEnv) ?? "";
  if (!key) {
    return json(501, {
      error: "provider_not_configured",
      message: `${which.keyEnv} is not set on the proxy.`,
    });
  }

  // Rebuild the upstream body from a WHITELIST - never forward the raw
  // client body (blocks smuggled costly params like n/logprobs/tools).
  const isGpt = model.startsWith("gpt-");
  const rawTokens = Number(
    body["max_completion_tokens"] ?? body["max_tokens"] ?? MAX_OUTPUT_TOKENS,
  );
  const tokens = Number.isFinite(rawTokens) && rawTokens > 0
    ? Math.min(Math.floor(rawTokens), MAX_OUTPUT_TOKENS)
    : MAX_OUTPUT_TOKENS;
  const upstreamBody: Record<string, unknown> = {
    model,
    messages: body["messages"],
    [isGpt ? "max_completion_tokens" : "max_tokens"]: tokens,
  };
  // GPT-5.x rejects temperature; others get the app's fixed 0.2
  if (!isGpt) upstreamBody["temperature"] = 0.2;
  if (body["response_format"] !== undefined) {
    upstreamBody["response_format"] = body["response_format"];
  }

  try {
    const upstream = await fetch(which.url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${key}`,
      },
      body: JSON.stringify(upstreamBody),
      signal: AbortSignal.timeout(110_000),
    });
    const text = await upstream.text();
    // relay the answer on success; on upstream error return a generic
    // status (never leak the provider's raw error body/keys)
    if (upstream.status >= 200 && upstream.status < 300) {
      // count the BILLED call now (best-effort - never fail a paid answer
      // over bookkeeping). Both buckets in parallel.
      await Promise.all([
        admin.rpc("bump_proxy_usage", { p_device: licBucket, p_day: day }),
        admin.rpc("bump_proxy_usage", { p_device: devBucket, p_day: day }),
      ]).catch(() => {});
      return new Response(text, {
        status: 200,
        headers: { "content-type": "application/json", ...CORS },
      });
    }
    return json(502, {
      error: "upstream_error",
      status: upstream.status,
      message: "The AI provider returned an error.",
    });
  } catch (e) {
    const timeout = e instanceof DOMException && e.name === "TimeoutError";
    return json(timeout ? 504 : 502, {
      error: timeout ? "upstream_timeout" : "upstream_unreachable",
    });
  }
});
