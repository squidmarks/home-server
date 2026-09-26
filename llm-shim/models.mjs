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
  // A caller may address a model by one of the engine's own names.
  for (const [key, m] of Object.entries(MODELS)) {
    if (m.served.includes(id)) return { id: key, ...m };
  }
  return null;
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
