// analyze-and-harness.js — Claude Code Workflow for vuln-target-prep.
// Two stages: ANALYZE (read source -> analysis.yaml) then HARNESS
// (analysis.yaml -> harness.c + compile_hints). Run context arrives via the
// Workflow `args` global: {src_dir, name, manifest_dir, fingerprint}.
//
// Constraints honored:
//  - plain JS (no TypeScript)
//  - meta is a pure literal (no Date.now / Math.random / argless new Date;
//    any variation is by stage index only)
//  - args existence is guarded (headless node --check must not throw)

export const meta = {
  name: "analyze-and-harness",
  description:
    "vuln-target-prep: read cloned source, pick a parser function, infer " +
    "its input grammar, then write an argv-file harness.c that calls it.",
  phases: [
    { id: "analyze", name: "ANALYZE", description: "Read source -> analysis.yaml" },
    { id: "harness", name: "HARNESS", description: "analysis.yaml -> harness.c + compile_hints" },
  ],
};

// Workflow harness injects `agent`, `args`, and the Bash/Write/Glob tools as
// globals at runtime. They are absent under plain `node --check`, so guard.
const args = (typeof args !== "undefined" && args) || {};
const agent = (typeof agent !== "undefined") ? agent : null;

function die(msg) {
  throw new Error("[analyze-and-harness] " + msg);
}

function requireArg(key) {
  const v = args[key];
  if (v === undefined || v === null || v === "") {
    die("missing required arg: " + key);
  }
  return v;
}

// --- ANALYZE stage -----------------------------------------------------------
// The agent reads the cloned source with grep/Glob/cat and emits analysis.yaml
// at <manifest_dir>/analysis.yaml with the schema:
//   target_function: {name, return_type, params:[{name,type}], file, line}
//   input_format: {format, grammar[], field_constraints[],
//                  known_valid_patterns[], known_invalid_patterns[]}
//   link_info: {include_header, is_static, needs_whole_archive, extra_libs[]}
async function analyze() {
  const srcDir = requireArg("src_dir");
  const name = requireArg("name");
  const manifestDir = requireArg("manifest_dir");
  const fingerprint = args.fingerprint || {};

  if (!agent) {
    die("ANALYZE: agent() unavailable (Workflow runtime required)");
  }

  const prompt = [
    "You are the ANALYZE stage of vuln-target-prep.",
    "Read the cloned C/C++ source at: " + srcDir,
    "Target name (use for naming outputs): " + name,
    "Fingerprint (build system, deps, size): " + JSON.stringify(fingerprint),
    "",
    "Use Bash to run grep/Glob/cat over the source tree. Pick ONE parser-like",
    "target function: it must take a buffer + length (or pointer + count),",
    "process untrusted data, and contain loops or memory ops (memcpy/malloc/",
    "array index) where memory bugs live.",
    "",
    "Write the result to " + manifestDir + "/analysis.yaml with EXACTLY this schema:",
    "  target_function:",
    "    name: <symbol>",
    "    return_type: <C type>",
    "    params: [{name: ..., type: ...}, ...]",
    "    file: <path relative to src_dir>",
    "    line: <1-based line of the definition>",
    "  input_format:",
    "    format: <short name, e.g. 'chunked TLV' or 'magic-prefixed binary'>",
    "    grammar: [{<field>: <type/desc>}, ...]",
    "    field_constraints: [{field, type, min, max, boundary_values:[...]}]",
    "    known_valid_patterns: [<hex or text>]",
    "    known_invalid_patterns: [<hex or text>]",
    "  link_info:",
    "    include_header: <header to #include from harness.c>",
    "    is_static: <true|false>   # if true, harness must use --whole-archive",
    "    needs_whole_archive: <true|false>",
    "    extra_libs: [<-l flags, e.g. '-lz'>]",
    "",
    "If no clear parser function exists, still write analysis.yaml with",
    "target_function.name: null and a comment explaining why. Do not guess.",
  ].join("\n");

  await agent({
    description: "ANALYZE: read source, pick parser function, write analysis.yaml",
    prompt: prompt,
  });

  return { analysis_yaml: manifestDir + "/analysis.yaml" };
}

// --- HARNESS stage -----------------------------------------------------------
// The agent reads analysis.yaml and writes harness.c: the argv-file template
// from spec §4.4. main(argc,argv) opens argv[1], reads it into a heap buffer,
// calls target_function(buf, n), frees, returns 0. Also emits compile_hints.
async function harness(analyzeOut) {
  const manifestDir = requireArg("manifest_dir");
  const analysisYaml = analyzeOut.analysis_yaml;

  if (!agent) {
    die("HARNESS: agent() unavailable (Workflow runtime required)");
  }

  const prompt = [
    "You are the HARNESS stage of vuln-target-prep.",
    "Read the analysis at: " + analysisYaml,
    "",
    "Write " + manifestDir + "/harness.c implementing this exact template,",
    "filled in from target_function in the analysis:",
    "  #include <stdio.h>",
    "  #include <stdlib.h>",
    "  #include \"<link_info.include_header>\"",
    "  int main(int argc, char **argv) {",
    "    if (argc != 2) return 2;",
    "    FILE *f = fopen(argv[1], \"rb\");",
    "    if (!f) return 2;",
    "    fseek(f, 0, SEEK_END);",
    "    long n = ftell(f);",
    "    fseek(f, 0, SEEK_SET);",
    "    unsigned char *buf = malloc(n);",
    "    if (!buf) { fclose(f); return 2; }",
    "    fread(buf, 1, n, f);",
    "    fclose(f);",
    "    <target_function>(buf, n);   /* call target parser */",
    "    free(buf);",
    "    return 0;",
    "  }",
    "",
    "Adjust the call if the signature differs (e.g. takes (buf, n, ctx)) but",
    "keep the argv-file -> heap-buffer -> call -> free shape. If link_info.",
    "is_static or needs_whole_archive is true, also write a JSON object to",
    manifestDir + "/compile_hints with:",
    "  { whole_archive: <bool>, extra_libs: [...], include_header: \"...\" }",
    "If target_function.name is null, do NOT write harness.c; instead write",
    manifestDir + "/compile_hints with {error: \"no parser function identified\"}.",
  ].join("\n");

  await agent({
    description: "HARNESS: write harness.c + compile_hints from analysis.yaml",
    prompt: prompt,
  });

  return {
    harness_c: manifestDir + "/harness.c",
    compile_hints: manifestDir + "/compile_hints",
  };
}

// --- pipeline entry ----------------------------------------------------------
// Workflow invokes `main()` with the args global populated. The two stages are
// strictly sequential (HARNESS depends on ANALYZE's analysis.yaml), so no
// internal fan-out in v1.
async function main() {
  const a = await analyze();
  const h = await harness(a);
  return { phase: "analyze-and-harness", analyze: a, harness: h };
}

// Named exports for tooling; Workflow calls main().
export { analyze, harness, main };

// Default export is the entrypoint.
export default { meta, main };
