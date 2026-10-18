create table if not exists public.team_snapshots (
  user_id uuid primary key references auth.users (id) on delete cascade,
  revision bigint not null check (revision > 0),
  payload text not null check (jsonb_typeof(payload::jsonb) = 'object'),
  updated_at timestamptz not null default now()
);

alter table public.team_snapshots enable row level security;

drop policy if exists "Users can read their own team snapshot"
  on public.team_snapshots;
create policy "Users can read their own team snapshot"
  on public.team_snapshots
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke insert, update, delete on public.team_snapshots from anon, authenticated;
grant select on public.team_snapshots to authenticated;

create or replace function public.sync_team_snapshot(
  p_expected_revision bigint,
  p_payload jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_current_revision bigint;
  v_next_revision bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Snapshot must be a JSON object' using errcode = '22023';
  end if;

  if octet_length(p_payload::text) > 10485760 then
    raise exception 'Snapshot is too large' using errcode = '22001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));

  select revision
    into v_current_revision
    from public.team_snapshots
    where user_id = v_user_id;

  v_current_revision := coalesce(v_current_revision, 0);
  if p_expected_revision <> v_current_revision then
    raise exception 'SYNC_CONFLICT' using errcode = '40001';
  end if;

  v_next_revision := v_current_revision + 1;
  insert into public.team_snapshots (user_id, revision, payload, updated_at)
    values (v_user_id, v_next_revision, p_payload::text, now())
  on conflict (user_id) do update
    set revision = excluded.revision,
        payload = excluded.payload,
        updated_at = excluded.updated_at;

  return v_next_revision;
end;
$$;

revoke all on function public.sync_team_snapshot(bigint, jsonb) from public;
grant execute on function public.sync_team_snapshot(bigint, jsonb) to authenticated;
