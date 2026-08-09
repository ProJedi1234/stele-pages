# stele

Publish an HTML file, get a readable link back. It expires in a week unless you say
otherwise.

```
$ stele publish index.html
http://localhost:8080/radiant-surf-gecko
```

The `stele` CLI ([stele-cli](https://github.com/ProJedi1234/stele-cli)) holds the
credential so that whoever runs it — usually an agent — never has to. Every write now has a
command in front of it — `stele publish`, `stele update`, `stele amend` and `stele delete`
for `POST`, `PUT`, `PATCH` and `DELETE` — so nothing an agent does routinely needs a token
in hand. Underneath it is an ordinary HTTP request, and curl still works if you are holding
one yourself:

```
$ curl -X POST "localhost:8080/pages?ttl=never" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: text/html" \
    --data-binary @index.html
{"slug":"radiant-surf-gecko","url":"http://localhost:8080/radiant-surf-gecko","expires":null}
```

Anyone can then load `/radiant-surf-gecko` and get the page, for as long as the page
lives — see "How long a page lives". Pages live in Postgres, so the server holds no state
and can be restarted or moved freely.

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
another. On the rare collision the server simply redraws (five attempts, then 503). A slug
freed by an expiry goes back into the pool and can be drawn or claimed again — expired
pages leave no tombstone behind them.

### Slugs are pretty, not secret

**A three-word slug is guessable by an attacker who is willing to scan.** 11.8M is a
large number for a human and a small one for a script. Anyone who can reach the server
can eventually enumerate every page on it.

That's a fine trade for publishing pages meant to be shared. It is *not* a fine trade if
a page's contents should stay private — an unguessable URL would be doing access-control
work it can't do at this size. If you need that, set `STELE_SLUG_WORDS=4` (~3 billion,
meaningfully harder) and treat even that as obscurity rather than security. Real privacy
needs an auth check on reads, which this server deliberately does not have.

Expiry adds nothing to that risk. A page past its deadline answers with the byte-identical
404 that a malformed, reserved or never-published slug answers with, so a scanner cannot
learn that a name *used to* be a page — which would otherwise hand it the publication
history of the namespace for free.

### The landing page lists what is published

`GET /` shows the twenty most recently published live pages by name, unauthenticated, to
anybody who loads it. That is a deliberate reversal of the "willing to scan" framing above:
the live half of the namespace is no longer merely enumerable, it is *enumerated*, and the
cost of obtaining it drops from a scanning campaign to one request.

It is worth being exact about what that does and does not give up, because the two are
easily conflated:

- It does not weaken any access control, because there was none. A page was always readable
  by anyone holding — or guessing — its slug.
- It does not expose expired pages. The index carries the same `expires_at > now()`
  predicate every read does, so the publication history the uniform 404 protects is still
  not on offer. What the index shows is exactly the set of pages that a `GET` would serve.
- It does remove obscurity as a stopgap. "Nobody will bother scanning for it" was never a
  security property, but it was a real amount of friction, and this deletes it. A page whose
  *existence* is sensitive — never mind its contents — does not belong on this server, and
  now visibly so.

There is no unlisted option, and adding one would be a schema change plus a query parameter
plus a default to argue about. If this deployment wants the index gone, the honest lever is
to delete the call in `buildRouter`'s `GET /` handler rather than to add a flag that makes
"is this page listed?" a thing every publisher has to think about.

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

The schema is an ordered, append-only list of migrations in code. Whatever a database
hasn't applied yet runs on boot, under a Postgres advisory lock — so there's still no
separate migrate step, and two instances starting at once are safe. See "Changing the
schema" below.

Run the tests with `swift test`. That run is hermetic and needs no database. The suite
that exercises the migration runner against a real Postgres is gated on a separate
variable:

```sh
docker compose up -d postgres
STELE_TEST_DATABASE_URL=postgres://stele:stele_dev_password@localhost:5432/postgres swift test
```

It creates and drops a throwaway schema per test on whichever cluster you point it at.
The variable is deliberately not `DATABASE_URL`, so pointing the server at a database
never points a suite that drops things at it too.

### Changing the schema

`PageStore.migrations` is an ordered, append-only list. To change the schema, append a
`Migration` with the next version and its statements; never edit a version that has
shipped, because it has already run on databases you don't control and nothing would
detect the divergence. On boot the runner reads `schema_migrations`, applies whatever is
missing in version order, and commits each migration together with the row recording it —
so a step is either fully applied and recorded, or not applied at all.

One SQL command per array element, literal text only: an interpolation becomes a bind
parameter, and DDL can't take binds. Statements aren't limited to DDL — because a version
runs exactly once, a data backfill belongs in a migration too. `CREATE INDEX CONCURRENTLY`
doesn't, because each migration runs inside a transaction.

Version 1 is the original schema written with `IF NOT EXISTS`, so a database created
before there was a version table simply records version 1 and carries on. Nothing is
dumped or restored.

Version 2 is the page-expiry column, and it is what every later migration should look
like: a versioned step with no `IF NOT EXISTS`, rather than another idempotent `ALTER`
accumulating in a bootstrap function. Only version 1 needs the conditional forms, because
only version 1 describes a schema that already existed before the runner did. Version 2
adds `expires_at` as nullable with no default, backfills every row already in the table to
seven days out, then builds a *partial* index on it. It is also the example of why a
backfill belongs in a migration rather than in application code: the statement is only
accurate in the one moment it runs, when a `NULL` still provably means "published before
expiry existed" rather than "published with `?ttl=never`".

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
| `GET /`            | none   | Usage page, and an index of recently published pages   |
| `GET /healthz`     | none   | `ok`                                                   |
| `GET /:slug`       | none   | The stored page, or a 404 page if it's absent or expired |
| `GET /assets/stele.css` | none | The shared stylesheet (see "A shared look")         |
| `GET /skill`       | none   | The publish skill, as Markdown (see "Teaching an agent to publish") |
| `POST /pages`      | `publish` | Stores the request body, takes `?slug=` and `?ttl=`, returns `{slug, url, expires}` as `201` |
| `PUT /pages/:slug` | `publish` | Replaces a stored page's body and content type, returns `{slug, url, expires}` as `200` |
| `PATCH /pages/:slug` | `publish` | Renames a page with `?slug=` and retimes it with `?ttl=`, leaving its contents alone, returns `{slug, url, expires}` as `200` |
| `DELETE /pages/:slug` | `publish` | Removes a stored page and frees the slug, returns `204` |
| `GET /admin/whoami` | any credential | Reports the credential presented — name, scopes, expiry, last use — and never a token |
| `POST /admin/clients` | `admin` | Mints a credential, returns `{token, client}` as `201`. The token is shown once and never again |
| `GET /admin/clients` | `admin` | Lists credentials — names, scopes, last use, revocation — and never a token |
| `DELETE /admin/clients/:name` | `admin` | Revokes one, returns the credential as `200`. The row stays |

The auth column names the *scope* a bearer token has to carry; see "Credentials" below.
`GET /admin` itself answers the same uniform 404 as any other miss, so nothing on the
public read surface advertises that the credential routes are there.

`GET /admin/whoami` is the one route under `/admin` that requires no scope, only a valid
credential. It is what `stele auth status` asks and what `stele auth login` checks before
writing a credential to disk — both of which a publish-only agent runs — so gating it on
`admin` would refuse the one question a working agent credential most needs answered. It
returns the same credential record the listing does, and like the listing it carries
neither the token nor its digest.

`POST /pages` takes the page as the raw request body, up to `STELE_MAX_PAGE_BYTES`
(default 1 MiB; larger is `413`). Add `?slug=my-page` to choose the name yourself — it's
validated by the same rules as a generated one, returning `400` if invalid and `409` if
taken. Add `?ttl=` to choose how long it lives, described below. Accepted content types
are `text/html` (default), `text/plain`, `text/css`, and `text/markdown`; anything else is
`415`. An empty body, a non-UTF-8 one, a NUL byte, an invalid slug and an invalid `ttl`
are each `400`, a missing or wrong bearer token is `401`, and if five random draws in a
row collide with existing slugs the server gives up with `503` rather than retrying
forever.

`PUT /pages/:slug` replaces an existing page's body and content type, and shares POST's
request semantics — the same size limit (`413`), content-type allowlist (`415`), empty or
non-UTF-8 body (`400`), and bearer token (`401`) — with one deliberate difference:
omitting `Content-Type` keeps the page's stored type instead of defaulting to HTML, so a
re-upload that forgets the header can't silently turn a stylesheet into a page browsers
refuse to apply. It reports the page's `expires` and never moves it, for the same reason it
never touches `created_at`, and a `?ttl=` on this verb is a `400` rather than a value
quietly dropped — accepting `?ttl=never` with a `200` and changing nothing would be the one
silent default the `POST` parser exists to prevent. The slug in the path obeys the
same grammar as a custom slug below; malformed or reserved is `400` rather than the
public `404`, because this side of the API is behind the upload token and has nothing to
hide from its caller. A well-formed slug with no *live* page at it is `404` — absent, or
expired and not yet cleaned up: `PUT` never creates, so publishing a new page is always
`POST`.

`PATCH /pages/:slug` changes the two things about a page that used to be fixed at
publication: where it lives and how long it lives. `?slug=` moves it to a new name and
`?ttl=` gives it a new deadline; either alone, or both in one request. It reads no body and
touches none — the page's contents, its content type, its `created_at` and its `client_id`
all survive, and that last one is the deliberate difference from `PUT`: that column records
who wrote the bytes currently being served, and an amendment writes no bytes.

A separate verb rather than `?ttl=` on `PUT`, because the two operations are independent.
Extending a deadline shouldn't require re-uploading a megabyte, and replacing a body
shouldn't be an opportunity to silently move a deadline — so `PUT`'s refusal of `?ttl=`
stays exactly as it was, and remains correct: *a replacement* still cannot retime a page.
This is not a replacement.

An amendment that amends nothing — neither parameter present — is a `400` rather than a
`200` over an untouched page. The shape of that mistake is a misspelled parameter, and a
success would confirm it as having worked. `?ttl=` obeys the same grammar it does on `POST`
and is measured from *now*, so `?ttl=30` means thirty more days rather than thirty from
publication; the one difference is that an absent `?ttl=` here means "leave it alone" rather
than "seven days", which is the whole reason `PageExpiry` is an enum and not a `Date?`. A
new slug is validated by `Slug(custom:)` exactly as `POST`'s is (`400` if invalid, including
reserved names), a name held by another row is `409`, and renaming a page to the name it
already has is a successful no-op. As with `PUT` and `DELETE`, a well-formed slug with no
*live* page at it is `404` — so `?ttl=never` cannot resurrect an expired page, which is the
one temptation this predicate exists to refuse.

