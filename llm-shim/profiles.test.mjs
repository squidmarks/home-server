import { test } from "node:test";
import assert from "node:assert/strict";
import { isProfileName, labelFrom, listFrom, switcherFor, readProfile, MAX_NAME } from "./profiles.mjs";

test("a profile name is a name, never an argument", () => {
  // This service proxies untrusted bodies. A name goes to a privileged script,
  // so the shape is narrower than the scripts themselves accept.
  assert.ok(isProfileName("mtp3"));
  assert.ok(isProfileName("mtp3-cram16"));
  assert.ok(isProfileName("ctx128k-chunk4096"));
  for (const bad of [
    "mtp3; rm -rf /", "mtp3 --flag", "../profiles.sh", "mtp3\nmtp3", "MTP3",
    "mtp3$(id)", "", "-", "mtp3--", "a".repeat(MAX_NAME + 1), null, 42, {},
  ]) {
    assert.equal(isProfileName(bad), false, `must reject ${JSON.stringify(bad)}`);
  }
});

test("the running profile is read out of the switcher's own output", () => {
  assert.equal(labelFrom("mtp3-cram16\n"), "mtp3-cram16");
  assert.equal(
    labelFrom("profiles: a b c\nrunning:  short-dflash (up)\n"),
    "short-dflash",
  );
  // "unknown (down)" is the switcher saying it cannot tell, which is not a name.
  assert.equal(labelFrom("running:  unknown (down)"), null);
  assert.equal(labelFrom(""), null);
});

test("the offered profiles come from the switcher, not a copy kept here", () => {
  assert.deepEqual(
    listFrom("profiles: long-dflash short-dflash ctx128k-chunk4096\nrunning: short-dflash"),
    ["long-dflash", "short-dflash", "ctx128k-chunk4096"],
  );
  assert.deepEqual(listFrom("examples:  base mtp3 mtp3-temp0"), ["base", "mtp3", "mtp3-temp0"]);
  assert.deepEqual(listFrom("nothing useful"), []);
});

test("sly is reported as itself, not as the name file's stale answer", async () => {
  // vllm-profiles.sh keeps a name file and answers "short-dflash" from it even
  // now, with sly running and the radiance build down. Reporting that would be
  // a claim about an engine that is not up -- the failure this service exists
  // to prevent. The running container decides.
  const sw = await switcherFor("vllm", { dir: "/x", dockerPs: async () => ["vllm-sly", "mongo"] });
  assert.equal(sw.switchable, false);
  assert.equal(sw.fixed, "sly");
  assert.equal(sw.script, null);

  const p = await readProfile(sw);
  assert.equal(p.profile, "sly");
  assert.deepEqual(p.available, []);
});

test("the radiance build still gets its own switcher when it is the one up", async () => {
  const sw = await switcherFor("vllm", { dir: "/x", dockerPs: async () => ["vllmmxfp4074"] });
  assert.equal(sw.switchable, true);
  assert.equal(sw.script, "/x/vllm-profiles.sh");
});

test("llama always uses profiles.sh; an unknown engine has no switcher", async () => {
  const sw = await switcherFor("llama", { dir: "/x", dockerPs: async () => [] });
  assert.equal(sw.script, "/x/profiles.sh");
  assert.equal(sw.switchable, true);
  assert.equal(await switcherFor("nonsense", { dir: "/x", dockerPs: async () => [] }), null);
});

test("a switcher that will not answer leaves the profile unknown, not wrong", async () => {
  const sw = { script: "/x/profiles.sh", engine: "llama", switchable: true };
  const p = await readProfile(sw, { exec: async () => { throw new Error("no such file"); } });
  assert.equal(p.profile, null);
  assert.deepEqual(p.available, []);
});
