-- LIVE DESIGN SISTEM: rode UMA vez no SQL Editor do Supabase (pode rodar de novo sem problema).
-- ANTES DE RODAR: troque SEU_EMAIL_ADMIN (última linha) pelo e-mail do administrador.

-- 1) Corrige o erro "infinite recursion" das regras (função precisa ser security definer)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- 2) Colunas e tabela que o site usa
alter table public.profiles add column if not exists email text;
alter table public.leads add column if not exists has_contract boolean not null default false;
create table if not exists public.settings (key text primary key, value numeric not null default 0);
alter table public.settings enable row level security;
drop policy if exists "settings_admin" on public.settings;
create policy "settings_admin" on public.settings for all using (public.is_admin()) with check (public.is_admin());
insert into public.settings(key, value) values ('goal', 0) on conflict (key) do nothing;

-- 3) Todo usuário novo do Supabase ganha perfil de vendedor automaticamente
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name, role, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)), 'seller', new.email)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
insert into public.profiles(id, name, role, email)
  select id, split_part(email,'@',1), 'seller', email from auth.users on conflict (id) do nothing;
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

-- 4) Fecha brechas: vendedor não vira admin, não falsifica auditoria, não apaga contrato nem marca "recebido"
drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_update" on public.profiles for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "audit_insert" on public.audit_log;
create policy "audit_insert" on public.audit_log for insert with check (user_id = auth.uid());
drop policy if exists "contracts_all" on public.contracts;
drop policy if exists "contracts_select" on public.contracts;
drop policy if exists "contracts_insert" on public.contracts;
drop policy if exists "contracts_update" on public.contracts;
drop policy if exists "contracts_delete" on public.contracts;
create policy "contracts_select" on public.contracts for select using (seller_id = auth.uid() or public.is_admin());
create policy "contracts_insert" on public.contracts for insert with check (seller_id = auth.uid() or public.is_admin());
create policy "contracts_update" on public.contracts for update using (seller_id = auth.uid() or public.is_admin()) with check (seller_id = auth.uid() or public.is_admin());
create policy "contracts_delete" on public.contracts for delete using (public.is_admin());
create or replace function public.protect_paid() returns trigger language plpgsql as $$
begin
  if not public.is_admin() then
    if tg_op = 'INSERT' then new.paid := false; else new.paid := old.paid; end if;
  end if;
  return new;
end $$;
drop trigger if exists contracts_protect_paid on public.contracts;
create trigger contracts_protect_paid before insert or update on public.contracts for each row execute function public.protect_paid();

-- 5) Torna você administrador (troque o e-mail!)
update public.profiles set role = 'admin' where email = 'SEU_EMAIL_ADMIN';
