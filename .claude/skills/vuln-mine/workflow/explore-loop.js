// explore-loop.js — vuln-mine Explore loop: Reader -> Synthesizer -> Analyst.
//
// Run via the Workflow tool. The runtime injects bare in-scope globals:
//   agent, pipeline, phase, log   -> functions
//   args                          -> a JSON STRING (parse it)
//   budget                        -> object
// We reference them BARE (no globalThis, no redeclare). `typeof <undeclared>`
// is safe (no TDZ). Args shape: { run_dir, budget_total, budget_used }.
// No Date.now / Math.random: variation comes from the iteration index only.

export const meta = {
  name: 'vuln-mine-explore',
  description: 'vuln-mine explore loop: Reader->Synthesizer->Analyst pipeline that mines a target for crash PoCs',
  phases: [{ title: 'Explore', detail: 'Reader->Synthesizer->Analyst over shared memory' }],
}

function die(msg) { throw new Error('[explore-loop] ' + msg) }

// Parse the injected args. Runtime sends a JSON STRING; accept object too.
function loadArgs() {
  if (typeof args === 'undefined') return {}
  if (args && typeof args === 'object') return args
  if (typeof args === 'string') {
    try { return JSON.parse(args) || {} }
    catch (e) { die('args is not valid JSON: ' + e.message) }
  }
  return {}
}
const ARGS   = loadArgs()
const runDir = ARGS.run_dir
const total  = Number(ARGS.budget_total) || 0
const used0  = Number(ARGS.budget_used)  || 0
if (!runDir) die('missing required arg: run_dir')
const FLOOR = total > 0 ? Math.max(1, Math.round(0.1 * total)) : 1   // 10% reserved for REPORT
const BATCH = 3

const HELPERS = '.claude/skills/vuln-mine/helpers'

// ---- Stage output schemas ---------------------------------------------------
const READER_SCHEMA = {
  parsing_chain: [{ fn: 'string', file: 'string', role: 'string' }],
  suspicious:    [{ fn: 'string', file: 'string', why: 'string' }],
  data_flows:    ['string'],
  format_facts:  ['string'],
}
const SYNTH_SCHEMA = {
  id: 'string',
  file: 'string',
  rationale: 'string',
  targets_branch: 'string',   // REQUIRED — schema rejects a PoC without it
  derived_from: ['string'],
  binary_b64: 'string?',
}
const ANALYST_SCHEMA = {
  poc_id: 'string',
  crash: 'boolean',
  signal: 'string',
  sanitizer: 'string',
  crash_location: 'string',
  why_no_crash: 'string',
  verdict: 'string',                 // needs_more | converging | stuck
  writes: {
    candidate_status: 'string',      // unverified | verified_crash | verified_benign
    negative: 'object?',
    verified_crash: 'object?',
    next_constraints: ['string'],
  },
}

// ---- Stage prompts (reference exact helper CLIs + paths) --------------------
const readerPrompt = () => `You are the Reader for vuln-mine.
Read these memory files with Bash cat:
  cat ${runDir}/01-goal.yaml
  cat ${runDir}/02-code-path.yaml
  cat ${runDir}/03-input-format.yaml
  cat ${runDir}/07-next-constraint.yaml
Also inspect source under the directory named in 02/01 (Bash: grep/head). Identify the parsing
chain, suspicious functions, data flows, and any NEW input-format facts.
Append findings via the helper (Bash) — write-back.sh handles flock + rev + append. It takes a
record.json FILE PATH (not inline JSON), so write the JSON to a temp file first, then pass the
path. Use a fresh mktemp each call so parallel agents never clobber:
  mkdir -p ${runDir}/.records
  rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"parsing_chain":[{"fn":"<fn>","file":"<file:line>","role":"<role>"}],"suspicious":[{"fn":"<fn>","file":"<file:line>","why":"<why>"}],"data_flows":["<flow>"]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} code-path "$rf"
  rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"format_facts":["<fact>"]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} input-format "$rf"
Return ONLY a JSON object with keys: parsing_chain, suspicious, data_flows, format_facts.`

