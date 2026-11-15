-- One private team snapshot shared by a small group of authenticated users.
create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 100),
  owner_id uuid not null references auth.users(id),
  invite_code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);

create table public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null default '',
  primary key (team_id, user_id),
  unique (user_id)
);
create index team_members_user_id_idx on public.team_members(user_id);

create table public.shared_team_snapshots (
  team_id uuid primary key references public.teams(id) on delete cascade,
  revision bigint not null check (revision > 0),
  payload text not null check (jsonb_typeof(payload::jsonb) = 'object'),
  updated_at timestamptz not null default now()
);

alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.shared_team_snapshots enable row level security;
alter publication supabase_realtime add table public.shared_team_snapshots;

create function public.my_team_id() returns uuid language sql stable security definer
set search_path = '' as $$
  select team_id from public.team_members where user_id = (select auth.uid())
$$;

create policy "Members read team" on public.teams for select to authenticated
  using (id = public.my_team_id());
create policy "Owner edits team" on public.teams for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
create policy "Members read membership" on public.team_members for select to authenticated
  using (team_id = public.my_team_id());
create policy "Members edit own name" on public.team_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Members read snapshot" on public.shared_team_snapshots for select to authenticated
  using (team_id = public.my_team_id());

-- Membership creation and snapshot writes go through narrow, authenticated RPCs.
revoke insert, delete on public.teams from anon, authenticated;
revoke insert, delete on public.team_members from anon, authenticated;
revoke insert, update, delete on public.shared_team_snapshots from anon, authenticated;
grant select on public.teams to authenticated;
grant update(name) on public.teams to authenticated;
grant select on public.team_members to authenticated;
grant update(display_name) on public.team_members to authenticated;
grant select on public.shared_team_snapshots to authenticated;

create function public.create_team(p_name text, p_display_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_team uuid;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if length(trim(p_name)) not between 1 and 100 or length(trim(p_display_name)) not between 1 and 100 then
    raise exception 'Name must be 1 to 100 characters' using errcode = '22023';
  end if;
  if exists (select 1 from public.team_members where user_id = v_user) then
    raise exception 'Already in a team' using errcode = '23505';
  end if;
  insert into public.teams(name, owner_id) values (trim(p_name), v_user) returning id into v_team;
  insert into public.team_members(team_id, user_id, display_name)
    values (v_team, v_user, trim(p_display_name));
  -- Carry forward an existing single-user cloud backup, if there is one.
  insert into public.shared_team_snapshots(team_id, revision, payload)
    select v_team, 1, payload from public.team_snapshots where user_id = v_user;
  return v_team;
end; $$;

create function public.join_team(p_invite_code text, p_display_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_team uuid;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if length(trim(p_display_name)) not between 1 and 100 then
    raise exception 'Name must be 1 to 100 characters' using errcode = '22023';
  end if;
  if exists (select 1 from public.team_members where user_id = v_user) then
    raise exception 'Already in a team' using errcode = '23505';
  end if;
  select id into v_team from public.teams where invite_code = lower(trim(p_invite_code));
  if v_team is null then raise exception 'Invalid invitation code' using errcode = '22023'; end if;
  insert into public.team_members(team_id, user_id, display_name)
    values (v_team, v_user, trim(p_display_name));
  return v_team;
end; $$;

create function public.sync_shared_team_snapshot(
  p_team_id uuid, p_expected_revision bigint, p_payload jsonb
) returns bigint language plpgsql security definer set search_path = '' as $$
declare v_current bigint; v_next bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.team_members where team_id = p_team_id and user_id = auth.uid()
  ) then raise exception 'Not a team member' using errcode = '42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Snapshot must be a JSON object' using errcode = '22023';
  end if;
  if octet_length(p_payload::text) > 10485760 then
    raise exception 'Snapshot is too large' using errcode = '22001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_team_id::text, 0));
  select revision into v_current from public.shared_team_snapshots where team_id = p_team_id;
  v_current := coalesce(v_current, 0);
  if p_expected_revision <> v_current then
    raise exception 'SYNC_CONFLICT' using errcode = '40001';
  end if;
  v_next := v_current + 1;
  insert into public.shared_team_snapshots(team_id, revision, payload, updated_at)
    values(p_team_id, v_next, p_payload::text, now())
  on conflict (team_id) do update set revision = excluded.revision,
    payload = excluded.payload, updated_at = excluded.updated_at;
  return v_next;
end; $$;

create function public.rotate_team_invite(p_team_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_code text;
begin
  update public.teams set invite_code = replace(gen_random_uuid()::text, '-', '')
    where id = p_team_id and owner_id = auth.uid()
    returning invite_code into v_code;
  if v_code is null then raise exception 'Only the team owner can change invitations' using errcode = '42501'; end if;
  return v_code;
end; $$;

create function public.remove_team_member(p_team_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teams where id = p_team_id and owner_id = auth.uid())
    or p_user_id = auth.uid() then
    raise exception 'Only the team owner can remove another member' using errcode = '42501';
  end if;
  delete from public.team_members where team_id = p_team_id and user_id = p_user_id;
end; $$;

revoke all on function public.create_team(text, text) from public;
revoke all on function public.join_team(text, text) from public;
revoke all on function public.sync_shared_team_snapshot(uuid, bigint, jsonb) from public;
revoke all on function public.rotate_team_invite(uuid) from public;
revoke all on function public.remove_team_member(uuid, uuid) from public;
revoke all on function public.my_team_id() from public;
grant execute on function public.my_team_id() to authenticated;
grant execute on function public.create_team(text, text) to authenticated;
grant execute on function public.join_team(text, text) to authenticated;
grant execute on function public.sync_shared_team_snapshot(uuid, bigint, jsonb) to authenticated;
grant execute on function public.rotate_team_invite(uuid) to authenticated;
grant execute on function public.remove_team_member(uuid, uuid) to authenticated;
