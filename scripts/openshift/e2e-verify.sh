#!/usr/bin/env bash
# End-to-end verification of the OpenShift ATLAS stack. Run BEFORE any
# benchmark arm. Every check is hard-fail; the suite exits nonzero on the
# first component that is not doing its job FOR REAL — health endpoints
# alone are not trusted (a lens that answers /ready but times out scoring
# under generation load passed every health check while silently zeroing
# 95% of candidate energies in the 2026-07-11 routed run).
#
# Usage: e2e-verify.sh [env-file]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/deploy/openshift/openshift.env}"
set -a; source "$ENV_FILE"; set +a
NS="${ATLAS_NAMESPACE:?}"

BENCH_POD=$(oc get pod -n "$NS" -l app.kubernetes.io/name=atlas-bench -o jsonpath='{.items[0].metadata.name}')
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
need() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

pyexec() { oc exec -n "$NS" "$BENCH_POD" -- python -c "$1" 2>&1; }

echo "=== 1. llama-server ==="
out=$(pyexec "
import urllib.request, json
r=urllib.request.urlopen('http://atlas-llama-server:8080/health', timeout=10)
print(r.status)")
[ "$out" = "200" ]; need $? "/health 200"

out=$(pyexec "
import urllib.request, json
d=json.loads(urllib.request.urlopen('http://atlas-llama-server:8080/v1/models', timeout=10).read())
m=d['data'][0]; print(m['id'], m['meta']['n_embd'])")
echo "  served: $out"
echo "$out" | grep -q "4096"; need $? "model reports n_embd=4096"

# Generation correctness + speed. MTP must not corrupt output.
out=$(pyexec "
import urllib.request, json, time
body=json.dumps({'model':'x','messages':[{'role':'user','content':'What is 2+2? Answer with just the number.'}],'temperature':0,'max_tokens':16,'chat_template_kwargs':{'enable_thinking':False}}).encode()
req=urllib.request.Request('http://atlas-llama-server:8080/v1/chat/completions', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=60).read())
print('CONTENT:'+d['choices'][0]['message']['content'].strip()[:20])")
echo "  $out"
echo "$out" | grep -q "4"; need $? "greedy generation is correct"

out=$(pyexec "
import urllib.request, json
body=json.dumps({'prompt':'Write a haiku about GPUs.','n_predict':256,'temperature':0.7}).encode()
req=urllib.request.Request('http://atlas-llama-server:8080/completion', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=120).read())
print(round(d.get('timings',{}).get('predicted_per_second',0),1))")
echo "  decode tok/s: $out"
if [ "${ATLAS_LLAMA_SPEC_TYPE:-none}" != "none" ]; then
  # Speculative decode configured: demand the speedup and log evidence.
  python3 -c "exit(0 if float('$out')>=70 else 1)" 2>/dev/null; need $? "decode >= 70 tok/s (spec decode active)"
  # Deterministic spec-decode evidence: the timings block reports draft
  # counts (log-grepping is flaky — startup lines scroll out of --tail).
  drafted=$(pyexec "
import urllib.request, json
body=json.dumps({'prompt':'Count from 1 to 30 as a comma-separated list.','n_predict':128,'temperature':0}).encode()
req=urllib.request.Request('http://atlas-llama-server:8080/completion', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=120).read())
print(d.get('timings',{}).get('draft_n',0))")
  echo "  draft_n: $drafted"
  python3 -c "exit(0 if int('$drafted')>0 else 1)" 2>/dev/null; need $? "completion timings report draft tokens (spec decode live)"
else
  # Spec decode off (MTP+--embeddings crashes llama-server at b9966:
  # GGML_ASSERT missing result_norm/result_embd — upstream #24443 class).
  python3 -c "exit(0 if float('$out')>=50 else 1)" 2>/dev/null; need $? "decode >= 50 tok/s (spec decode disabled)"
fi

EMBED_URL="http://atlas-llama-server:8080"
if [ -n "${ATLAS_EMBED_PORT:-}" ]; then
  EMBED_URL="http://atlas-llama-embed:${ATLAS_EMBED_PORT}"
fi
echo "=== 2. embeddings + PC-202 hidden states (via $EMBED_URL — the lens's lane) ==="
out=$(pyexec "
import urllib.request, json
body=json.dumps({'content':'def f(x): return x*2'}).encode()
req=urllib.request.Request('$EMBED_URL/embedding', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=60).read())
e=d[0]['embedding'] if isinstance(d,list) else d['embedding']
# Nested output means pooling NONE (per-token): the lens extractor would
# silently take e[0] — the FIRST TOKEN's hidden state — which is how the
# 2026-07-12 run scored every candidate on the embedding of 'def'.
print('PER_TOKEN' if isinstance(e[0], list) else len(e))")
[ "$out" = "4096" ]; need $? "/embedding returns ONE pooled 4096-dim vector (not per-token)"

out=$(pyexec "
import urllib.request, json
body=json.dumps({'content':'def f(x): return x*2','layers':[20]}).encode()
req=urllib.request.Request('$EMBED_URL/embedding', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=60).read())
d0=d[0] if isinstance(d,list) else d
hs=d0.get('hidden_states')
print('layers:', sorted(hs.keys()) if hs else None, '| n_tokens:', d0.get('hidden_states_n_tokens'))")
echo "  $out"
echo "$out" | grep -q "20"; need $? "PC-202 hidden-states capture returns layer 20"

echo "=== 3. geometric lens (idle) ==="
out=$(pyexec "
import urllib.request, json
d=json.loads(urllib.request.urlopen('http://atlas-geometric-lens:8099/ready', timeout=15).read())
print(d.get('ready'), d.get('lens_self_test'))")
[ "$out" = "True True" ]; need $? "/ready true + self-test passed"

out=$(pyexec "
import urllib.request, json
body=json.dumps({'text':'def add(a,b):\\n    return a+b'}).encode()
req=urllib.request.Request('http://atlas-geometric-lens:8099/internal/lens/score-text', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=60).read())
print(d.get('energy', 0.0))")
echo "  idle energy: $out"
python3 -c "exit(0 if float('$out')>0.001 else 1)" 2>/dev/null; need $? "score-text returns non-sentinel energy (idle)"

# Worst-case candidate length: failing tasks emit up to the full
# ATLAS_BENCH_MAX_TOKENS budget, and embedding requests 500 when the
# input exceeds n_ubatch ('input too large to process') — caught live
# 2026-07-12 after short-text checks passed. Score a ~7.5k-token text.
out=$(pyexec "
import urllib.request, json
body=json.dumps({'text':'x = 1\n' * 1500}).encode()
req=urllib.request.Request('http://atlas-geometric-lens:8099/internal/lens/score-text', data=body, headers={'Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(req, timeout=180).read())
print(d.get('energy', 0.0))")
echo "  7.5k-token energy: $out"
python3 -c "exit(0 if float('$out')>0.001 else 1)" 2>/dev/null; need $? "lens scores a worst-case-length candidate"

echo "=== 4. lens scoring UNDER GENERATION LOAD (the 2026-07-11 failure mode) ==="
out=$(pyexec "
import urllib.request, json, threading, time
def burn():
    body=json.dumps({'prompt':'Write a very long detailed essay about compilers.','n_predict':4096,'temperature':0.8}).encode()
    req=urllib.request.Request('http://atlas-llama-server:8080/completion', data=body, headers={'Content-Type':'application/json'})
    try: urllib.request.urlopen(req, timeout=600).read()
    except Exception: pass
threads=[threading.Thread(target=burn, daemon=True) for _ in range(${ATLAS_E2E_LOAD_STREAMS:-4})]
[t.start() for t in threads]
time.sleep(5)  # let slots fill
good=0; tries=6
for i in range(tries):
    body=json.dumps({'text':'def fib(n):\\n    if n<2: return n\\n    return fib(n-1)+fib(n-2)'}).encode()
    req=urllib.request.Request('http://atlas-geometric-lens:8099/internal/lens/score-text', data=body, headers={'Content-Type':'application/json'})
    try:
        d=json.loads(urllib.request.urlopen(req, timeout=150).read())
        if d.get('energy',0.0) > 0.001: good+=1
    except Exception:
        pass
    time.sleep(2)
print('%d/%d' % (good, tries))")
echo "  non-sentinel scores under load: $out"
python3 -c "g,t='$out'.split('/'); exit(0 if int(g)>=int(t)-1 else 1)" 2>/dev/null; \
  need $? "lens scores >=5/6 while ${ATLAS_E2E_LOAD_STREAMS:-4} generations saturate slots"

echo "=== 5. sandbox + v3-service + proxy ==="
out=$(pyexec "
import urllib.request
print(urllib.request.urlopen('http://atlas-sandbox:8020/health', timeout=10).status)" )
[ "$out" = "200" ] && ok "sandbox /health 200" || {
  # sandbox may not expose /health on 8070 in all revs; fall back to exec check
  oc exec -n "$NS" deploy/atlas-sandbox -- true 2>/dev/null; need $? "sandbox pod exec-able"; }
out=$(pyexec "
import urllib.request
print(urllib.request.urlopen('http://atlas-v3-service:8070/health', timeout=10).status)")
[ "$out" = "200" ] && ok "v3-service /health 200" || bad "v3-service /health"
out=$(pyexec "
import urllib.request
print(urllib.request.urlopen('http://atlas-proxy:8090/health', timeout=10).status)")
[ "$out" = "200" ] && ok "proxy /health 200" || bad "proxy /health"

echo "=== 6. bench harness mini-run (2 tasks, routed, full concurrency) ==="
oc exec -n "$NS" "$BENCH_POD" -- sh -c "cd /bench/ATLAS && rm -rf benchmark/results/e2e-verify_* && \
  PYTHONPATH=/bench/ATLAS ATLAS_LCB_RELEASE=release_v6only ATLAS_LLM_PARALLEL=1 ATLAS_PARALLEL_TASKS=${ATLAS_E2E_LOAD_STREAMS:-4} \
  ATLAS_BENCH_MAX_TOKENS=512 ATLAS_LCB_ALLOW_PARTIAL_CACHE=1 \
  python -u -m benchmark.v3_runner --run-id e2e-verify_routed --selection-strategy lens --max-tasks 2 --max-tokens 512" \
  > /tmp/e2e_mini.log 2>&1
grep -q "V3 BENCHMARK COMPLETE" /tmp/e2e_mini.log; need $? "mini routed run completes"

out=$(oc exec -n "$NS" "$BENCH_POD" -- python -c "
import json,glob
files=glob.glob('/bench/ATLAS/benchmark/results/e2e-verify_routed/v3_lcb/per_task/*.json')
tot=real=0
for f in files:
    ce=json.load(open(f)).get('telemetry',{}).get('candidate_energies') or []
    for c in ce:
        tot+=1
        if c.get('energy',0.0)>0.001: real+=1
print('%d/%d' % (real, tot))" 2>&1)
echo "  real energies in mini-run: $out"
python3 -c "r,t='$out'.split('/'); exit(0 if int(t)>0 and int(r)>=int(t)*0.8 else 1)" 2>/dev/null; \
  need $? ">=80% of candidate energies are non-sentinel in mini-run"

echo
echo "============================================"
echo "E2E RESULT: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" = "0" ]