**A rename is a move, and the old name goes back into the pool** — the same bargain the
delete strikes, argued out below. No redirect, no tombstone: the moment it commits, the old
URL serves the ordinary 404 and the name can be claimed again or drawn by the generator.
The alternative is a permanent table of retired names plus a lookup on every read, and a
`301` would also leak that a name used to be a page, which is exactly what the uniform 404
exists to prevent. A page whose link is already out in the world should be updated with
`PUT`, not renamed.

`DELETE /pages/:slug` removes the page and answers `204` with an empty body. There is no
`{slug, url}` to return — the URL that payload would carry now leads to the 404 page, and
handing back a dead link on a success response is worse than saying nothing. No request
body is read at all, so the size limit and the content-type allowlist have nothing to
apply to and neither `413` nor `415` can come back from this route; a `Content-Type` sent
anyway is ignored rather than rejected. Malformed or reserved is `400` and a well-formed
slug with no page at it is `404`, on the same reasoning as `PUT`: this side of the API is
behind the upload token and has nothing to hide from its caller, so a delete that removed
nothing says so instead of returning the idempotent `204` that would let a script delete a
typo and be told it worked.

An *expired* page is one of the slugs with no page at it. The delete carries the same
deadline predicate the reads and `PUT` do, so a `DELETE` aimed at a page that has passed its
`?ttl=` is a `404` even while the row is physically still there awaiting reclamation — the
write surface and the read surface agree on which pages exist, and answering `204` would
claim credit for removing something every reader already treats as gone. The row is left
for the next upload's reclamation rather than swept up here, so `delete` has exactly one
job. The practical consequence for a caller: you never need to delete a page to make it
expire, and a tidy-up pass over pages you published last week will earn a `404` each.

