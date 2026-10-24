-- Sicherheits-Hinweise des Supabase-Advisors beheben
create schema if not exists extensions;
alter extension pg_trgm set schema extensions;
revoke execute on function public.rls_auto_enable() from anon, authenticated, public;
