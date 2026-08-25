# justfile — the commands from the README's "Running it locally", in one place.
# `just` on its own lists them.
#
# Every recipe is a thin wrapper over `swift` or `docker compose`. There is no build
# logic here: the schema still migrates on boot, so there is nothing between a build
# and a running server for a recipe to own.

set shell := ["bash", "-uc"]

# Compose reads .env for STELE_UPLOAD_TOKEN and friends, and .env is gitignored — so a
# git worktree has none and every compose command fails on the `:?` in the compose file.
# Point this at the main checkout's copy rather than making a second one that drifts:
#   STELE_ENV_FILE=~/repos/stele-pages/.env just up

env_file := env('STELE_ENV_FILE', justfile_directory() / ".env")

# The maintenance database, not `stele`: the suite creates and drops a throwaway schema
# per test and must never be dropping things in a database of its own. Deliberately not
# DATABASE_URL, so pointing the server at a database never points the suite at it too.

test_database_url := env('STELE_TEST_DATABASE_URL', "postgres://stele:stele_dev_password@localhost:5432/postgres")

[private]
default:
    @just --list --unsorted

# Debug build.
build:
    swift build

# The hermetic suite; takes a --filter argument. Needs no database.
test *filter:
    swift test {{ if filter == "" { "" } else { "--filter " + filter } }}

# The same, plus the migration suite against the Postgres in Docker.
test-db *filter: db
    @echo "creating and dropping schemas in: {{ test_database_url }}"
    STELE_TEST_DATABASE_URL={{ quote(test_database_url) }} swift test {{ if filter == "" { "" } else { "--filter " + filter } }}

# Postgres in Docker, the app on the host — the one to use while writing code, since a
# Swift change is a ~10s rebuild versus rebuilding the image on every edit.

# Run the server on the host against the Docker database.
run: db
    set -a && . {{ quote(env_file) }} && set +a && swift run stele

# Waited on rather than a bare `up -d`, which returns while Postgres is still
# initialising; the app then crash-loops against a connection that never appears.

# Start the database alone.
db:
    docker compose --env-file {{ quote(env_file) }} up -d --wait postgres

# Start the whole stack in Docker, at localhost:8080.
up:
    docker compose --env-file {{ quote(env_file) }} up -d --build

# Stop the stack. Leaves the database volume alone.
down:
    docker compose --env-file {{ quote(env_file) }} down

# Follow the stack's logs.
logs:
    docker compose --env-file {{ quote(env_file) }} logs -f

# Drop the build directory's SwiftPM state.
clean:
    swift package clean
