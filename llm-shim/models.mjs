// What a model id means: which engine serves it, and the one fixed key the
// privileged switch script will accept for it.
//
// The studio chooses a MODEL, never an engine. That is deliberate. An engine is
// an implementation detail the studio has no reason to know about -- but a model
// id is what a benchmark result is stamped with and what a studio's admin
// setting records, and an id that quietly means a different model tomorrow makes
// every result recorded under it unattributable. That is the mistake ADR-0016
// exists about. So ids are explicit end to end here, and what gets hidden is the
// engine and the swap.
//
// `key` is the ONLY thing handed to switch-engine.sh. It comes from this fixed
// set and never from a request body: the shim proxies untrusted bodies, so it
// must not be able to turn one into an argument to a privileged script.

export const MODELS = {
  "local-qwen3.8-27b-mxfp4": {
    key: "qwen-vllm",
    engine: "vllm",
    name: "Qwen3.8 27B MXFP4 (vLLM)",
    // The ids this engine actually answers /v1/models with. Residency is READ
    // back from the server through these rather than believed from whatever we
    // last asked for -- vllm-profiles.sh learned that the hard way, when a
    // failed start left a name file claiming a profile nothing was running and
    // a whole sweep arm ran against a dead engine with every check saying fine.
    served: ["Qwen3.8", "Qwen3.6", "Qwen3.8-MXFP4", "local-qwen3.8-27b-mxfp4"],
    // How the Claude desktop app sees this model. Its gateway picker accepts
    // only ids that look like Anthropic routes, and rejects outright any id
    // naming another vendor's model ("qwen" included). So the app is offered
    // this id instead, and requests for it are pointed back at the real model
    // before they reach the engine. The display name stays the real one. See
    // withAnthropicFields.
    anthropicId: "claude-local",
    anthropicTier: "sonnet",
  },
  "local-gemma-4-26b-a4b": {
    key: "gemma-vllm",
    engine: "vllm",
    name: "Gemma 4 26B A4B INT4 (vLLM)",
    served: ["Gemma4", "gemma-4-26b-a4b", "local-gemma-4-26b-a4b"],
  },
  "local-qwen3.8-27b": {
    key: "qwen-llama",
    engine: "llama",
    name: "Qwen3.8 27B Q4_K_M (llama.cpp)",
    served: ["local-qwen3.8-27b", "Qwen3.8-27B-UD-Q4_K_M.gguf"],
  },
};

/** Every key switch-engine.sh is allowed to be called with. */
export const MODEL_KEYS = Object.values(MODELS).map(m => m.key);

/** The registry entry for a model id, or null if we do not serve that id. */
export function modelFor(id) {
  if (!id) return null;
  if (MODELS[id]) return { id, ...MODELS[id] };
  // A caller may address a model by one of the engine's own names, or by the
  // id an Anthropic client was offered for it.
  for (const [key, m] of Object.entries(MODELS)) {
    if (m.served.includes(id) || m.anthropicId === id) return { id: key, ...m };
  }
  return null;
}

/**
 * Pure: the name to hand the ENGINE for a requested model id. Only an
 * anthropicId is rewritten -- the engine has never heard of it -- and it becomes
 * the registry id when the engine answers to that, else the engine's first
 * served name. Anything else passes through untouched.
 */
export function engineModelId(id) {
  for (const [key, m] of Object.entries(MODELS)) {
    if (m.anthropicId && m.anthropicId === id) return m.served.includes(key) ? key : m.served[0];
  }
  return id;
}

/** The Claude family tiers an Anthropic client will accept on a model row. */
export const ANTHROPIC_TIERS = ["sonnet", "opus", "haiku", "fable"];

/**
 * Pure: an engine's /v1/models list, made acceptable to an Anthropic client too.
 *
 * The engine answers in OpenAI's shape, and the Claude desktop app's gateway
 * discovery throws away every row of that: it keeps a row only if the id looks
 * like a Claude model or the row carries `anthropic_family_tier`. Ours do
 * neither, so discovery reported "0 usable models" with all three rows in hand.
 *
 * Every row gains Anthropic's common fields, which an OpenAI client ignores.
 * Only ONE row gains a tier. When the resident model has an anthropicId, that
 * is a row of its own, appended -- discovery is not the last filter, and the
 * app's picker then drops any id that does not look like an Anthropic route.
 * Otherwise the tier goes on the resident model's registry-id row (or its first
 * served name, if the engine does not answer to the registry id). The engine's
 * aliases stay untiered on purpose, so the app drops them -- otherwise its
 * picker would list one model several times. Nothing resident means nothing
 * tiered, not a guess.
 */
export function withAnthropicFields(body) {
  const rows = Array.isArray(body?.data) ? body.data : [];
  const resident = residentFrom(rows.map(m => m?.id).filter(Boolean));
  const pick = resident
    && (rows.find(m => m?.id === resident.id) ?? rows.find(m => resident.served.includes(m?.id)));
  const tier = ANTHROPIC_TIERS.includes(resident?.anthropicTier) ? resident.anthropicTier : "sonnet";
  const data = rows.map(m => {
    if (!m || typeof m !== "object") return m;
    const row = {
      ...m,
      type: "model",
      display_name: m === pick ? resident.name : m.id,
      created_at: new Date(Number.isFinite(m.created) ? m.created * 1000 : 0).toISOString(),
      ...(Number.isFinite(m.max_model_len) ? { max_input_tokens: m.max_model_len } : {}),
    };
    return m === pick && !resident.anthropicId
      ? { ...row, anthropic_family_tier: tier, is_family_default: true }
      : row;
  });
  if (pick && resident.anthropicId) {
    const base = data[rows.indexOf(pick)];
    data.push({
      ...base,
      id: resident.anthropicId,
      display_name: resident.name,
      anthropic_family_tier: tier,
      is_family_default: true,
    });
  }
  return {
    ...body,
    data,
    has_more: false,
    first_id: data[0]?.id ?? null,
    last_id: data.at(-1)?.id ?? null,
  };
}

/**
 * Which model is loaded right now, decided from what the engine answers with.
 * Null when nothing is serving or when what is serving matches no known model.
 */
export function residentFrom(servedIds) {
  if (!servedIds?.length) return null;
  for (const [id, m] of Object.entries(MODELS)) {
    if (servedIds.some(s => m.served.includes(s))) return { id, ...m };
  }
  return null;
}
