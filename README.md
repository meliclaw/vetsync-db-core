<div align="center">

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/supabase/supabase/3-self-hosted-deployment)

</div>

# Self-Hosted Supabase with Docker

This is the official Docker Compose setup for self-hosted Supabase. It provides a complete stack with all Supabase services running locally or on your infrastructure.

## Getting Started

Follow the detailed setup guide in our documentation: [Self-Hosting with Docker](https://supabase.com/docs/guides/self-hosting/docker)

The guide covers:
- Prerequisites (Git and Docker)
- Initial setup and configuration
- Securing your installation
- Accessing services
- Updating your instance

## What's Included

This Docker Compose configuration includes the following services:

- **[Studio](https://github.com/supabase/supabase/tree/master/apps/studio)** - A dashboard for managing your self-hosted Supabase project
- **[Kong](https://github.com/Kong/kong)** - Kong API gateway
- **[Auth](https://github.com/supabase/auth)** - JWT-based authentication API for user sign-ups, logins, and session management
- **[PostgREST](https://github.com/PostgREST/postgrest)** - Web server that turns your PostgreSQL database directly into a RESTful API
- **[Realtime](https://github.com/supabase/realtime)** - Elixir server that listens to PostgreSQL database changes and broadcasts them over websockets
- **[Storage](https://github.com/supabase/storage)** - RESTful API for managing files in S3, with Postgres handling permissions
- **[imgproxy](https://github.com/imgproxy/imgproxy)** - Fast and secure image processing server
- **[postgres-meta](https://github.com/supabase/postgres-meta)** - RESTful API for managing Postgres (fetch tables, add roles, run queries)
- **[PostgreSQL](https://github.com/supabase/postgres)** - Object-relational database with over 30 years of active development
- **[Edge Runtime](https://github.com/supabase/edge-runtime)** - Web server based on Deno runtime for running JavaScript, TypeScript, and WASM services
- **[Logflare](https://github.com/Logflare/logflare)** - Log management and event analytics platform
- **[Vector](https://github.com/vectordotdev/vector)** - High-performance observability data pipeline for logs
- **[Supavisor](https://github.com/supabase/supavisor)** - Supabase's Postgres connection pooler

## Documentation

- **[Self-Hosting with Docker](https://supabase.com/docs/guides/self-hosting/docker)** - Setup and configuration guides
- **[Compose to UI mapping](./README.wapnet.md#compose-to-ui-mapping)** - Exact service-by-service map from compose services to the Supabase dashboard UI
- **[VetSync DB Core PRD specification](./specs/VetSync%20DB%20Core%20PRD%20specification.md)** - Safe secret generation, volume reuse, restore, Supavisor tenant routing and SQLSTATE `28P01` recovery
- **[CHANGELOG.md](./CHANGELOG.md)** - Track recent updates and changes to services
- **[versions.md](./versions.md)** - Complete history of Docker image versions for rollback reference
- **[Ask DeepWiki / Supabase](https://deepwiki.com/supabase/supabase/3-self-hosted-deployment)** - DeepWiki-generated description of self-hosted configuration
- **[CONFIG.md](./CONFIG.md)** - Configuration reference for all environment variables

## Updates

To update your self-hosted Supabase instance:

1. Review [CHANGELOG.md](./CHANGELOG.md) for breaking changes
2. Check [versions.md](./versions.md) for new image versions
3. Update `docker-compose.yml` if there are configuration changes
4. Pull the latest images: `docker compose pull`
5. Stop services: `docker compose down`
6. Start services with new configuration: `docker compose up -d`

**Note:** Consider to always backup your database before updating.

## Community & Support

For troubleshooting common issues, see:
- [GitHub Discussions](https://github.com/orgs/supabase/discussions?discussions_q=is%3Aopen+label%3Aself-hosted) - Questions, feature requests, and workarounds
- [GitHub Issues](https://github.com/supabase/supabase/issues?q=is%3Aissue%20state%3Aopen%20label%3Aself-hosted) - Known issues
- [Documentation](https://supabase.com/docs/guides/self-hosting) - Setup and configuration guides

Self-hosted Supabase is community-supported. Get help and connect with other users:

- [Discord](https://discord.supabase.com) - Real-time chat and community support
- [Reddit](https://www.reddit.com/r/Supabase/) - Official Supabase subreddit

Share your self-hosting experience:

- [GitHub Discussions](https://github.com/orgs/supabase/discussions/39820) - "Self-hosting: What's working (and what's not)?"

## Important Notes

- [Postgres](https://www.postgresql.org/) is an object-relational database system with over 30 years of active development that has earned it a strong reputation for reliability, feature robustness, and performance.
- [Realtime](https://github.com/supabase/realtime) is an Elixir server that allows you to listen to PostgreSQL inserts, updates, and deletes using websockets. Realtime polls Postgres' built-in replication functionality for database changes, converts changes to JSON, then broadcasts the JSON over websockets to authorized clients.
- [PostgREST](http://postgrest.org/) is a web server that turns your PostgreSQL database directly into a RESTful API.
- [GoTrue](https://github.com/supabase/gotrue) is a JWT-based authentication API that simplifies user sign-ups, logins, and session management in your applications.
- [Storage](https://github.com/supabase/storage-api) a RESTful API for managing files in S3, with Postgres handling permissions.
- [pg_graphql](http://github.com/supabase/pg_graphql/) a PostgreSQL extension that exposes a GraphQL API.
- [postgres-meta](https://github.com/supabase/postgres-meta) is a RESTful API for managing your Postgres, allowing you to fetch tables, add roles, and run queries, etc.
- [Envoy](https://github.com/envoyproxy/envoy) is a cloud-native, high-performance edge and service proxy.

⚠️ **The default configuration is not secure for production use.**

Before deploying to production, you must:
- [Update](https://supabase.com/docs/guides/self-hosting/docker#configuring-and-securing-supabase) all default passwords and secrets in the `.env` file
- Review and update CORS settings
- Consider setting up a secure proxy in front of self-hosted Supabase
- Review and adjust network security configuration (ACLs, etc.)
- Set up proper backup procedures

<table style="table-layout:fixed; white-space: nowrap;">
  <tr>
    <th>Language</th>
    <th>Client</th>
    <th colspan="5">Feature-Clients (bundled in Supabase client)</th>
  </tr>
  <!-- notranslate -->
  <tr>
    <th></th>
    <th>Supabase</th>
    <th><a href="https://github.com/postgrest/postgrest" target="_blank" rel="noopener noreferrer">PostgREST</a></th>
    <th><a href="https://github.com/supabase/gotrue" target="_blank" rel="noopener noreferrer">GoTrue</a></th>
    <th><a href="https://github.com/supabase/realtime" target="_blank" rel="noopener noreferrer">Realtime</a></th>
    <th><a href="https://github.com/supabase/storage-api" target="_blank" rel="noopener noreferrer">Storage</a></th>
    <th>Functions</th>
  </tr>
  <!-- TEMPLATE FOR NEW ROW -->
  <!-- START ROW
  <tr>
    <td>lang</td>
    <td><a href="https://github.com/supabase-community/supabase-lang" target="_blank" rel="noopener noreferrer">supabase-lang</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-lang" target="_blank" rel="noopener noreferrer">postgrest-lang</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-lang" target="_blank" rel="noopener noreferrer">gotrue-lang</a></td>
    <td><a href="https://github.com/supabase-community/realtime-lang" target="_blank" rel="noopener noreferrer">realtime-lang</a></td>
    <td><a href="https://github.com/supabase-community/storage-lang" target="_blank" rel="noopener noreferrer">storage-lang</a></td>
  </tr>
  END ROW -->
  <!-- /notranslate -->
  <th colspan="7">⚡️ Official ⚡️</th>
  <!-- notranslate -->
  <tr>
    <td>JavaScript (TypeScript)</td>
    <td><a href="https://github.com/supabase/supabase-js" target="_blank" rel="noopener noreferrer">supabase-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/postgrest-js" target="_blank" rel="noopener noreferrer">postgrest-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/auth-js" target="_blank" rel="noopener noreferrer">auth-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/realtime-js" target="_blank" rel="noopener noreferrer">realtime-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/storage-js" target="_blank" rel="noopener noreferrer">storage-js</a></td>
    <td><a href="https://github.com/supabase/supabase-js/tree/master/packages/core/functions-js" target="_blank" rel="noopener noreferrer">functions-js</a></td>
  </tr>
    <tr>
    <td>Flutter</td>
    <td><a href="https://github.com/supabase/supabase-flutter" target="_blank" rel="noopener noreferrer">supabase-flutter</a></td>
    <td><a href="https://github.com/supabase/supabase-flutter/tree/main/packages/postgrest" target="_blank" rel="noopener noreferrer">postgrest</a></td>
    <td><a href="https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_auth" target="_blank" rel="noopener noreferrer">supabase_auth</a></td>
    <td><a href="https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_realtime" target="_blank" rel="noopener noreferrer">supabase_realtime</a></td>
    <td><a href="https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_storage" target="_blank" rel="noopener noreferrer">supabase_storage</a></td>
    <td><a href="https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_functions" target="_blank" rel="noopener noreferrer">supabase_functions</a></td>
  </tr>
  <tr>
    <td>Swift</td>
    <td><a href="https://github.com/supabase/supabase-swift" target="_blank" rel="noopener noreferrer">supabase-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/PostgREST" target="_blank" rel="noopener noreferrer">postgrest-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Auth" target="_blank" rel="noopener noreferrer">auth-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Realtime" target="_blank" rel="noopener noreferrer">realtime-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Storage" target="_blank" rel="noopener noreferrer">storage-swift</a></td>
    <td><a href="https://github.com/supabase/supabase-swift/tree/main/Sources/Functions" target="_blank" rel="noopener noreferrer">functions-swift</a></td>
  </tr>
  <tr>
    <td>Python</td>
    <td><a href="https://github.com/supabase/supabase-py" target="_blank" rel="noopener noreferrer">supabase-py</a></td>
    <td><a href="https://github.com/supabase/postgrest-py" target="_blank" rel="noopener noreferrer">postgrest-py</a></td>
    <td><a href="https://github.com/supabase/gotrue-py" target="_blank" rel="noopener noreferrer">gotrue-py</a></td>
    <td><a href="https://github.com/supabase/realtime-py" target="_blank" rel="noopener noreferrer">realtime-py</a></td>
    <td><a href="https://github.com/supabase/storage-py" target="_blank" rel="noopener noreferrer">storage-py</a></td>
    <td><a href="https://github.com/supabase/functions-py" target="_blank" rel="noopener noreferrer">functions-py</a></td>
  </tr>
  <!-- /notranslate -->
  <th colspan="7">💚 Community 💚</th>
  <!-- notranslate -->
  <tr>
    <td>C#</td>
    <td><a href="https://github.com/supabase-community/supabase-csharp" target="_blank" rel="noopener noreferrer">supabase-csharp</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-csharp" target="_blank" rel="noopener noreferrer">postgrest-csharp</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-csharp" target="_blank" rel="noopener noreferrer">gotrue-csharp</a></td>
    <td><a href="https://github.com/supabase-community/realtime-csharp" target="_blank" rel="noopener noreferrer">realtime-csharp</a></td>
    <td><a href="https://github.com/supabase-community/storage-csharp" target="_blank" rel="noopener noreferrer">storage-csharp</a></td>
    <td><a href="https://github.com/supabase-community/functions-csharp" target="_blank" rel="noopener noreferrer">functions-csharp</a></td>
  </tr>
  <tr>
    <td>Go</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/postgrest-go" target="_blank" rel="noopener noreferrer">postgrest-go</a></td>
    <td><a href="https://github.com/supabase-community/gotrue-go" target="_blank" rel="noopener noreferrer">gotrue-go</a></td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/storage-go" target="_blank" rel="noopener noreferrer">storage-go</a></td>
    <td><a href="https://github.com/supabase-community/functions-go" target="_blank" rel="noopener noreferrer">functions-go</a></td>
  </tr>
  <tr>
    <td>Java</td>
    <td>-</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/gotrue-java" target="_blank" rel="noopener noreferrer">gotrue-java</a></td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/storage-java" target="_blank" rel="noopener noreferrer">storage-java</a></td>
    <td>-</td>
  </tr>
  <tr>
    <td>Kotlin</td>
    <td><a href="https://github.com/supabase-community/supabase-kt" target="_blank" rel="noopener noreferrer">supabase-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Postgrest" target="_blank" rel="noopener noreferrer">postgrest-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Auth" target="_blank" rel="noopener noreferrer">auth-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Realtime" target="_blank" rel="noopener noreferrer">realtime-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Storage" target="_blank" rel="noopener noreferrer">storage-kt</a></td>
    <td><a href="https://github.com/supabase-community/supabase-kt/tree/master/Functions" target="_blank" rel="noopener noreferrer">functions-kt</a></td>
  </tr>
  <tr>
    <td>Ruby</td>
    <td><a href="https://github.com/supabase-community/supabase-rb" target="_blank" rel="noopener noreferrer">supabase-rb</a></td>
    <td><a href="https://github.com/supabase-community/postgrest-rb" target="_blank" rel="noopener noreferrer">postgrest-rb</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <tr>
    <td>Rust</td>
    <td>-</td>
    <td><a href="https://github.com/supabase-community/postgrest-rs" target="_blank" rel="noopener noreferrer">postgrest-rs</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <tr>
    <td>Godot Engine (GDScript)</td>
    <td><a href="https://github.com/supabase-community/godot-engine.supabase" target="_blank" rel="noopener noreferrer">supabase-gdscript</a></td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
    <td>-</td>
  </tr>
  <!-- /notranslate -->
</table>

## License

This repository is licensed under the Apache 2.0 License. See the main [Supabase repository](https://github.com/supabase/supabase) for details.
