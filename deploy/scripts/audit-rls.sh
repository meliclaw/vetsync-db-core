#!/usr/bin/env bash
# ==============================================================================
# audit-rls.sh — multi-tenant isolation audit for the VetSync public schema.
#
# Read-only. Answers, with numbers rather than assumptions:
#   - which tables carry organization_id / unit_id (so they are tenant-scoped)
#   - which have RLS enabled and how many policies
#   - which have a tenant-injection trigger
#   - which grant privileges to anon / authenticated
#   - how many rows each actually holds
#
# RLS only filters rows for roles that are NOT the table owner. With RLS
# disabled, a GRANT to `anon` is unrestricted access — and the publishable key
# that reaches `anon` ships inside the browser bundle by design.
#
#   ./audit-rls.sh                          # local PRD container
#   CONTAINER=vetsync-prd-supabase-db ./audit-rls.sh
#   OUT=/tmp/audit ./audit-rls.sh           # also write the CSV inventory
# ==============================================================================
set -uo pipefail

CONTAINER="${CONTAINER:-vetsync-prd-supabase-db}"
DB="${DB:-postgres}"
OUT="${OUT:-}"

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "container '$CONTAINER' not found" >&2; exit 1; }

q() { docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -tAc "$1" 2>/dev/null; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Tables covered by the repository's RLS foundation migration.
COVERED="'access_profile_permissions','access_profiles','applications','department_permissions','departments','groups','organization_users','organizations','profiles','units','user_access_profiles','user_departments','user_groups','user_roles','user_units'"

head_ "Scope"
q "
with t as (
  select c.relname,
    exists(select 1 from information_schema.columns
           where table_schema='public' and table_name=c.relname and column_name='organization_id') org,
    exists(select 1 from information_schema.columns
           where table_schema='public' and table_name=c.relname and column_name='unit_id') unit,
    c.relrowsecurity rls
  from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
  where c.relkind='r'
)
select
  '  tables in public ............. '||count(*)||E'\n'||
  '    tenant-scoped (org_id) ..... '||count(*) filter (where org)||E'\n'||
  '    unit-scoped only ........... '||count(*) filter (where unit and not org)||E'\n'||
  '    system / global ............ '||count(*) filter (where not org and not unit)||E'\n'||
  '  RLS enabled ................. '||count(*) filter (where rls)||E'\n'||
  '  RLS MISSING ................. '||count(*) filter (where not rls)
from t;"

head_ "Policies and tenant triggers"
q "select '  policies in public .......... '||count(*) from pg_policies where schemaname='public';"
q "
select '  tables with tenant trigger .. '||count(distinct t.tgrelid)
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
where not t.tgisinternal and pg_get_triggerdef(t.oid) ilike '%organization%';"

head_ "Grants to browser-reachable roles"
q "
select '  tables granting to anon ..... '||count(distinct table_name)
from information_schema.role_table_grants where table_schema='public' and grantee='anon';"
q "
select '  tables granting to authenticated '||count(distinct table_name)
from information_schema.role_table_grants where table_schema='public' and grantee='authenticated';"
q "
select '  anon holds DELETE/TRUNCATE on '||count(distinct table_name)
from information_schema.role_table_grants
where table_schema='public' and grantee='anon' and privilege_type in ('DELETE','TRUNCATE');"

head_ "Coverage of the repository RLS migration"
q "
with t as (
  select c.relname,
    exists(select 1 from information_schema.columns
           where table_schema='public' and table_name=c.relname and column_name='organization_id') org
  from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
  where c.relkind='r'
)
select
  '  covered by batch_1 .......... '||count(*) filter (where relname in ($COVERED))||E'\n'||
  '  NOT covered ................. '||count(*) filter (where relname not in ($COVERED))||E'\n'||
  '  tenant-scoped NOT covered ... '||count(*) filter (where org and relname not in ($COVERED))
from t;"

head_ "Largest unprotected tenant tables"
q "
select string_agg(l, E'\n' order by cnt desc) from (
  select format('  %-38s %7s rows', relname, cnt) l, cnt from (
    select c.relname,
      (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I',c.relname),false,true,'')))[1]::text::int cnt
    from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
    where c.relkind='r' and not c.relrowsecurity
      and exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name=c.relname and column_name='organization_id')
  ) s where cnt > 0 order by cnt desc limit 15
) z;"

head_ "Helper functions available for policies"
q "
select '  SECURITY DEFINER functions .. '||count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef;"
q "
select string_agg('  - '||proname, E'\n' order by proname)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
  and proname in ('has_role','is_org_admin','is_member_of_org','get_user_organization_id','can_assign_role');"

# ---------------------------------------------------------------- CSV export
if [ -n "$OUT" ]; then
  mkdir -p "$OUT"
  docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -q <<SQL > "$OUT/rls-inventory.csv" 2>/dev/null
\pset format csv
\pset tuples_only off
select
  c.relname as table_name,
  case when co.org then 'ORG' when co.unit then 'UNIT' else 'SYSTEM' end as scope,
  c.relrowsecurity as rls_enabled,
  coalesce(pol.n,0) as policies,
  coalesce(trg.n,0) as tenant_triggers,
  coalesce(ga.n,0) as anon_privileges,
  coalesce(gu.n,0) as authenticated_privileges,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I',c.relname),false,true,'')))[1]::text::int as row_count,
  (c.relname in ($COVERED)) as covered_by_batch1
from pg_class c
join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
left join lateral (
  select bool_or(column_name='organization_id') org, bool_or(column_name='unit_id') unit
  from information_schema.columns where table_schema='public' and table_name=c.relname
) co on true
left join lateral (select count(*) n from pg_policies p where p.schemaname='public' and p.tablename=c.relname) pol on true
left join lateral (select count(*) n from pg_trigger t where t.tgrelid=c.oid and not t.tgisinternal
                   and pg_get_triggerdef(t.oid) ilike '%organization%') trg on true
left join lateral (select count(*) n from information_schema.role_table_grants g
                   where g.table_schema='public' and g.table_name=c.relname and g.grantee='anon') ga on true
left join lateral (select count(*) n from information_schema.role_table_grants g
                   where g.table_schema='public' and g.table_name=c.relname and g.grantee='authenticated') gu on true
where c.relkind='r'
order by co.org desc nulls last, row_count desc;
SQL
  printf '\n  inventory written: %s/rls-inventory.csv (%s rows)\n' "$OUT" "$(( $(wc -l < "$OUT/rls-inventory.csv") - 1 ))"
fi

head_ "Verdict"
MISSING=$(q "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;")
if [ "${MISSING:-1}" = "0" ]; then
  printf '  \033[32mPASS\033[0m every table in public has RLS enabled\n\n'
else
  printf '  \033[31mFAIL\033[0m %s table(s) in public without RLS\n' "$MISSING"
  printf '        Do not expose this database on a public endpoint.\n\n'
  exit 1
fi