const synthPrompt = (idx) => `You are the Synthesizer for vuln-mine, iteration ${idx}.
Read (Bash cat):
  cat ${runDir}/02-code-path.yaml
  cat ${runDir}/03-input-format.yaml
  cat ${runDir}/04-candidate-poc.yaml
  cat ${runDir}/05-negative.yaml
  cat ${runDir}/07-next-constraint.yaml
Check 07.stagnation_counter: if it is >= 3, STAGNATION DETECTED — switch vector; pick an untried
open_hypothesis from 07 and target a DIFFERENT branch than prior candidates. Otherwise continue
along 07.next_iteration_must.
Produce ONE PoC that satisfies 07.next_iteration_must and avoids 05.mined_areas. targets_branch is
REQUIRED (concrete file:line or symbol) — a PoC without it is rejected.
Write the PoC binary to ${runDir}/pocs/poc-${idx}.bin using Bash (python3 emitting exact bytes).
Register it via write-back.sh. It takes a record.json FILE PATH (not inline JSON), so write the
JSON to a temp file first, then pass the path. Use a fresh mktemp so parallel agents never clobber:
  mkdir -p ${runDir}/.records
  rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"candidates":[{"id":"poc-${idx}","file":"${runDir}/pocs/poc-${idx}.bin","rationale":"<why this input hits targets_branch>","targets_branch":"<REQUIRED>","hypothesis_status":"unverified","derived_from":[]}]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} candidate-poc "$rf"
Return ONLY JSON: {id,file,rationale,targets_branch,derived_from}.`

const analystPrompt = (pocId) => `You are the Analyst for vuln-mine.
Read the candidate (Bash cat ${runDir}/04-candidate-poc.yaml) and the goal (Bash cat ${runDir}/01-goal.yaml).
Run the PoC through the harness helper (Bash):
  bash ${HELPERS}/run-harness.sh ${runDir}/01-goal.yaml ${runDir}/pocs/${pocId}.bin 30
Then classify the result DETERMINISTICALLY (do NOT free-text classify) with the helper:
  CL=$(bash ${HELPERS}/classify-result.sh ${runDir}/01-goal.yaml <harness_EXIT_value> ${runDir}/.runs/${pocId}.err)
classify-result.sh normalizes the exit code to a symbolic signal (134->SIGABRT, 139->SIGSEGV,
124->TIMEOUT) and emits one line like:
  crash=true|signal=SIGABRT|sanitizer=heap-buffer-overflow|at=file.c:42|verdict=verified_crash
Use CL's fields directly for all memory writes below (crash/signal/sanitizer/at/verdict). If
crash=false, give why_no_crash (REQUIRED). Then write back. write-back.sh takes a record.json FILE
PATH (not inline JSON), so write the JSON to a temp file first, then pass the path. Use a fresh
mktemp each call so parallel agents never clobber. Append this run into 06.runs[] (a list, so
concurrent Analysts never clobber each other's record):
  mkdir -p ${runDir}/.records
  rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"runs":[{"poc_id":"${pocId}","harness_exit":<n>,"stdout_tail":"<tail>","sanitizer_output":"<tail>","crash":<true|false>,"crash_location":"<loc|null>","why_no_crash":"<reason|null>","signal":"<sig>","sanitizer":"<kind>","verdict":"<verdict-from-CL>"}]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} verification "$rf"
If benign: rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"non_triggering":[{"poc_id":"${pocId}","reason":"<why_no_crash>"}]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} negative "$rf"
If verdict=verified_crash: rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"verified_crashes":[{"poc_id":"${pocId}","signal":"<sig>","sanitizer":"<kind>","at":"<loc>"}]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} candidate-poc "$rf"
Always update the next constraint, then recompute stagnation (this PERSISTS the counter to 07):
  rf=$(mktemp ${runDir}/.records/rec.XXXXXX); printf '%s' '{"next_iteration_must":["<concrete next step>"]}' > "$rf"; bash ${HELPERS}/write-back.sh ${runDir} next-constraint "$rf"
  bash ${HELPERS}/recompute-stagnation.sh ${runDir}/07-next-constraint.yaml ${runDir}/06-verification.yaml
Return ONLY JSON matching the analyst schema.`

// ---- Body -------------------------------------------------------------------
// Wrapped in an async function so top-level control flow (await/while/return)
// is valid. The runtime evaluates this module; we invoke body() at the end.
async function body() {
  phase('Explore')

  let used = used0
  let iteration = 0

  while (total - used > FLOOR) {
    const batch = []
    for (let i = 0; i < BATCH && total - used > FLOOR; i++) {
      iteration += 1
      used += 1
      batch.push(iteration)
    }
    if (batch.length === 0) break

    // pipeline(items, stage1, stage2, stage3): each stage gets (prevResult, item, index).
    // item = the iteration number; we use it to name poc ids.
    await pipeline(
      batch,
      ()           => agent(readerPrompt(), { schema: READER_SCHEMA, phase: 'Explore' }),
      (_r, idx)    => agent(synthPrompt(idx), { schema: SYNTH_SCHEMA, phase: 'Explore' }),
      (synth, idx) => agent(analystPrompt((synth && synth.id) || `poc-${idx}`), { schema: ANALYST_SCHEMA, phase: 'Explore' }),
    )
  }

  return { run_dir: runDir, iterations: iteration }
}

// CRITICAL: top-level await is REQUIRED. Without it, body() returns a promise
// the harness never awaits, and the workflow exits before spawned agents
// complete (agentCount=N, agents_done=0, ~25ms).
await body()
