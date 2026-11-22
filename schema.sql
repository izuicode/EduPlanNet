-- =====================================================================
-- EduPlanNet · esquema Supabase (idempotente: se puede ejecutar más de una vez)
-- Ejecutar en: Supabase → SQL Editor → New query → pegar todo → Run
-- Si YA tenés tablas con estos nombres pero otras columnas, no lo ejecutes sin revisar:
--   corré antes el diagnóstico (final del archivo) y comparalo.
-- =====================================================================

-- 1) Perfiles (1 fila por usuario de auth.users) y registro de actividad
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  email text, nombre text, apellido text, ci text, edad int,
  role text not null default 'estudiante' check (role in ('docente','estudiante','padre','admin')),
  alumno text, created_at timestamptz default now());
create table if not exists public.logs(
  id uuid primary key default gen_random_uuid(), u uuid, a text, t bigint);

-- 2) Colecciones del docente (cada fila: id, dueño u y los campos en d jsonb)
do $$ declare c text; begin
  foreach c in array array['classes','tasks','events','meds','posts','folders','plans'] loop
    execute format('create table if not exists public.%I(
      id uuid primary key default gen_random_uuid(),
      u uuid not null default auth.uid() references auth.users(id) on delete cascade,
      d jsonb not null default ''{}''::jsonb,
      created_at timestamptz default now())', c);
    execute format('alter table public.%I enable row level security', c);
  end loop;
end $$;
alter table public.classes add column if not exists code text;
create unique index if not exists classes_code_key on public.classes(code);
alter table public.posts   add column if not exists vis  text default 'pub';

-- 3) Funciones de rol
create or replace function public.is_admin() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin') $$;
create or replace function public.is_teacher() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from public.profiles where id=auth.uid() and role in ('docente','admin')) $$;

-- 4) Trigger: crea el perfil al registrarse. El rol admin NUNCA se acepta desde el cliente.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role','estudiante');
begin
  if r not in ('docente','estudiante','padre') then r := 'estudiante'; end if;
  insert into public.profiles(id,email,nombre,apellido,ci,edad,role,alumno) values(
    new.id, new.email,
    left(coalesce(new.raw_user_meta_data->>'nombre',''),60),
    left(coalesce(new.raw_user_meta_data->>'apellido',''),60),
    left(regexp_replace(coalesce(new.raw_user_meta_data->>'ci',''),'\D','','g'),8),
    case when (new.raw_user_meta_data->>'edad') ~ '^\d{1,3}$' then (new.raw_user_meta_data->>'edad')::int end,
    r, left(coalesce(new.raw_user_meta_data->>'alumno',''),100))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- 5) Row Level Security
alter table public.profiles enable row level security;
alter table public.logs     enable row level security;

drop policy if exists prof_read on public.profiles;
create policy prof_read on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());
drop policy if exists prof_admin_upd on public.profiles;
create policy prof_admin_upd on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists logs_ins on public.logs;
create policy logs_ins on public.logs for insert to authenticated with check (u=auth.uid());
drop policy if exists logs_read on public.logs;
create policy logs_read on public.logs for select to authenticated using (public.is_admin());

do $$ declare c text; begin
  foreach c in array array['classes','tasks','events','meds','folders','plans'] loop
    execute format('drop policy if exists own_all on public.%I', c);
    execute format('create policy own_all on public.%I for all to authenticated using (u=auth.uid()) with check (u=auth.uid() and public.is_teacher())', c);
  end loop;
end $$;

drop policy if exists posts_read on public.posts;
create policy posts_read on public.posts for select to authenticated using (u=auth.uid() or vis='pub');
drop policy if exists posts_ins on public.posts;
create policy posts_ins on public.posts for insert to authenticated with check (u=auth.uid() and public.is_teacher());
drop policy if exists posts_upd on public.posts;
create policy posts_upd on public.posts for update to authenticated using (u=auth.uid()) with check (u=auth.uid());
drop policy if exists posts_del on public.posts;
create policy posts_del on public.posts for delete to authenticated using (u=auth.uid());

-- 6) Acceso de alumnos/familias por código (devuelve SOLO esa clase)
create or replace function public.class_by_code(p_code text) returns jsonb
language sql security definer stable set search_path=public as $$
  select jsonb_build_object(
    'name', c.d->>'name',
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('title',t.d->>'title','desc',t.d->>'desc','due',t.d->>'due','st',t.d->>'st','grade',t.d->>'grade','note',t.d->>'note') order by t.created_at)
                       from public.tasks t where t.u=c.u and t.d->>'cls'=c.id::text), '[]'::jsonb),
    'posts', coalesce((select jsonb_agg(jsonb_build_object('title',p.d->>'title','body',p.d->>'body') order by p.created_at desc)
                       from public.posts p where p.vis='pub' or p.vis=c.id::text), '[]'::jsonb))
  from public.classes c where c.code=upper(p_code) limit 1 $$;
revoke all on function public.class_by_code(text) from public;
grant execute on function public.class_by_code(text) to anon, authenticated;

-- =====================================================================
-- DESPUÉS de registrarte en la web con tu cédula/correo, convertite en admin:
--   update public.profiles set role='admin' where email='TU_CORREO@dominio.com';
--
-- DIAGNÓSTICO (si ya tenías tablas): ver columnas existentes
--   select table_name, column_name, data_type from information_schema.columns
--   where table_schema='public' order by 1, ordinal_position;
-- =====================================================================
