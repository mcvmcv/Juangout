# Chapter 15: Deployment

Juangout works on your laptop. This last chapter gets it ready for a real server: settings that
come from the environment, PostgreSQL instead of SQLite, HTTPS, static files served properly, a worker
for background tasks, error pages, and a checklist. It ends with how the pieces fit together on a
Linux server behind nginx.

Juango ideas in this chapter: **`Juango.Environ`** (`env`, `env_db`, `env_cache`, `env_email`),
**`check --deploy`**, the **security settings**, **PostgreSQL** and full-text search, **`collectstatic`**
and manifest storage, the **database task backend** and `db_worker`, **`LIVE_PUBSUB`**, **error pages**,
and running Juango in production.

## Settings from the environment

A laptop and a server need different settings: `DEBUG` on or off, a different database, real email.
Some settings, like `SECRET_KEY` and passwords, are secret and mustn't be in git at all. So they come
from **environment variables**, or from a `.env` file that stays out of git (it's been in `.gitignore`
since chapter 1). **`Juango.Environ`** reads them: `env(name, Type; default)` reads and converts one
variable, and `read_env(".env")` loads a file of `NAME=value` lines.

Rewrite `settings.jl` so that everything that varies comes from the environment, with development
defaults:

```julia
# Settings. What differs between a laptop and a server comes from environment variables, or a
# .env file kept out of git (see .env.example): DEBUG, SECRET_KEY, ALLOWED_HOSTS, DATABASE_URL,
# EMAIL_URL, CACHE_URL, SITE_URL. With none of them set, you get a development setup.
using Juango.Environ
read_env(joinpath(BASE_DIR, ".env"))

debug = env("DEBUG", Bool; default = true)
on_postgres = startswith(env("DATABASE_URL"; default = ""), "postgres")
site_url = env("SITE_URL"; default = "http://127.0.0.1:8000")

configure!(;                                                 # (the ; lets env_email(...)... below add keywords)
    DEBUG = debug,
    # signs sessions, password-reset links and CSRF tokens: required, and secret, in production
    SECRET_KEY = debug ? env("SECRET_KEY"; default = "insecure-development-key-never-use-in-production") :
                         env("SECRET_KEY"),
    ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost", "127.0.0.1"]),

    # services, each from a URL: DATABASE_URL=postgresql://user:password@host:5432/juangout,
    # CACHE_URL=redis://host:6379/0, EMAIL_URL=smtp+tls://user:password@mail.example.com:587
    DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
    CACHES = Dict("default" => env_cache(; default = "locmem://")),
    env_email(; default = "consolemail://")...,          # printed to the terminal unless EMAIL_URL says otherwise
    DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    SERVER_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    ADMINS = [("Admin", a) for a in env("ADMIN_EMAILS", Vector{String}; default = String[])],   # mailed about errors
    SITE_URL = site_url,                                  # for links in emails

    # background tasks run at once in development; in production a worker process runs them
    # (julia --project manage.jl db_worker), so a slow mail server never holds up a page
    TASKS = Dict("default" => Dict("backend" => debug ? :immediate : :database)),
    # in production, live views hear about new posts from every server process, through PostgreSQL
    # (it sends messages when transactions commit; one process, in development, needs no help)
    LIVE_PUBSUB = on_postgres && !debug ? :postgres : nothing,

    INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages",
                      "juango.tasks", Accounts.APP, Posts.APP, Notifications.APP, Moderation.APP, Api.APP],
    # ... MIDDLEWARE, INTERNAL_IPS, CONTEXT_PROCESSORS, ATOMIC_REQUESTS, AUTH_USER_MODEL,
    #     MIGRATIONS_DIR and ROOT_URLCONF as before ...

    # templates, static files and uploads
    TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
    STATIC_DIRS = [joinpath(BASE_DIR, "static")],
    STATIC_ROOT = joinpath(BASE_DIR, "staticfiles"),     # collectstatic copies everything here, for the web server
    STATICFILES_STORAGE = debug ? :static : :manifest,   # in production, a hash in each name, so browsers can cache them for ever
    MEDIA_ROOT = joinpath(BASE_DIR, "media"),            # uploaded files (FileField/ImageField)

    # ... time zones and languages as before ...

    # HTTPS, in production: behind a proxy (nginx) that handles TLS and says so in a header
    SECURE_PROXY_SSL_HEADER = debug ? nothing : ("X-Forwarded-Proto", "https"),
    SECURE_SSL_REDIRECT = !debug,                        # http:// -> https://
    SECURE_HSTS_SECONDS = debug ? 0 : env("HSTS_SECONDS", Int; default = 3600),   # raise to a year once it all works
    SESSION_COOKIE_SECURE = !debug,                      # cookies only over HTTPS
    CSRF_COOKIE_SECURE = !debug,
    CSRF_TRUSTED_ORIGINS = [site_url],
)
```

