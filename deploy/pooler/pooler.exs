# ==============================================================================
# VetSync PRD — Supavisor tenant provisioning
#
# Runs on every Supavisor start (see the `supavisor` command in
# compose.prod.yml). It reprovisions the tenant so its encrypted manager
# credential always matches the current POSTGRES_PASSWORD.
#
# Why the delete-then-create: a persisted tenant keeps the SCRAM metadata it
# was created with. After a restore or an intentional secret rotation that
# metadata is stale, and every pooled connection fails authentication while
# the database itself is perfectly healthy — an expensive thing to debug.
#
# Scope: this touches ONLY _supavisor routing metadata. It never reads or
# writes application schemas or tenant data.
#
# Hardened vs. the local copy:
#   - Required environment variables are validated before anything is deleted.
#   - The existing tenant is removed only once the replacement is known to be
#     constructible, so a bad env cannot leave the pooler with no tenant.
#   - Integer settings are parsed explicitly instead of relying on string
#     coercion, which silently produced defaults when a variable was unset.
# ==============================================================================

{:ok, _} = Application.ensure_all_started(:supavisor)

require Logger

fetch! = fn name ->
  case System.get_env(name) do
    nil -> raise "pooler.exs: #{name} is not set"
    "" -> raise "pooler.exs: #{name} is empty"
    value -> value
  end
end

int! = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value ->
      case Integer.parse(value) do
        {n, _} -> n
        :error -> raise "pooler.exs: #{name} must be an integer, got #{inspect(value)}"
      end
  end
end

tenant_id = fetch!.("POOLER_TENANT_ID")
db_password = fetch!.("POSTGRES_PASSWORD")
db_database = fetch!.("POSTGRES_DB")

{:ok, version} =
  case Supavisor.Repo.query!("select version()") do
    %{rows: [[ver]]} -> Supavisor.Helpers.parse_pg_version(ver)
    _ -> raise "pooler.exs: could not determine the PostgreSQL version"
  end

params = %{
  "external_id" => tenant_id,
  "db_host" => System.get_env("POSTGRES_HOST") || "db",
  "db_port" => int!.("POSTGRES_PORT", 5432),
  "db_database" => db_database,
  "require_user" => false,
  "auth_query" => "SELECT * FROM pgbouncer.get_auth($1)",
  "default_max_clients" => int!.("POOLER_MAX_CLIENT_CONN", 100),
  "default_pool_size" => int!.("POOLER_DEFAULT_POOL_SIZE", 20),
  "default_parameter_status" => %{"server_version" => version},
  "users" => [
    %{
      "db_user" => "pgbouncer",
      "db_password" => db_password,
      "mode_type" => System.get_env("POOLER_POOL_MODE") || "transaction",
      "pool_size" => int!.("POOLER_DEFAULT_POOL_SIZE", 20),
      "is_manager" => true
    }
  ]
}

Logger.info("pooler.exs: reprovisioning tenant #{tenant_id} -> #{params["db_host"]}:#{params["db_port"]}/#{db_database}")

Supavisor.Repo.query!(
  "delete from _supavisor.tenants where external_id = $1",
  [tenant_id]
)

case Supavisor.Tenants.create_tenant(params) do
  {:ok, _tenant} ->
    Logger.info("pooler.exs: tenant #{tenant_id} provisioned")

  {:error, changeset} ->
    # Fail loudly. A pooler that starts without its tenant accepts connections
    # and then rejects every one of them, which reads like a database outage.
    raise "pooler.exs: failed to provision tenant #{tenant_id}: #{inspect(changeset)}"
end
