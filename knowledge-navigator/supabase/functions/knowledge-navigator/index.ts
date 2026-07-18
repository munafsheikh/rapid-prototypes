import { createClient } from 'jsr:@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' },
});

const html = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Knowledge Navigator</title><style>
:root{font-family:Inter,system-ui;background:#07111f;color:#e8f2ff}body{margin:0;padding:24px;background:radial-gradient(circle at top,#17335a,#07111f 45%)}
main{max-width:1100px;margin:auto}.hero{padding:28px;border:1px solid #31527f;border-radius:22px;background:#0c1d33dd;box-shadow:0 20px 60px #0008}h1{margin:0;font-size:clamp(2rem,5vw,4rem)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:18px}.card{background:#0d2038;border:1px solid #29476e;border-radius:18px;padding:18px}input,textarea,select,button{width:100%;box-sizing:border-box;margin:6px 0;padding:11px;border-radius:10px;border:1px solid #365b88;background:#071522;color:#fff}button{background:#18b6a4;border:0;font-weight:800;cursor:pointer}.danger{background:#d75a73}.claim{margin:12px 0;padding:14px;border-left:5px solid #18b6a4;background:#081827;border-radius:12px}.meta{font-size:.85rem;color:#a9bfd8}.score{font-weight:800;color:#65e6d4}pre{white-space:pre-wrap}.wide{grid-column:1/-1}@media(max-width:760px){.grid{grid-template-columns:1fr}}
</style></head><body><main><section class="hero"><div class="meta">DEPLOYED PROTOTYPE · SUPABASE</div><h1>Belief-Aware Knowledge Graph</h1><p>Submit evidence-backed claims, inspect confidence, review them, and generate an auditable receipt plus documentation.</p></section>
<div class="grid"><section class="card"><h2>New belief transaction</h2><form id="create"><input name="source_title" placeholder="Source title" required><input name="source_uri" placeholder="Source URI"><textarea name="excerpt" placeholder="Exact evidence excerpt" required></textarea><input name="locator" placeholder="Page, line, URL fragment or message date" required><input name="subject" placeholder="Subject" required><input name="predicate" placeholder="Predicate" required><input name="object" placeholder="Object" required><button>Create claim</button></form></section><section class="card"><h2>Runtime status</h2><pre id="status">Loading…</pre></section><section class="card wide"><h2>Verification queue</h2><div id="claims">Loading…</div></section></div></main>
<script>
const endpoint=location.href.split('?')[0];
async function api(action,options={}){const r=await fetch(endpoint+'?action='+action,options);const b=await r.json();if(!r.ok)throw Error(b.error||'Request failed');return b}
async function load(){const rows=await api('list');document.querySelector('#status').textContent=JSON.stringify({service:'knowledge-navigator',deployment:'SUPABASE_EDGE',claims:rows.length,updated:new Date().toISOString()},null,2);document.querySelector('#claims').innerHTML=rows.map(x=>`<article class="claim"><div class="meta">${x.source_title||''} · ${x.status}</div><h3>${x.subject} → ${x.predicate} → ${x.object}</h3><div>${x.excerpt||''}</div><p class="meta">Evidence: ${x.locator||'—'} · Policy: ${x.policy_version||'—'} · Confidence: <span class="score">${x.score??'—'}</span></p><button onclick="review('${x.id}','APPROVE')">Approve</button><button class="danger" onclick="review('${x.id}','REJECT')">Reject</button>${x.generated_document?`<pre>${x.generated_document}</pre>`:''}</article>`).join('')||'<p>No claims yet.</p>'}
async function review(id,decision){await api('review',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id,decision,reviewer:'Munaf',rationale:'Reviewed in Knowledge Navigator v0.1'})});await load()}
document.querySelector('#create').onsubmit=async e=>{e.preventDefault();const data=Object.fromEntries(new FormData(e.target));await api('create',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(data)});e.target.reset();await load()};load();
</script></body></html>`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type,authorization' } });
  const action = new URL(req.url).searchParams.get('action');
  try {
    if (!action) return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (action === 'list') {
      const { data, error } = await supabase.from('claim_review_view').select('*').order('created_at', { ascending: false });
      if (error) throw error;
      return json(data);
    }
    const body = await req.json();
    if (action === 'create') {
      const { data, error } = await supabase.rpc('create_belief_transaction', {
        p_source_title: body.source_title, p_source_uri: body.source_uri || '', p_excerpt: body.excerpt,
        p_subject: body.subject, p_predicate: body.predicate, p_object: body.object, p_locator: body.locator,
        p_source_quality: .85, p_directness: .9, p_relevance: .9, p_freshness: 1,
      });
      if (error) throw error;
      return json(data, 201);
    }
    if (action === 'review') {
      const { data, error } = await supabase.rpc('review_claim', { p_claim_id: body.id, p_decision: body.decision, p_reviewer: body.reviewer || 'demo-reviewer', p_rationale: body.rationale || null });
      if (error) throw error;
      return json(data);
    }
    return json({ error: 'Unknown action' }, 404);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
