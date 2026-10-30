-- Problem reports sent from Lina's "Report a Problem…" window and `/lina bug`.
-- The app only ever inserts: nobody can read, change or delete reports through the Data API.
-- Reports hold app names, lengths, settings and Lina's decisions, never document text.
create table public.problem_reports (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  -- A random id made on first launch, so reports from one Mac can be grouped. Not tied to a person.
  install_id uuid not null,
  app_version text not null check (char_length(app_version) between 1 and 40),
  kind text not null check (char_length(kind) between 1 and 200),
  note text not null default '' check (char_length(note) <= 4000),
  report text not null check (char_length(report) between 1 and 60000)
);

comment on table public.problem_reports is 'Problem reports filed from the Lina Mac app. Insert-only for clients.';

create index problem_reports_created_at_idx on public.problem_reports (created_at desc);
create index problem_reports_install_id_idx on public.problem_reports (install_id);

alter table public.problem_reports enable row level security;

revoke all on table public.problem_reports from anon, authenticated;
grant insert (install_id, app_version, kind, note, report) on table public.problem_reports to anon, authenticated;

create policy "Lina apps can file reports"
  on public.problem_reports
  for insert
  to anon, authenticated
  with check (char_length(report) > 0);