**The delete is hard, and the slug goes back into the pool.** The row is gone; nothing is
kept to mark the name as spent, so a later `POST ?slug=` can ask for it and the random
generator can draw it — which means a link that has already been shared may one day
resolve to somebody else's page. That is the trade, taken deliberately rather than
conceded: the alternative is a tombstone, which buys link stability by growing a table of
names nobody may ever use again and a `WHERE deleted_at IS NULL` on every read after it,
in exchange for protecting URLs that this server already treats as guessable rather than
secret. Deleting is the operation for giving a name up. A page whose link is out in the
world and must keep pointing somewhere sensible should be replaced with `PUT`, which never
lets go of the name.

Custom slugs are lowercase letters, digits and single interior hyphens, 3–64 characters.
Names the server uses for itself (`pages`, `healthz`, …) are rejected rather than
accepted-then-shadowed.

### Credentials

Every writer gets its own token. A credential is a row in `clients` — a name, a SHA-256
of the token, an array of scopes, and optional expiry and revocation timestamps — and the
token itself exists in plaintext exactly once, in the `201` that minted it. The server
stores only the digest and cannot produce it again, so a caller that loses it mints a
replacement rather than looking it up.

Scopes are what make revocation work. An agent's credential carries `publish` and nothing
else, so a leaked one can deface pages — bad, bounded, recoverable from a re-publish — but
it cannot reach `POST /admin/clients` to mint itself a second credential and revoke yours.
`admin` is the operator's scope and no agent holds it. A valid credential used outside its
scopes is `403`, not `401`: it is working exactly as issued, and answering `401` would send
someone to rotate a token whose only problem is that it was never allowed to do this.

