-- Run once in Supabase SQL Editor BEFORE connecting the public site.
-- Keeps answer keys and scoring out of the public repository/browser.
begin;

drop policy if exists "anyone can read questions" on public.quiz_content;
drop policy if exists "admins can read questions" on public.quiz_content;
create policy "admins can read questions"
on public.quiz_content for select to authenticated
using (exists (
  select 1 from public.admin_users a where a.user_id = (select auth.uid())
));
revoke select on public.quiz_content from anon;
grant select, update on public.quiz_content to authenticated;

drop policy if exists "anyone can submit score" on public.scores;
revoke insert, update, delete on public.scores from anon, authenticated;
grant select on public.scores to anon, authenticated;

create table if not exists public.quiz_attempts (
  token uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  completed_at timestamptz
);
alter table public.quiz_attempts enable row level security;
revoke all on public.quiz_attempts from anon, authenticated;

create or replace function public.get_public_questions()
returns jsonb language sql stable security definer set search_path=''
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', q.obj->>'id',
      'title', q.obj->'title',
      'options', q.obj->'options',
      'images', q.obj->'images'
    ) order by q.ord
  ), '[]'::jsonb)
  from public.quiz_content c,
       jsonb_array_elements(c.questions) with ordinality as q(obj,ord)
  where c.id=1;
$$;

create or replace function public.start_quiz()
returns uuid language plpgsql volatile security definer set search_path=''
as $$
declare v_token uuid;
begin
  insert into public.quiz_attempts default values returning token into v_token;
  return v_token;
end;
$$;

create or replace function public.submit_quiz(
  p_token uuid, p_name text, p_answers jsonb, p_duration integer
)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare
  v_started timestamptz;
  v_all jsonb;
  v_review jsonb;
  v_correct integer;
  v_total integer;
begin
  if p_name is null or length(btrim(p_name)) not between 1 and 40
     or p_duration is null or p_duration < 10 or p_duration > 86400
     or p_answers is null or jsonb_typeof(p_answers) <> 'object'
  then
    raise exception 'Invalid quiz submission';
  end if;

  select started_at into v_started
  from public.quiz_attempts
  where token=p_token and completed_at is null
  for update;
  if v_started is null or v_started > now()
     or v_started > now() - interval '10 seconds'
     or v_started < now() - interval '1 day'
  then
    raise exception 'Quiz session expired or already completed';
  end if;

  select questions into v_all from public.quiz_content where id=1;
  if v_all is null then raise exception 'Quiz is not configured'; end if;

  select count(*) filter (
      where q.obj->'correct' <> 'null'::jsonb
        and (p_answers->>(q.obj->>'id')) ~ '^[0-9]{1,2}$'
        and (p_answers->>(q.obj->>'id'))::integer = (q.obj->>'correct')::integer
    ),
    count(*) filter (where q.obj->'correct' <> 'null'::jsonb),
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', q.obj->>'id',
        'correct_index', q.obj->'correct',
        'note', q.obj->'note'
      ) order by q.ord
    ), '[]'::jsonb)
  into v_correct, v_total, v_review
  from jsonb_array_elements(v_all) with ordinality q(obj,ord);

  update public.quiz_attempts set completed_at=now() where token=p_token;
  insert into public.scores(player_name,correct_count,total_count,duration_seconds)
  values (btrim(p_name),v_correct,v_total,p_duration);
  return jsonb_build_object('correct',v_correct,'total',v_total,'review',v_review);
end;
$$;

revoke all on function public.get_public_questions() from public;
revoke all on function public.start_quiz() from public;
revoke all on function public.submit_quiz(uuid,text,jsonb,integer) from public;
grant execute on function public.get_public_questions() to anon, authenticated;
grant execute on function public.start_quiz() to anon, authenticated;
grant execute on function public.submit_quiz(uuid,text,jsonb,integer) to anon, authenticated;

commit;