(The full file is in the repository. The parts marked "as before" haven't changed.) Section by section:

### Secrets

**`SECRET_KEY`** signs session cookies, password-reset links and CSRF tokens. Anyone who knows it can
forge them, so in production it must be long, random and secret. The rule here is that in development
there's a fixed, obviously fake default, and in production there's *no* default, so if it's missing the
server refuses to start (`env` throws) rather than running with a key that's in your git history. To
make one:

```sh
julia -e 'using Random; println(randstring(RandomDevice(), 64))'
```

> `startproject` wrote a real-looking key straight into `settings.jl` in chapter 1, so it's in git, and
> Juangout's is on GitHub. That's fine as long as it's only used in development, which this rule makes
> sure of. Never reuse a key that has been committed.

**`ALLOWED_HOSTS`** lists the domain names the site answers to. Requests for any other host are refused.
That stops attacks that rely on the server trusting the `Host` header, for example to build password-reset
links pointing elsewhere.

### Services as URLs

Each external service is configured with one URL, a common convention for hosting platforms:

- **`env_db`** reads `DATABASE_URL`: `postgresql://user:password@host:5432/juangout`, or `sqlite:///path`.
- **`env_cache`** reads `CACHE_URL`: `locmem://`, `redis://host:6379/0`, `memcached://host:11211`.
- **`env_email`** reads `EMAIL_URL`: `consolemail://` prints, `smtp+tls://user:password@host:587` sends.
  It returns several settings at once (`EMAIL_BACKEND`, `EMAIL_HOST` and so on), so it's spliced into
  `configure!` with `...`. That only works after a `;`, which marks what follows as keyword arguments,
  hence `configure!(; ...`.

**`ADMINS`** receive an email whenever an unhandled error happens while `DEBUG` is off, with the details
that the debug page would have shown.

### `.env.example`

Document every variable in a file that *is* committed, `.env.example`:

```
# Copy to .env (which is in .gitignore) and fill in, or set these as environment variables.
# With none of them set, Juangout runs in development mode on SQLite.

DEBUG=false
# 50 or more random characters: julia -e 'using Random; println(randstring(RandomDevice(), 64))'
SECRET_KEY=
ALLOWED_HOSTS=juangout.example
SITE_URL=https://juangout.example

DATABASE_URL=postgresql://juangout:PASSWORD@127.0.0.1:5432/juangout
# CACHE_URL=redis://127.0.0.1:6379/0
EMAIL_URL=smtp+tls://USER:PASSWORD@smtp.example.com:587
DEFAULT_FROM_EMAIL=Juangout <noreply@juangout.example>
ADMIN_EMAILS=you@example.com
```

> **If you know Django:** `Juango.Environ` is django-environ: `env`, `env.db()`, `env.cache()`,
> `env.email()`, with the same URL schemes.

## PostgreSQL

SQLite is a file, written by one process at a time. That's ideal on a laptop, but a busy site needs a
database server that many connections can write to at once. Juango supports PostgreSQL and MySQL.
PostgreSQL is the usual choice, and Juango has extras for it.

Install PostgreSQL, make a user and an empty database, then point `DATABASE_URL` at it and migrate:

```sh
createdb juangout
DATABASE_URL=postgresql://you@127.0.0.1:5432/juangout julia --project manage.jl migrate
```

The same migrations that built the SQLite database build the PostgreSQL one. The tests run there too:
`manage.jl test` makes a `test_juangout` database on the same server, and drops it afterwards.

```sh
DATABASE_URL=postgresql://you@127.0.0.1:5432/juangout julia --project manage.jl test
```

Run the tests against the database you deploy on. Databases differ in small ways (ordering of equal
values, case sensitivity, what a "word" is), and the tests are how you find out before your members do.
That's exactly what happened in writing this chapter, described next.

### Full-text search

Chapter 11 searched posts with `icontains`, which finds `garden` in "gardener" but not "gardens" in
"garden". PostgreSQL has **full-text search**, which understands word forms. The lookup is
**`__search`**. Change the search filter in `posts/views.jl` to use it:

```julia
# "#garden" means the tag; anything else is searched for in the text (full-text search, which
# on PostgreSQL understands word forms: "gardens" finds "garden"), usernames and tags.
function search_posts(qs, name, v)
    startswith(v, "#") && return filter(qs; tags__name = lowercase(v[2:end]))
    filter(qs, Q(body__search = v) | Q(author__username__icontains = v) | Q(tags__name = lowercase(v)))
end
```

and use it in the `FilterSet`: `:q => CharFilter(label = "Search for", distinct = true, method =
search_posts)`. On SQLite, `__search` falls back to matching each word, so development still works,
just without the cleverness. Running the tests on PostgreSQL showed why `#garden` needed its own
branch: full-text search ignores punctuation, so "#garden" also found posts that merely mention
gardens. For more control, Juango's `Juango.Postgres` module has `SearchVector`, `SearchQuery` and
`SearchRank`, for weighting fields and ordering by relevance.

A test that only makes sense on PostgreSQL can check the database and skip itself elsewhere:

```julia
@testset "full-text search on PostgreSQL" begin
    if startswith(env("DATABASE_URL"; default = ""), "postgres")
        rollback_after() do
            ann = create_user("ann"; password = "correct-horse-battery")
            create(Post; author = ann, body = "Our gardens are full of tomatoes")
            # stemming: "garden" finds "gardens", "tomato" finds "tomatoes"
            r = get(Client(), "/search/?q=garden+tomato")
            @test [p.body for p in r.context["page_obj"]] == ["Our gardens are full of tomatoes"]
        end
    else
        @test_skip "needs DATABASE_URL=postgresql://..."
    end
end
```

## HTTPS and security settings

In production, Juango sits behind a **reverse proxy** such as nginx. The proxy handles HTTPS (TLS)
and passes requests to Juango over plain HTTP on the same machine, adding a header,
`X-Forwarded-Proto: https`, that says the original request was secure. The security settings above:

- **`SECURE_PROXY_SSL_HEADER`** tells Juango to trust that header. Only set it when the proxy always sets
  (or strips) it, or anyone could claim to be on HTTPS.
- **`SECURE_SSL_REDIRECT`** redirects `http://` to `https://`.
- **`SECURE_HSTS_SECONDS`** sends `Strict-Transport-Security`, telling browsers to use only HTTPS for this
  site for that long. Browsers remember it, so start small (an hour) and raise it to a year once you're
  sure HTTPS works.
- **`SESSION_COOKIE_SECURE`** and **`CSRF_COOKIE_SECURE`** stop cookies being sent over plain HTTP.

Juango also sends `X-Content-Type-Options`, `X-Frame-Options` and `Referrer-Policy` headers by default.

### `check --deploy`

Juango can check a production configuration for you:

```sh
DEBUG=false SECRET_KEY=... ALLOWED_HOSTS=juangout.example julia --project manage.jl check --deploy
```

With the settings above and the test values used here, it reported two things:

```
System check identified 2 issues (0 silenced):
  WARNING: (security.W020) ALLOWED_HOSTS has only local addresses: set it to the site's domain names.
  WARNING: (security.W005) SECURE_HSTS_INCLUDE_SUBDOMAINS is false: subdomains can still be reached over plain HTTP.
```

The first goes away with a real domain. The second is a decision. If all your subdomains use HTTPS, set
`SECURE_HSTS_INCLUDE_SUBDOMAINS = true`. Run `check --deploy` before every deployment.

## Static files in production

Juango's development server serves `static/` itself. In production, a web server should, since it's
much better at sending files. **`collectstatic`** gathers every static file (yours, your apps', and
Juango's own, like htmx) into `STATIC_ROOT`:

```sh
DEBUG=false SECRET_KEY=... julia --project manage.jl collectstatic
```

```
6 static files copied to /srv/juangout/staticfiles
```

With **`STATICFILES_STORAGE = :manifest`** it also writes a copy of each file with a hash of its contents
in the name, `style.303bdd481792.css`, plus a `staticfiles.json` mapping names to hashed names, and
`{% static 'style.css' %}` then gives the hashed URL. Because the name changes whenever the file does,
the web server can tell browsers to cache static files for ever, and a new release is still picked up
at once. It also writes `.gz` copies for the web server to send compressed. Add `staticfiles/` to
`.gitignore`: it's built, not written.

Manifest storage needs `collectstatic` to have run, so development keeps `:static`, which is why the
setting depends on `debug`.

## Background tasks: a worker

In chapter 9, tasks ran immediately (`:immediate`), inside the request. In production that's what you
wanted to avoid: a slow mail server would slow down the page. With the **`:database`** backend,
`enqueue` stores the task in a table (from the `juango.tasks` app, now in `INSTALLED_APPS`, so run
`migrate`) and returns at once. A separate process runs the tasks:

```sh
julia --project manage.jl db_worker
```

It runs until it's stopped, picking up tasks as they arrive. Several workers can run at once on
PostgreSQL. In testing this chapter, a reply queued its notification email, and the worker sent it:

```
To: ann@example.com
Subject: bob replied to your post on Juangout
```

That's also why chapter 9 enqueued with `on_commit`: the worker is another process, and it can only see
the notification once the reply's transaction has committed.

## Live views across processes

A big site runs several Juango processes, and a post saved by one should reach live views connected to
any of them. **`LIVE_PUBSUB = :postgres`** sends `publish`ed messages through PostgreSQL's `NOTIFY`, which
every process listens to. Messages go when the transaction commits, which is also why the setting is
only on in production. Tests never commit (`rollback_after`), and one development process needs no help.

## Error pages

With `DEBUG` off, an error shows the visitor a plain page instead of the debug page. Juango uses
templates named `404.html` (not found), `403.html`, `400.html` and `500.html` (server error) if you
provide them. `templates/404.html` can use the site's look:

```html
{% extends "base.html" %}

{% block title %}Not found · Juangout{% endblock %}

{% block content %}
  <h1>Page not found</h1>
  <p>There's nothing here. It may have been deleted, or the link may be wrong.</p>
  <p><a href="{% url 'posts:timeline' %}">Back to the timeline</a></p>
{% endblock %}
```

But `500.html` should be deliberately plain, with no base template and nothing that touches the database,
because it's shown when something has already gone wrong, perhaps with the database itself:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Something went wrong · Juangout</title>
<style>body { font: 16px/1.55 system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; color: #1f2328; }</style>
</head>
<body>
  {# Deliberately plain: no base template, no database, no tags that could fail again. #}
  <h1>Something went wrong</h1>
  <p>Sorry. We've been told about it and will look into it. Please try again in a little while.</p>
  <p><a href="/">Juangout</a></p>
</body>
</html>
```

Test the 404 page with `DEBUG` off:

```julia
@testset "error pages" begin
    rollback_after() do
        override_settings(DEBUG = false) do
            r = get(Client(), "/no-such-page/")
            @test r.status == 404
            @test assert_contains(r, "Page not found"; status = 404)      # our templates/404.html
        end
    end
end
```

## Running it

Here's how it fits together on a Linux server. The repository has these files in `deploy/`.

**Juango itself**, run by systemd, which starts it at boot and restarts it if it stops. Juango handles
many requests at once in one process, using threads, so there's one service, not a pool of workers.
`deploy/juangout.service`:

```ini
# /etc/systemd/system/juangout.service: the web server
[Unit]
Description=Juangout
After=network.target postgresql.service

[Service]
User=juangout
WorkingDirectory=/srv/juangout
EnvironmentFile=/srv/juangout/.env
# --threads=auto,1: worker threads for views, plus one to answer connections
ExecStart=/usr/local/bin/julia --project --threads=auto,1 manage.jl runserver 127.0.0.1:8000 --noreload
Restart=always

[Install]
WantedBy=multi-user.target
```

It listens on `127.0.0.1` only, so nothing reaches it except through the proxy. **The task worker** is
a second service, the same apart from `ExecStart=... manage.jl db_worker` (`deploy/juangout-worker.service`).

**nginx** handles HTTPS, serves static files and uploads, and passes everything else to Juango,
WebSockets included, for the live timeline. `deploy/nginx.conf`:

```nginx
# /etc/nginx/sites-available/juangout: TLS, static files and uploads; everything else to Juango
server {
    listen 443 ssl;
    server_name juangout.example;
    ssl_certificate     /etc/letsencrypt/live/juangout.example/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/juangout.example/privkey.pem;
    client_max_body_size 6m;                         # posts' pictures are up to 5 MB

    location /static/ { alias /srv/juangout/staticfiles/; expires max; }    # hashed names: cache for ever
    location /media/  { alias /srv/juangout/media/; }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;  # tells Juango the request was HTTPS
        proxy_http_version 1.1;                      # WebSockets, for the live timeline:
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {                                             # http:// -> https://
    listen 80;
    server_name juangout.example;
    return 301 https://$host$request_uri;
}
```

**Deploying a new version** is then:

```sh
cd /srv/juangout
git pull
julia --project -e 'using Pkg; Pkg.instantiate()'   # the exact versions in Manifest.toml
julia --project manage.jl check --deploy
julia --project manage.jl migrate
julia --project manage.jl collectstatic
sudo systemctl restart juangout juangout-worker
```

This is why chapter 1 committed `Manifest.toml`: `Pkg.instantiate()` installs exactly the versions you
tested with.

**Starting faster.** A Julia process compiles code the first time it runs it, so a freshly started
server is slow for its first few requests. `julia --project manage.jl build` makes a **system image**
with that compiled code saved, and `julia -J build/juango.so ...` starts from it in a few seconds.
Building takes several minutes and needs a lot of memory (around 11 GB, by Juango's documentation), so
build on a big machine with the same operating system and CPU, and copy the image across.

## A last look at the migration warnings

Since chapter 7, `makemigrations` has warned about adding columns "without a database default". Now it
matters. During a deployment, between `migrate` and the restart, the *old* code is still serving
requests against the *new* tables. If a new column is `NOT NULL` without a database default, the old
code's inserts, which don't know about the column, fail for those few seconds. Juango's migration
safety checks point out such changes, and its README describes the safe sequences (add the column as
nullable, deploy, fill it in, then make it required). For a small site, a few seconds of failed posts
during a deployment may be acceptable. For a big one, follow the warnings.

## The checklist

Before going live:

- [ ] `DEBUG=false`, a new random `SECRET_KEY`, real `ALLOWED_HOSTS` and `SITE_URL`
- [ ] PostgreSQL, with the tests passing against it
- [ ] `check --deploy` clean, or each warning understood
- [ ] `collectstatic`, with nginx serving `/static/` and `/media/`
- [ ] HTTPS, with HSTS starting small
- [ ] email (`EMAIL_URL`) working, and `ADMIN_EMAILS` set
- [ ] the task worker running
- [ ] backups of the database *and* of `media/`

## Summary

- Read what varies, and what's secret, from the **environment** with `Juango.Environ`. Commit an
  `.env.example`, never the `.env`. Production requires a real `SECRET_KEY`.
- **PostgreSQL** via `DATABASE_URL`. Run the tests against it. `__search` gives full-text search.
- Behind a **proxy**: `SECURE_PROXY_SSL_HEADER`, `SECURE_SSL_REDIRECT`, HSTS and secure cookies. Run
  **`check --deploy`**.
- **`collectstatic`** with **manifest storage** for static files served by the web server.
- **`TASKS`** with the **`:database`** backend and a **`db_worker`** process. **`LIVE_PUBSUB = :postgres`**
  for live views across processes.
- Custom **error pages**, with a plain `500.html`.
- **systemd** runs Juango and the worker. **nginx** handles TLS, files and WebSockets. Deploy with
  `instantiate`, `migrate`, `collectstatic` and a restart.

The code at this point is tagged `ch15`.

## Where next

That's Juangout. Along the way you've used most of Juango: models and migrations, the ORM, forms, auth,
the admin, generic views, htmx, live views, signals, email and tasks, permissions, caching, translations,
an API, feeds and deployment. Some ideas for taking it further, each of which touches something new:

- **Direct messages** between members: a new app, with a conversation model and access control on
  every query.
- **Blocking members**: a many-to-many on `Member` that `for_display` and the notification signals respect.
- **Formsets** (Juango's `formset`): a post with several pictures, each with its own description.
- **Rate limiting**: a middleware that counts each member's posts per minute in the cache.

The Juango README covers every feature in more depth, and this repository's issues list the rough edges
found while writing the tutorial, most of them already reported upstream.