Every *rejected* credential, on the other hand, gets one byte-identical `401`. Unknown,
revoked and expired are three facts a caller probing for a valid token learns none of —
the README's licence to return distinguishing errors applies to callers already behind the
token, and this one is not. A missing `Authorization` header keeps its own message, because
a caller who presented nothing has learned nothing.

**`STELE_UPLOAD_TOKEN` is now the admin credential, and it can no longer publish.** It
resolves to a synthesised client carrying `admin` alone, which is the bootstrap: minting
the first per-client credential otherwise needs a credential you cannot yet have. It stays
required and defaultless, and it moves out of every agent's environment into one
operator's:

```sh
curl -X POST "$STELE/admin/clients" \
    -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"claude-code","scopes":["publish"],"expiresIn":7776000}'
```

`scopes` defaults to `["publish"]` and `expiresIn` is seconds from now, absent meaning no
expiry and anything past a century being a `400` — a `timestamptz` is microseconds in an
`Int64`, and a date far enough out is not a value the driver refuses but one it traps on.
Revoking is `DELETE /admin/clients/:name`; it keeps the first `revoked_at` rather than
moving it on a retry, and the row is never deleted — "which did I revoke, and when?" is the
question the listing exists to answer.

Rotating a credential is revoke, then mint again under the same name. Names are unique
among *live* credentials only: a revoked row keeps its name in the listing without
reserving it, so `claude-code` stays `claude-code` across a rotation instead of becoming
`claude-code-2`. Uniqueness still holds where it matters — there is at most one live
credential per name, which is what keeps `DELETE /admin/clients/:name` unambiguous, and it
always takes the live one.

Every write records the credential that made it in `pages.client_id`, on `POST` and on
`PUT` alike — the column says who wrote the bytes currently being served, so replacing a
page re-attributes it rather than leaving the original publisher credited for content they
did not write. Attribution is never served: `GET /:slug` answers with the page, and who
published it is the operator's question.

Pages published before any of this, or by the shared token, carry `client_id IS NULL`.
There was no honest owner to invent for them — the shared token is synthesised rather than
stored, so it has no row for a foreign key to point at.

### Clients, and the version gate

