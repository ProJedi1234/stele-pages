# stele

Publish an HTML file, get a readable link back.

```
$ curl -X POST localhost:8080/pages \
    -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
    -H "Content-Type: text/html" \
    --data-binary @index.html
{"url":"http://localhost:8080/radiant-surf-gecko","slug":"radiant-surf-gecko"}
```

Anyone can then load `/radiant-surf-gecko` and get the page. Pages live in Postgres, so
the server holds no state and can be restarted or moved freely.

A *stele* is the stone slab you put up in public for people to read — which is the job.

## The identifier

Slugs are three words drawn from three curated pools, one per part of speech:

    adjective  -  nature noun  -  creature/object noun
      radiant       surf            gecko
      quiet         cedar           otter
      brisk         harbor          compass

Keeping each slot to its own pool is what makes every combination read as a phrase
instead of three adjacent words. Pools are 253 / 208 / 224 words, so:

| `STELE_SLUG_WORDS` | Shape                       | Combinations  |
| ------------------ | --------------------------- | ------------- |
| `3` (default)      | `quiet-cedar-otter`         | 11,787,776    |
| `4`                | `quiet-mossy-cedar-otter`   | 2,982,307,328 |

Slugs are drawn at random, not derived from a row counter, so one slug never reveals
another. On the rare collision the server simply redraws (five attempts, then 503).

### Slugs are pretty, not secret

**A three-word slug is guessable by an attacker who is willing to scan.** 11.8M is a
large number for a human and a small one for a script. Anyone who can reach the server
can eventually enumerate every page on it.

That's a fine trade for publishing pages meant to be shared. It is *not* a fine trade if
a page's contents should stay private — an unguessable URL would be doing access-control
work it can't do at this size. If you need that, set `STELE_SLUG_WORDS=4` (~3 billion,
meaningfully harder) and treat even that as obscurity rather than security. Real privacy
needs an auth check on reads, which this server deliberately does not have.

## Running it locally

```sh
cp .env.example .env
openssl rand -hex 32          # put this in STELE_UPLOAD_TOKEN
docker compose up -d          # app + Postgres; working at localhost:8080
```

While actually writing code, run the database in Docker and the app on the host instead
— a Swift change is a ~10s rebuild, versus rebuilding the image on every edit:

```sh
docker compose up -d postgres
set -a && . ./.env && set +a
swift run stele
```

The schema is created on boot; there's no separate migrate step. Run the tests with
`swift test`.

### The two compose files

| File                        | Contains        | For                                         |
| --------------------------- | --------------- | ------------------------------------------- |
| `docker-compose.yml`        | app + Postgres  | Local development. Throwaway database.      |
| `docker-compose.deploy.yml` | app only        | Deployment. Database lives elsewhere.       |

They're deliberately not the same file. The deployment stack has no Postgres service:
bundling one would put production data in a container volume on whichever machine
happens to run the app, which is rarely the machine you chose for durable storage. See
"Deploying" below.

## API

| Route              | Auth   | Behaviour                                              |
| ------------------ | ------ | ------------------------------------------------------ |
| `GET /`            | none   | Usage page                                             |
| `GET /healthz`     | none   | `ok`                                                   |
| `GET /:slug`       | none   | The stored page, or a 404 page                         |
| `POST /pages`      | bearer | Stores the request body, returns `{slug, url}` as `201` |

`POST /pages` takes the page as the raw request body. Add `?slug=my-page` to choose the
name yourself — it's validated by the same rules as a generated one and returns `409` if
taken. Accepted content types are `text/html` (default), `text/plain`, `text/css`, and
`text/markdown`; anything else is `415`.

Custom slugs are lowercase letters, digits and single interior hyphens, 3–64 characters.
Names the server uses for itself (`pages`, `healthz`, …) are rejected rather than
accepted-then-shadowed.

## Configuration

Everything is environment variables, read once at startup — see `.env.example` for the
annotated list. A bad value stops the process immediately with a message naming the
variable, rather than surfacing later as a connection error.

`DATABASE_URL` is a standard libpq URL, including `?sslmode=`, so switching databases is
a one-line change.

## Deploying

Create the role and database on your Postgres host first:

```sql
CREATE ROLE stele LOGIN PASSWORD 'pick-something-strong';
CREATE DATABASE stele OWNER stele;
```

Then, on the host that will run the app:

```sh
cat > .env <<'EOF'
DATABASE_URL=postgres://stele:pick-something-strong@DB_HOST:5432/stele
STELE_UPLOAD_TOKEN=<openssl rand -hex 32>
STELE_BASE_URL=https://stele.example.com
EOF

docker compose -f docker-compose.deploy.yml up -d --build
```

Nothing else changes — the schema bootstraps on first boot exactly as it does locally.
All three of those variables are required and the stack refuses to start without them,
rather than defaulting to something that would quietly be wrong.

**Point `DATABASE_URL` at a host whose storage you trust.** Development machines often
run with durability tradeoffs that are fine for rebuildable data and not fine for the
only copy of something — writes the database reports as committed can be lost on a power
cut. The local `docker compose` database is for development only.

## Before this faces the internet

The current shape is built for a trusted LAN. Three things need attention first:

- **Stored pages are same-origin.** An uploaded page's JavaScript runs on the server's
  own domain. There's nothing to steal today — no cookies, no session, no authenticated
  reads — but it stops being harmless the moment this server grows any of those. Serving
  pages from a separate domain to the API is the durable fix.
- **One shared upload token.** No per-user attribution and no revocation short of
  rotating it for everyone.
- **No rate limiting.** Reads are unauthenticated and unmetered, which is what makes the
  enumeration note above practical rather than theoretical.
