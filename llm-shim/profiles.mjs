// Engine profiles: the configuration an engine was started with, as opposed to
// which model it holds.
//
// The bench needs this remotely. It currently shells out to profiles.sh on the
// box, which stops working the moment the bench moves to another host, and
// /admin/model only ever covered the MODEL -- so a remote bench could pick
// Qwen3.8 but not mtp3-cram16, which kills exactly the A/B comparisons the
// profile machinery exists for.
//
// Two rules carried over from the rest of this service:
//
//   Observed, not claimed. vllm-profiles.sh keeps a name file, and with sly
//   running it still answers "short-dflash" -- a profile belonging to an engine
//   that is not up. A label read from a file that nothing verifies is how a
//   whole benchmark sweep once ran against a dead engine with every check
//   reporting fine. So the container actually serving decides first, and the
//   name file is only consulted when it is the engine that file describes.
//
//   A request body is never an argument. This service proxies untrusted bodies.
//   A profile name is checked against a strict shape, passed as one argv
//   element with shell: false, and the script itself rejects names it does not
//   know. Nothing from a caller reaches a shell.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";

const run = promisify(execFile);

// Lower-case words joined by "-" (mtp3-cram16, ctx128k-chunk4096). Deliberately
// narrower than the scripts accept: no dots, slashes, spaces or any character
// a shell would treat specially, so a name cannot be anything but a name.
const SHAPE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const MAX_NAME = 48;

/** Pure: is this something we are willing to hand to a profile script? */
export function isProfileName(s) {
  return typeof s === "string" && s.length > 0 && s.length <= MAX_NAME && SHAPE.test(s);
}

/** Pure: the running profile out of `<switcher> label` / `list` output. */
export function labelFrom(stdout) {
  const t = String(stdout ?? "").trim();
  if (!t) return null;
  // `label` prints the bare name; `list` prints "running:  <name> (up)".
  const m = /^running:\s*(\S+)/m.exec(t) ?? /^(\S+)$/m.exec(t);
  const name = m?.[1];
  return name && name !== "unknown" ? name : null;
}

/** Pure: the profiles a `<switcher>` banner says it offers. */
export function listFrom(stdout) {
  const m = /^(?:profiles|examples):\s*(.+)$/m.exec(String(stdout ?? ""));
  return m ? m[1].trim().split(/\s+/).filter(Boolean) : [];
}

/**
 * Which script manages the engine that is up, and what to call its config.
 *
 * serve-sly.sh has no profile machinery -- it is one fixed configuration -- so
 * its profile is reported as a fixed name and it accepts no switches. Saying
 * "short-dflash" there, because a name file still holds that, would be a claim
 * about an engine that is not running.
 */
export async function switcherFor(engineId, { dir, dockerPs = defaultDockerPs } = {}) {
  if (engineId === "llama") {
    return { script: path.join(dir, "profiles.sh"), engine: "llama", switchable: true };
  }
  if (engineId === "strata") {
    // One fixed configuration, like sly; serve-strata.sh picks the config file.
    return { script: null, engine: "strata", switchable: false, fixed: "coder-iq1_m-262k" };
  }
  if (engineId !== "vllm") return null;
  const names = await dockerPs();
  if (names.some(n => /vllm-sly/.test(n))) {
    return { script: null, engine: "vllm", switchable: false, fixed: "sly" };
  }
  return { script: path.join(dir, "vllm-profiles.sh"), engine: "vllm", switchable: true };
}

async function defaultDockerPs() {
  try {
    const { stdout } = await run("docker", ["ps", "--format", "{{.Names}}"], { timeout: 3000 });
    return stdout.split("\n").map(s => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

/** The profile actually running, and what else this engine offers. */
export async function readProfile(sw, { exec = run } = {}) {
  if (!sw) return null;
  if (!sw.switchable) return { engine: sw.engine, profile: sw.fixed, available: [], switchable: false };
  try {
    const { stdout } = await exec(sw.script, ["list"], { timeout: 5000 });
    return {
      engine: sw.engine,
      profile: labelFrom(stdout),
      available: listFrom(stdout),
      switchable: true,
    };
  } catch {
    return { engine: sw.engine, profile: null, available: [], switchable: true };
  }
}