Writes are expected to come from [stele-cli](https://github.com/ProJedi1234/stele-cli),
which stores the credential in a `0600` file and never prints it. That is the whole point
of the split: the agent runs `stele publish page.html`, and the secret never enters its
context.

The CLI sends `User-Agent: stele-cli/<version>` on every write, and a build older than the
server's `minimumCLIVersion` gets `426 Upgrade Required` with the required version and the
reinstall command in the body — a contract mismatch that announces itself and names its own
fix, instead of surfacing later as a field nobody could decode. **A request with no such
`User-Agent` is never gated**, so curl keeps working; the header is a compatibility signal,
not a security control, and nothing behind it assumes a minimum client. `minimumCLIVersion`
lives in `Sources/SteleCore/SteleCLI.swift` alongside the clone URL and the install
commands, which are the only facts this repository hardcodes about that one — and the
publish skill interpolates all of them rather than restating any.

### How long a page lives

**Pages are ephemeral by default.** A `POST` with no `?ttl=` expires 7 days after it is
published; permanence is the deliberate opt-out, not the default.

| Query        | Lifetime                                   |
| ------------ | ------------------------------------------ |
| omitted      | 7 days                                     |
| `?ttl=30`    | 30 days; any whole number from 1 to 36500  |
| `?ttl=never` | Never expires                              |

Anything else — `0`, a negative, `7.5`, an empty value, a count past the maximum — is a
`400`. Nothing is silently rounded or defaulted: a rejected `ttl` means the page was not
published at all, because a caller who mistyped a lifetime and got a week-long page would
not find out until the link died. The upper bound exists because an unbounded day count is
`Date` arithmetic waiting to overflow, and because "effectively never" should be spelled
`never`.

Every write reports the result as an `expires` field: an RFC 3339 instant in UTC, or JSON
`null` for a page that never expires. It is always present — an absent key would read as
"the server has no opinion", and it always has one.

**A deadline is fixed for the page's body but not for the page.** `PUT` cannot move it, and
refuses `?ttl=` with a `400` rather than accepting one and changing nothing; `PATCH` exists
to move it, and is the only verb that does. The distinction is that a replacement is new
contents at an old address — if editing extended the deadline, a link's lifetime would
depend on how often somebody happened to touch it — whereas an amendment is an explicit
request about the deadline itself. A `PATCH ?ttl=` is measured from the moment of the
request, not from `created_at`, so it grants the full lifetime asked for rather than
whatever remains of it.

The default is the part worth arguing about, so: a page server whose links all last
forever accumulates every draft, preview and one-off anybody ever published, and nothing
about a link tells you afterwards which it was. Making the common case temporary costs one
query parameter on the pages that matter, and nothing at all on the ones that don't.

Expiry is enforced in two places, for two different reasons:

- **On read, for correctness.** The fetch query treats a page past its deadline as absent,
  so it stops being served at exactly the right moment regardless of cleanup — and it 404s
  with the same bytes every other miss does.
- **On write, to reclaim.** A `POST` and a `PATCH` each delete expired rows before doing
  anything else, which is what returns their slugs to the pool — those are the two verbs
  that need a name freed *now*, one to claim it and one to move onto it. `PUT` and `DELETE`
  address a name that already exists and reclaim nothing. A partial index
  (`WHERE expires_at IS NOT NULL`) keeps that cheap, since permanent pages never enter it.
  There is no cron and no scheduler: cleanup frequency scales with usage, and an idle
  server holding invisible expired rows is fine, because nothing can read them anyway.

A `NULL` expiry means "never expires", and that is the only thing it means: it is what
`?ttl=never` stores, and nothing else produces one.

**Pages published before this feature existed are not exempt.** Migration 2 backfills them
in the same breath as it adds the column, so they expire seven days after the upgrade runs.
That backfill has to live in that migration and nowhere else — one statement earlier the
column did not exist, so every `NULL` it sees is provably a pre-expiry page, whereas the
same `UPDATE` written any later could not tell those apart from a page whose author asked
for `never`. The interval is measured from the migration rather than from `created_at`,
because a page older than the default would otherwise arrive with a deadline already behind
it and be deleted by the very next upload — a feature meant to bound storage would open by
destroying the archive. Everything already published gets one full lifetime from the
upgrade, and anything worth keeping should be re-published with `?ttl=never` inside that
window.

Expired slugs return to the pool. Once the row is deleted the generator may draw the name
again, or a caller may claim it with `?slug=`. There are no tombstones: a name that expired
is a name that is free — and the same is true of one that was deleted, or vacated by a
`PATCH ?slug=`. Three ways to free a name, one rule about what happens next.

### A shared look

Pages published here can look like they belong together without anyone copying a
`<style>` block between them. One line in the `<head>` is the whole integration:

```html
<link rel="stylesheet" href="/assets/stele.css">
```

**Plain semantic HTML is styled with no classes at all** — headings, paragraphs, lists,
links, `code`, `pre`, tables, quotes, images. That is the important half: a page written
by someone who never read this section still comes out looking like the rest of the
server. The classes are opt-in extras for the handful of shapes HTML has no element for:

| Class                       | For                                                        |
| --------------------------- | ---------------------------------------------------------- |
| `.card`                     | A bordered surface panel around a title and a few lines     |
| `.grid`                     | A row of cards that rewraps itself; no breakpoints to pick  |
| `.scroll`                   | Wraps a too-wide table so it scrolls instead of squeezing    |
| `.callout`                  | A tinted aside with an accent left border                   |
| `.badge`                    | A small inline pill for a status, an HTTP method or a tag   |
| `.muted`                    | Secondary text — a subtitle, a caption, an aside            |
| `body.narrow` / `body.wide` | A short centred message page; or one carrying wide content  |

`.callout` and `.badge` share one tone vocabulary, added as a second class: `note` (the
default), `ok`, `warn`, `danger` — so `<div class="callout warn">` and
`<span class="badge ok">`. The two body modifiers go on the `<body>` element itself,
since what they change is the page's measure.

`.scroll` is the one class worth reaching for even on an otherwise plain page. A bare
`<table>` is styled — rounded frame, shaded head, alternating rows — but it can only
shrink to fit, so on a phone a table of any width degrades into columns broken across
three lines each. Wrapping it (`<div class="scroll"><table>…</table></div>`) lets it keep
its natural width and scroll inside the frame instead. Scrolling genuinely needs the
extra element: one box has to stay pinned to the page width while the other is free to be
wider than it, and a lone `<table>` cannot be both.

Code blocks get their colour the same opt-in way, and with no highlighter: the server
runs no parser and serves no JavaScript. The author wraps tokens in spans while writing
the snippet — `tok-kw`, `tok-str`, `tok-num`, `tok-fn`, `tok-type`, `tok-com` — which an
agent, the usual author here, does more reliably than a regex-based highlighter would
have. Anything left unwrapped keeps the default text colour, so a partially marked-up
snippet degrades to plain code rather than to anything broken.

Dark mode needs nothing from an author. Every colour comes from a `--stele-*` custom
property and a single `prefers-color-scheme` block reassigns those properties, so a page
that uses the classes is dark-mode-correct for free rather than carrying a second copy of
its own colours to keep in step. The same indirection is how you retheme without forking:
override the tokens in your own page — `:root { --stele-accent: #7c3aed; }` — instead of
restating the rules. The server's own landing and 404 pages link this sheet and carry no
CSS of their own, so it is the same stylesheet in use on every deploy, not a sample.

**There is no versioned path, and that is a real tradeoff.** `/assets/stele.css` mutates
in place: editing it restyles every page linking it, which is exactly the point — it is
how a fleet of already-published pages gets a fix — and it is also the risk. It is served
`no-cache` with an ETag, so a browser revalidates rather than pinning a stale copy, which
means a change lands on the next load whether the author wanted it or not. A page whose
appearance must never change should carry its own `<style>` and link nothing; so should
one that inlines overrides fitted to today's rules. That is the deal, accepted knowingly,
until it first bites.

Serving something at a fixed path costs nothing on the enumeration front: `/assets` is a
documented, server-owned prefix outside the single-segment slug namespace, and `GET /assets`
itself answers the same uniform 404 as every other miss, so a scanner that finds it learns
only what this README already told it. A deeper miss like `/assets/nope.css` gets the
framework's own 404 rather than the uniform page — a two-segment path can never be a slug,
so it has no namespace to leak.

### Teaching an agent to publish

`GET /skill` returns a SKILL.md — `text/markdown; charset=utf-8` — that teaches an agent
the whole publish contract: how to install the CLI, how to write the one self-contained
HTML file, the component classes above, the commands that publish and replace a page, and
what each failure status means. It assumes a machine with nothing on it, because on a fresh
machine that is the situation. Bootstrapping an agent anywhere is a single instruction:

```sh
curl https://stele.example.com/skill
```

The document is served by the deployment it documents, and is rendered from that
deployment's configuration rather than being a compile-time constant. Every value with exactly one constant behind
it — the base URL, `STELE_MAX_PAGE_BYTES`, the stylesheet path, the slug length bounds,
the reserved names, the accepted content types, the whole `ttl` vocabulary (the
parameter's name, the `never` keyword, the default lifetime and its maximum), and now the
CLI's clone URL, install commands and minimum version — is interpolated from that
constant, so the
`stele auth login --host …` an agent copies out is already pointed at the right host with
the right limits. That removes the opportunity for drift rather than detecting it
afterwards: there is no second copy of those values to fall out of step, not even across
the two repositories. What is left is prose, and the prose is pinned by tests to the code
it describes — the component table against the stylesheet's own class list, the content
types against the allowlist, the example slugs against `Slug(custom:)` itself, the lifetime
table against `PageLifetime`, and the only version string in the document against
`minimumCLIVersion`.

**The skill does not hand the agent a credential, and that is the load-bearing part.** It
tells the agent to check `stele auth status`, to install the tool if it is missing, and to
*ask the user* to run `stele auth login` — never to obtain, store or pass a token. An
earlier version of this document told the agent to hold `STELE_UPLOAD_TOKEN` and warned it
not to publish the secret it was holding; the CLI removes the secret from the model's reach
instead of asking it to be careful. A test asserts the document contains no
`Authorization`, no `Bearer` and no token-shaped instruction, because a well-meant edit
restoring any of them would work perfectly and quietly undo the whole arrangement.

This README is the one document that *cannot* interpolate any of that — it is a static
file, so every route, limit, keyword and lifetime in it is typed by hand. Changing the
contract therefore means changing this file in the same commit that changes the code.

Like the stylesheet, it ships with the app rather than living in Postgres: it changes by
deploy, not by upload, and a database copy could serve one version's documentation from a
deployment running another. It is Markdown, not a styled page, because the reader is an
agent.

**There is no versioned skill path, and it is the same tradeoff as the stylesheet.**
`/skill` mutates with the deployment, so an agent that cached the document yesterday may
publish against a contract that has since moved — and, symmetrically, a fix to the
instructions reaches every agent on its next fetch, which is the point. It is served
`no-cache` with a strong ETag, so a client revalidates rather than pinning a stale copy;
that makes the window small, not zero. Fetch the skill at the start of a publishing task,
not once at setup.

Serving it publicly leaks nothing: the document describes the routes this README already
describes, `skill` is a reserved name that no page can claim, and writes still need a
credential — an agent that reads the skill without one learns how to publish and cannot.
Unlike `/pages` and `/assets`, `/skill` needs no bare-segment 404 stub, because it is a
terminal node that carries its own value; a deeper miss like `/skill/nope` gets the
framework's own 404, which no single-segment slug could ever have reached.

## Configuration

Everything is environment variables, read once at startup — see `.env.example` for the
annotated list. A bad value stops the process immediately with a message naming the
variable, rather than surfacing later as a connection error.

`DATABASE_URL` is a standard libpq URL, including `?sslmode=` with libpq's semantics:
`require` encrypts without verifying the certificate (so a self-signed or IP-addressed
Postgres works, exactly as it does with psql), and only `verify-ca` / `verify-full`
check the chain and hostname. Switching databases is a one-line change.

Two variables configure signing in with GitHub, and neither of them is a secret — that is
the point of it. `STELE_GITHUB_OWNERS` is the comma-separated list of GitHub logins allowed
to mint a publishing credential by signing in. Matching is case-insensitive, because
GitHub's own is, and an operator who typed the casing GitHub displays did not mean to lock
out the same account spelled any other way.

**The allowlist fails closed.** Absent, empty, whitespace, or nothing but commas all mean
the same thing: nobody may mint. This is the reasoning that keeps `STELE_UPLOAD_TOKEN`
defaultless, applied to a list instead of a token — a list whose absence meant "anyone"
would leave minting open on every deployment that had simply not got round to setting it,
and open with nothing to notice. Failing closed turns that same oversight into a refused
sign-in, which somebody sees. The variable is optional at boot even so: a deployment that
has not adopted GitHub sign-in should not fail to start over a feature it does not use, so
it is the sign-in that refuses, not the process.

The list gates *minting* and nothing else. Taking a login out of it does not disturb a
credential that login already holds — credentials are cut off by revoking them, `DELETE
/admin/clients/:name`, and the allowlist is consulted only at the moment one is issued.

`STELE_GITHUB_CLIENT_ID` records which GitHub OAuth app the deployment trusts (GitHub →
Settings → Developer settings → OAuth Apps). It is not a secret either. Two things about
it are worth knowing before reading any further into it: the sign-in is a device flow,
which has no redirect in it, so **the callback URL GitHub's registration form insists on is
never used** and there is no handler behind it to go looking for; and the client runs that
flow itself with its own compiled-in copy of the ID, so setting this variable does not hand
the client anything. It records on the server side which app is trusted, beside the
allowlist of the people that app may identify. There is deliberately no endpoint that
serves it — one more unauthenticated route, to spare the client a constant it already has,
is a bad trade.

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

All three of those variables are required and the stack refuses to start without them,
rather than defaulting to something that would quietly be wrong. The two GitHub sign-in
variables above belong in that same file and are optional — left out, the stack starts
normally with an allowlist that permits nobody. Both compose stacks name them explicitly,
which is what makes setting them work: Compose interpolates `.env` into the compose file
rather than handing it to the container, so a variable the compose file does not name never
reaches the process however plainly it is set.

Nothing else changes — any unapplied migrations run on boot, exactly as they do locally.
An existing deployment needs no dump and restore: version 1 describes the schema it
already has, so the first boot after a version table exists records version 1 without
running anything, then applies whatever versions come after it.

Today that means version 2, and **it is not a schema-only migration: it puts a deadline on
every page you have already published.** Alongside the nullable `expires_at` and its
partial index, version 2 backfills every existing row to expire seven days after the
upgrade runs. When that week is up, the next upload reclaims them, and expired slugs leave
no tombstone — the pages and their names are gone. Re-publish anything worth keeping with
`?ttl=never` inside that window; "Page lifetimes" above argues out why the backfill belongs
in that migration and measures from the upgrade rather than from `created_at`. Budget for
it on a large table, too: the `ALTER` and the index are catalog-only, but the backfill
`UPDATE` rewrites every row before the server starts serving.

**Point `DATABASE_URL` at a host whose storage you trust.** Development machines often
run with durability tradeoffs that are fine for rebuildable data and not fine for the
only copy of something — writes the database reports as committed can be lost on a power
cut. The local `docker compose` database is for development only.

## Before this faces the internet

The current shape is built for a trusted LAN. Two things need attention first:

- **Stored pages are same-origin.** An uploaded page's JavaScript runs on the server's
  own domain. There's nothing to steal today — no cookies, no session, no authenticated
  reads — but it stops being harmless the moment this server grows any of those. Serving
  pages from a separate domain to the API is the durable fix.
- **No rate limiting.** Reads are unauthenticated and unmetered, which is what makes the
  enumeration note above practical rather than theoretical.

Per-writer credentials used to be the third item on this list. They are done: each client
has its own scoped, expirable, revocable token, and the shared token has been demoted to
the operator's bootstrap credential — see "Credentials". The `pages.client_id` column that
records *which* credential published a page exists and is still unwritten, so attribution
is the remaining half of that item.
