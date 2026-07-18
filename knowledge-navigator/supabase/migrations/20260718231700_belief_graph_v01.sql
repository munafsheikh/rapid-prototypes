create extension if not exists pgcrypto;

create table if not exists public.sources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  source_type text not null default 'document',
  canonical_uri text,
  created_at timestamptz not null default now()
);
create table if not exists public.source_submissions (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.sources(id),
  content_hash text not null,
  submitted_by text not null default 'demo-user',
  submitted_at timestamptz not null default now(),
  raw_excerpt text not null
);
create table if not exists public.claims (
  id uuid primary key default gen_random_uuid(),
  source_submission_id uuid not null references public.source_submissions(id),
  subject text not null,
  predicate text not null,
  object text not null,
  status text not null default 'PROPOSED' check (status in ('PROPOSED','ACCEPTED','REJECTED','STALE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.evidence_references (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  locator text not null,
  excerpt text not null,
  stance text not null default 'SUPPORTS' check (stance in ('SUPPORTS','CONTRADICTS')),
  created_at timestamptz not null default now()
);
create table if not exists public.confidence_evaluations (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  policy_version text not null default 'confidence-v1',
  source_quality numeric(5,4) not null,
  directness numeric(5,4) not null,
  relevance numeric(5,4) not null,
  freshness numeric(5,4) not null,
  contradiction_penalty numeric(5,4) not null default 0,
  verification_adjustment numeric(5,4) not null default 0,
  score numeric(5,4) generated always as (
    greatest(0, least(1, ((source_quality + directness + relevance + freshness) / 4) - contradiction_penalty + verification_adjustment))
  ) stored,
  calculated_at timestamptz not null default now()
);
create table if not exists public.review_decisions (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  decision text not null check (decision in ('APPROVE','REJECT','DEFER','MARK_STALE')),
  reviewer text not null default 'demo-reviewer',
  rationale text,
  decided_at timestamptz not null default now()
);
create table if not exists public.belief_receipts (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  review_decision_id uuid not null references public.review_decisions(id),
  previous_status text not null,
  new_status text not null,
  summary text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.generated_documents (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  format text not null default 'markdown',
  content text not null,
  generated_at timestamptz not null default now()
);

create index if not exists idx_claims_status on public.claims(status);
create index if not exists idx_evidence_claim on public.evidence_references(claim_id);
create index if not exists idx_confidence_claim on public.confidence_evaluations(claim_id, calculated_at desc);
create index if not exists idx_reviews_claim on public.review_decisions(claim_id, decided_at desc);

alter table public.sources enable row level security;
alter table public.source_submissions enable row level security;
alter table public.claims enable row level security;
alter table public.evidence_references enable row level security;
alter table public.confidence_evaluations enable row level security;
alter table public.review_decisions enable row level security;
alter table public.belief_receipts enable row level security;
alter table public.generated_documents enable row level security;

create or replace function public.create_belief_transaction(
  p_source_title text, p_source_uri text, p_excerpt text,
  p_subject text, p_predicate text, p_object text, p_locator text,
  p_source_quality numeric default 0.8, p_directness numeric default 0.8,
  p_relevance numeric default 0.8, p_freshness numeric default 1.0
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_source uuid; v_submission uuid; v_claim uuid; v_evidence uuid; v_confidence uuid;
begin
  insert into sources(title,source_type,canonical_uri) values(p_source_title,'document',nullif(p_source_uri,'')) returning id into v_source;
  insert into source_submissions(source_id,content_hash,raw_excerpt) values(v_source,encode(digest(coalesce(p_excerpt,''),'sha256'),'hex'),p_excerpt) returning id into v_submission;
  insert into claims(source_submission_id,subject,predicate,object) values(v_submission,p_subject,p_predicate,p_object) returning id into v_claim;
  insert into evidence_references(claim_id,locator,excerpt) values(v_claim,p_locator,p_excerpt) returning id into v_evidence;
  insert into confidence_evaluations(claim_id,source_quality,directness,relevance,freshness) values(v_claim,p_source_quality,p_directness,p_relevance,p_freshness) returning id into v_confidence;
  return jsonb_build_object('source_id',v_source,'submission_id',v_submission,'claim_id',v_claim,'evidence_id',v_evidence,'confidence_id',v_confidence);
end $$;

create or replace function public.review_claim(p_claim_id uuid,p_decision text,p_reviewer text default 'demo-reviewer',p_rationale text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_previous text; v_new text; v_review uuid; v_receipt uuid; v_document uuid; v_claim claims%rowtype; v_conf numeric;
begin
  if p_decision not in ('APPROVE','REJECT','DEFER','MARK_STALE') then raise exception 'Unsupported decision'; end if;
  select * into v_claim from claims where id=p_claim_id for update;
  if not found then raise exception 'Claim not found'; end if;
  v_previous:=v_claim.status;
  v_new:=case p_decision when 'APPROVE' then 'ACCEPTED' when 'REJECT' then 'REJECTED' when 'MARK_STALE' then 'STALE' else v_previous end;
  insert into review_decisions(claim_id,decision,reviewer,rationale) values(p_claim_id,p_decision,coalesce(nullif(p_reviewer,''),'demo-reviewer'),p_rationale) returning id into v_review;
  update claims set status=v_new,updated_at=now() where id=p_claim_id;
  select score into v_conf from confidence_evaluations where claim_id=p_claim_id order by calculated_at desc limit 1;
  insert into belief_receipts(claim_id,review_decision_id,previous_status,new_status,summary)
    values(p_claim_id,v_review,v_previous,v_new,format('%s changed claim from %s to %s under confidence-v1 (score %s)',p_decision,v_previous,v_new,coalesce(v_conf::text,'n/a'))) returning id into v_receipt;
  insert into generated_documents(claim_id,format,content)
    values(p_claim_id,'markdown',format('# Reviewed claim\n\n**Claim:** %s %s %s\n\n**Status:** %s\n\n**Confidence:** %s\n\n**Reviewer:** %s\n\n**Decision:** %s\n\n**Rationale:** %s\n\n**Receipt:** %s\n',v_claim.subject,v_claim.predicate,v_claim.object,v_new,coalesce(v_conf::text,'n/a'),p_reviewer,p_decision,coalesce(p_rationale,'—'),v_receipt)) returning id into v_document;
  return jsonb_build_object('claim_id',p_claim_id,'review_id',v_review,'receipt_id',v_receipt,'document_id',v_document,'status',v_new);
end $$;

create or replace view public.claim_review_view as
select c.id,c.subject,c.predicate,c.object,c.status,c.created_at,s.title source_title,s.canonical_uri,e.locator,e.excerpt,ce.score,ce.policy_version,br.id latest_receipt_id,gd.id latest_document_id,gd.content generated_document
from public.claims c
join public.source_submissions ss on ss.id=c.source_submission_id
join public.sources s on s.id=ss.source_id
left join lateral (select * from public.evidence_references x where x.claim_id=c.id order by x.created_at desc limit 1) e on true
left join lateral (select * from public.confidence_evaluations x where x.claim_id=c.id order by x.calculated_at desc limit 1) ce on true
left join lateral (select * from public.belief_receipts x where x.claim_id=c.id order by x.created_at desc limit 1) br on true
left join lateral (select * from public.generated_documents x where x.claim_id=c.id order by x.generated_at desc limit 1) gd on true;

grant usage on schema public to anon,authenticated;
grant select on public.claim_review_view to anon,authenticated;
grant execute on function public.create_belief_transaction(text,text,text,text,text,text,text,numeric,numeric,numeric,numeric) to anon,authenticated;
grant execute on function public.review_claim(uuid,text,text,text) to anon,authenticated;
