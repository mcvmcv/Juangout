# Chapter 14: API and feeds

So far Juangout talks to people, through HTML. In this chapter it talks to programs: a **JSON API**
that scripts and apps can use as a member, with **API tokens** to sign in, plus **RSS and Atom
feeds** for feed readers and a **sitemap** for search engines.

Juango ideas in this chapter: **typed JSON APIs** (`API`, typed handler arguments, structs as
request and response schemas, 422 errors, OpenAPI docs), **`bearer_auth`**, adding **packages**,
hashing secrets, **`Feed`**, **`cache_page`**, and **`Sitemap`**.

## A new app, and two packages

Make the app, `julia --project manage.jl startapp api`, and load it in `project.jl` after
`moderation`, with `Api.APP` in `INSTALLED_APPS` and `path("", include_urls(Api.APP))` in `urls.jl`.

API tokens need secure random numbers and a hash function. Both are in Julia's standard library,
but a project must still list the packages it uses:

```sh
julia --project -e 'using Pkg; Pkg.add(["SHA", "Random"])'
```

That adds them to `Project.toml` (and records their versions in `Manifest.toml`). The tests also
read JSON, so add `JSON` the same way.

`api/Api.jl`:

```julia
# The api app: a JSON API for programs, members' API tokens, and RSS/Atom feeds.
module Api

using Juango
using Dates
using Random: RandomDevice, randstring
using SHA: sha256
using ..Posts: Post, for_display, feed, top_level

export ApiToken, juangout_api

const APP = App("api"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

include("models.jl")
include("schemas.jl")
include("endpoints.jl")
include("feeds.jl")
include("views.jl")
include("urls.jl")

end
```

## API tokens

A program can't fill in a login form, so each request carries a **token**: a long random secret that
a member creates and gives the program. The program sends it as `Authorization: Bearer <token>`.

### Storing them safely

A token is as good as a password, so treat it like one: don't store it. Store a **hash** of it,
a one-way fingerprint. When a request arrives, hash the token it carries and look for that. Someone
who steals a copy of the database gets only hashes, which can't be turned back into tokens.
`api/models.jl`:

```julia
# An API token: a secret a member gives a program, so it can act as them. Only a hash of the
# secret is stored, as with passwords: someone who reads the database can't use the tokens.
@model struct ApiToken
    member = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :api_tokens)
    name = CharField(max_length = 50, help_text = "What it's for, so you can recognise it later.")
    key_hash = CharField(max_length = 64, unique = true, editable = false)
    created = DateTimeField(auto_now_add = true)
    last_used = DateTimeField(null = true, blank = true, editable = false)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, t::ApiToken) = print(io, t.name)

hash_key(key) = bytes2hex(sha256(key))

"Make a token for `member`. Returns the token and its secret key, which is never stored."
function new_token!(member, name)
    key = randstring(RandomDevice(), 40)          # RandomDevice: the operating system's secure randomness
    token = create(ApiToken; member, name, key_hash = hash_key(key))
    token, key
end

"The active member a key belongs to, or `nothing`. Notes when the token was last used."
function member_for_key(key)
    token = first(select_related(filter(ApiToken; key_hash = hash_key(key)), :member))
    (token === nothing || !token.member.is_active) && return nothing
    update!(filter(ApiToken; id = token.id); last_used = timezone_now())
    token.member
end
```

- **`RandomDevice()`** reads randomness from the operating system, which is what secrets need.
  Julia's default random numbers are fast but predictable, which is fine for simulations and wrong
  for keys.
- A token is 40 random letters and digits, so it can't be guessed. That's also why a plain,
  fast SHA-256 hash is enough here. (Passwords, which people choose, need a deliberately slow hash,
  and Juango uses one for them.)
- **`first(qs)`** returns `nothing` when there's no match.

### Managing tokens

Members make and revoke their tokens on a page of their own. `api/views.jl`:

```julia
# Managing your API tokens: a list, a form to make one, and revoking.
function tokens(req)
    secret = nothing
    form = ModelForm(ApiToken; data = req.method == "POST" ? req.POST : nothing, fields = [:name])
    if req.method == "POST" && is_valid(form)
        token, secret = new_token!(req.user, form.cleaned_data[:name])
        form = ModelForm(ApiToken; fields = [:name])
    end
    # the secret is shown once, on this response, and never again
    render(req, "api/tokens.html", Dict("tokens" => req.user.api_tokens, "form" => form, "secret" => secret))
end

function revoke(req; id)
    delete!(get_object_or_404(ApiToken; id, member = req.user))
    message!(req, :success, "The token was revoked. Programs using it can't any more.")
    redirect("api:tokens")
end
```

This view breaks the "redirect after POST" rule from chapter 4, on purpose. The secret must be shown
exactly once, and a redirect would lose it. `get_object_or_404(ApiToken; id, member = req.user)` means
members can only revoke their own tokens.

`api/templates/api/tokens.html`:

```html
{% extends "base.html" %}
{% load humanize %}

{% block title %}API tokens · Juangout{% endblock %}

{% block content %}
  <h1>API tokens</h1>
  <p>A token lets a program use <a href="/api/v1/docs">Juangout's API</a> as you.
     Keep tokens secret, like passwords.</p>

  {% if secret %}
    <div class="msg success">
      <p><strong>Your new token:</strong> <code class="secret">{{ secret }}</code></p>
      <p>Copy it now. It won't be shown again.</p>
    </div>
  {% endif %}

  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <button type="submit">Make a token</button>
  </form>

  <ul class="tokens">
    {% for t in tokens %}
      <li><strong>{{ t.name }}</strong>, made {{ t.created|naturaltime }},
          {% if t.last_used %}last used {{ t.last_used|naturaltime }}{% else %}never used{% endif %}
        <form method="post" action="{% url 'api:revoke' t.id %}" class="inline">
          {% csrf_token %}<button type="submit" class="link">Revoke</button>
        </form>
      </li>
    {% empty %}
      <li class="empty">No tokens yet.</li>
    {% endfor %}
  </ul>
{% endblock %}
```

Link to it from the profile-editing page (`<a href="{% url 'api:tokens' %}">API tokens</a>`).

## The JSON API

### Schemas: the shapes of the data

An API is a contract: what each request sends and what each reply contains. Juango lets you write
the shapes as plain Julia structs. It decodes request bodies into them (checking every field's
type), encodes replies from them, and documents them. `api/schemas.jl`:

```julia
# The shapes of the API's requests and replies: plain Julia structs. Juango decodes JSON bodies
# into them, checking types, and documents them in the OpenAPI description.
struct MemberOut
    username::String
    name::String
    bio::String
    followers::Int
    following::Int
    url::String
end

struct PostOut
    id::Int
    author::String
    body::String
    created::String          # ISO 8601, in UTC
    reply_to::Union{Int,Nothing}
    like_count::Int
    reply_count::Int
    liked::Bool
    url::String
end

struct PostIn
    body::String
    reply_to::Union{Int,Nothing}
end

struct PostPage
    count::Int
    items::Vector{PostOut}
end

absolute(req, obj) = Juango.build_absolute_uri(req, get_absolute_url(obj))

post_out(req, p) = PostOut(p.id, p.author.username, p.body, string(p.created), p.reply_to_id,
                           p.like_count, p.reply_count, p.liked, absolute(req, p))

member_out(req, m) = MemberOut(m.username, m.name, m.bio, count(m.followers), count(m.following), absolute(req, m))
```

Why not just send the models? Because the API's shape is a promise to other people's programs.
Separate structs mean you can rename a database column without breaking anyone, and nothing (such
as a password hash) leaks out by accident. `build_absolute_uri` gives full URLs (`https://...`),
because a program has no "current page" to resolve relative ones against.

### Endpoints

`api/endpoints.jl`:

```julia
# The JSON API. Each endpoint is a function whose arguments after `req` say what it takes: a
# name in the path ({id}) is a path parameter, a struct is the JSON body, anything else comes
# from the query string. Juango checks them all, and answers 422 with the details if they're wrong.

const juangout_api = API(title = "Juangout API", version = "1",
                         description = "Read and write Juangout as a member. Send `Authorization: Bearer <token>`.",
                         auth = bearer_auth(member_for_key))       # every endpoint needs a token

me(req) = req.meta[:api_auth]                     # the member the token belongs to

page_of(req, posts, limit, offset) =
    PostPage(count(posts), [post_out(req, p) for p in posts[offset+1:offset+clamp(limit, 1, 100)]])

function timeline(req, limit::Union{Int,Nothing} = nothing, offset::Union{Int,Nothing} = nothing)
    page_of(req, for_display(top_level(feed(me(req))), me(req)), something(limit, 20), something(offset, 0))
end
get(timeline, juangout_api, "/timeline"; response = PostPage, summary = "Your timeline: people you follow, and you")

function member_posts(req, username::String, limit::Union{Int,Nothing} = nothing, offset::Union{Int,Nothing} = nothing)
    m = get_object_or_404(get_user_model(); username, is_active = true)
    page_of(req, for_display(m.posts, me(req)), something(limit, 20), something(offset, 0))
end
get(member_posts, juangout_api, "/members/{username}/posts"; response = PostPage, summary = "A member's posts")

get(juangout_api, "/members/{username}"; response = MemberOut, summary = "A member's profile") do req, username::String
    member_out(req, get_object_or_404(get_user_model(); username, is_active = true))
end

get(juangout_api, "/posts/{id}"; response = PostOut, summary = "One post") do req, id::Int
    post_out(req, get_object_or_404(for_display(objects(Post), me(req)); id))
end

Juango.post(juangout_api, "/posts"; status = 201, response = PostOut, summary = "Write a post, or a reply") do req, body::PostIn
    parent = body.reply_to === nothing ? nothing : get_object_or_404(Post; id = body.reply_to, hidden = false)
    p = Post(; author = me(req), body = body.body, reply_to = parent)
    errors = full_clean(p)                         # the model's own rules: length, and so on
    isempty(errors) || return JsonResponse(Dict("detail" => [Dict("loc" => ["body", String(k)], "msg" => join(v, " "))
                                                             for (k, v) in errors]); status = 422)
    save!(p)
    post_out(req, first(for_display(filter(Post; id = p.id), me(req))))
end

route!(juangout_api, "PUT", "/posts/{id}/like"; status = 204, summary = "Like a post") do req, id::Int
    add!(get_object_or_404(Post; id, hidden = false).likers, me(req))
    HttpResponse(""; status = 204)
end

route!(juangout_api, "DELETE", "/posts/{id}/like"; status = 204, summary = "Stop liking a post") do req, id::Int
    remove!(get_object_or_404(Post; id).likers, me(req))
    HttpResponse(""; status = 204)
end
```

Each endpoint is registered with `get(handler, api, path)`, `Juango.post(...)` or
`route!(handler, api, method, path)`, either as a named function or with `do`. **The handler's
arguments are the specification.**

- `{id}` in the path and an argument `id::Int` make a **path parameter**, so `/posts/abc` is
  refused.
- A struct argument (`body::PostIn`) is the **JSON body**, decoded and checked field by field.
- Anything else, like `limit::Union{Int,Nothing} = nothing`, is an optional **query parameter**
  (`?limit=10`).

When the input doesn't fit, Juango answers **422** with every problem and where it is, before your
code runs:

```json
{"detail": [{"loc": ["body", "body"], "msg": "field required"}]}
```

The handler returns a struct, which Juango encodes as JSON. Validation beyond types (the
280-character limit) comes from the model, through `full_clean`, reported in the same shape.

- **`auth = bearer_auth(member_for_key)`** applies to every endpoint. It reads the `Authorization:
  Bearer` header and calls `member_for_key` with the token. A result of `nothing` is a **401**. Whatever
  it returns is in `req.meta[:api_auth]`, which is what `me(req)` reads.
- **Status codes** say what happened: 201 Created for a new post, 204 No Content for a like (nothing to
  say), 404 for a missing post, 422 for bad input. Programs rely on them.
- `PUT` and `DELETE` on `/posts/{id}/like` make liking **idempotent**: liking twice is the same as
  liking once, so a program can safely retry.

(`Juango.post` needs its prefix for now. It isn't exported yet,
[#265](https://github.com/mcvmcv/Juango/issues/265).)

### Mounting and documenting

In `api/urls.jl`:

```julia
const urlpatterns = [
    path("api/v1/", api_urls(juangout_api)),        # the endpoints, plus openapi.json and docs/
    path("@<str:username>/feed/", member_rss; name = "feed"),
    path("@<str:username>/feed/atom/", member_atom; name = "feed_atom"),
    path("accounts/tokens/", login_required(tokens); name = "tokens"),
    path("accounts/tokens/<int:id>/revoke/", require_POST(login_required(revoke)); name = "revoke"),
]
```

The `v1` leaves room for a `v2` that changes the contract while old programs keep using `v1`.
`api_urls` also serves **`/api/v1/openapi.json`**, an OpenAPI 3.1 description generated from the
handlers and structs, which tools can turn into client libraries, and **`/api/v1/docs`**, an
interactive page (Swagger UI) for reading about the API and trying it in a browser.

From a shell:

```sh
curl -H "Authorization: Bearer YOUR-TOKEN" http://127.0.0.1:8000/api/v1/timeline
curl -X POST -H "Authorization: Bearer YOUR-TOKEN" -H "Content-Type: application/json" \
     -d '{"body": "Hello from curl", "reply_to": null}' http://127.0.0.1:8000/api/v1/posts
```

> **If you know Django:** this is django-ninja's design (typed handler arguments, schemas,
> automatic OpenAPI) built in, rather than Django REST framework's serializers and viewsets. Juango's
> API routes are CSRF-exempt, since a token in a header can't be sent by another site's form.

## Feeds

**RSS** and **Atom** are the formats feed readers use to follow sites. A Juango **`Feed`** is a view
that describes where the items come from and what each part of an item is. `api/feeds.jl`:

```julia
# Feeds: a member's posts as RSS 2.0 or Atom, for feed readers. A Feed is a view; these options
# say where its items come from and what each part of an item is.
const member_feed = Feed(
    get_object = (req; username) -> get_object_or_404(get_user_model(); username, is_active = true),
    title = m -> "$(m.name) on Juangout",
    link = m -> get_absolute_url(m),
    description = m -> "The latest posts by @$(m.username)",
    items = m -> filter(Post; author = m, hidden = false, reply_to__isnull = true)[1:20],
    item_title = p -> length(p.body) > 60 ? first(p.body, 59) * "…" : p.body,
    item_description = :body,
    item_pubdate = :created,
    item_author_name = p -> p.author.name)

# Feeds are the same for everyone, so whole responses can be cached: five minutes is fresh
# enough for a feed reader, and saves the queries when many readers poll.
const member_rss = cache_page(member_feed; timeout = 300)
const member_atom = cache_page(Feed(member_feed; feed_type = :atom); timeout = 300)
```

- **`get_object`** gets the feed's subject from the URL, here a member. The feed-level options are
  functions of it.
- The **item** options are functions of each item, or a field name (`:body`, `:created`). Items link
  to their `get_absolute_url` unless you say otherwise.
- `Feed(member_feed; feed_type = :atom)` is the same feed as Atom.

Feed readers poll every few minutes, and a feed is the same for everyone, so it's a perfect fit for
**`cache_page`**, which caches whole responses by URL. (Chapter 13's pages couldn't use it, because they
differ for each member.)

Tell browsers and feed readers about the feed. `base.html` gets a block in its `<head>`,

```html
  {% block extra_head %}{% endblock %}
```

which the profile template fills in:

```html
{% block extra_head %}
  <link rel="alternate" type="application/rss+xml" title="{{ member.name }} on Juangout" href="{% url 'api:feed' member.username %}">
{% endblock %}
```

and add a visible link too: `<a href="{% url 'api:feed' member.username %}">RSS feed</a>`.

## A sitemap

A **sitemap** lists a site's pages for search engines. In the project's `urls.jl`:

```julia
    # /sitemap.xml: every public page, for search engines
    sitemap_urls(Dict(
        "members" => Sitemap(() -> filter(get_user_model(); is_active = true); changefreq = "daily"),
        "posts" => Sitemap(() -> filter(Post; hidden = false, reply_to__isnull = true); lastmod = :created),
        "pages" => Sitemap(["posts:timeline", "about"]; location = name -> reverse_url(name)),
    ))...,
```

`/sitemap.xml` becomes an index pointing at one sitemap per section. Models use their
`get_absolute_url`, and `lastmod` tells search engines when a page last changed. `sitemap_urls` returns
several URL patterns, so `...` splices them into the list.

And the CSS:

```css
/* api */
code.secret { font-size: 1rem; background: var(--card); padding: .15rem .4rem; border-radius: 4px; user-select: all; }
.tokens { list-style: none; padding: 0; }
.tokens li { padding: .5rem 0; border-bottom: 1px solid var(--line); }
```

`user-select: all` selects the whole token with one click, ready to copy.

## Tests

The test client sends JSON with **`json = ...`**, extra headers with **`headers = ...`**, and any
method with **`request(c, "PUT", url)`**. Create `api/tests.jl`, and `tests/test_api.jl` to run it:

```julia
using Test
using Juango.Testing
using JSON

@testset "API tokens" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = post(c, "/accounts/tokens/", Dict("name" => "my script"))
        secret = r.context["secret"]
        @test length(secret) == 40
        @test assert_contains(r, secret)                       # shown once...
        @test !occursin(secret, text(get(c, "/accounts/tokens/")))   # ...and never again
        token = only(ann.api_tokens)
        @test token.key_hash == Api.hash_key(secret) != secret   # only the hash is stored
        @test Api.member_for_key(secret) == ann
        @test Api.member_for_key("not-a-key") === nothing

        post(c, "/accounts/tokens/$(token.id)/revoke/")
        @test Api.member_for_key(secret) === nothing
    end
end

@testset "the JSON API" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        add!(ann.following, bob)
        hello = create(Post; author = bob, body = "Hello from Bob")
        _, key = Api.new_token!(ann, "tests")
        auth = Dict("Authorization" => "Bearer $key")
        c = Client()
        body(r) = JSON.parse(text(r))

        # no token, or a wrong one: 401
        @test get(c, "/api/v1/timeline").status == 401
        @test get(c, "/api/v1/timeline"; headers = Dict("Authorization" => "Bearer nope")).status == 401

        r = get(c, "/api/v1/timeline"; headers = auth)
        @test r.status == 200
        page = body(r)
        @test page["count"] == 1
        @test only(page["items"])["body"] == "Hello from Bob"
        @test only(page["items"])["author"] == "bob"
        @test startswith(only(page["items"])["url"], "http")      # absolute

        @test body(get(c, "/api/v1/members/ann"; headers = auth))["name"] == "Ann Lee"
        @test body(get(c, "/api/v1/members/bob"; headers = auth))["followers"] == 1
        @test get(c, "/api/v1/members/nobody"; headers = auth).status == 404

        # writing: 201 with the new post; a reply; bad input is a 422 saying what's wrong
        r = post(c, "/api/v1/posts"; json = Dict("body" => "Posted by a robot", "reply_to" => nothing), headers = auth)
        @test r.status == 201
        @test body(r)["author"] == "ann"
        r = post(c, "/api/v1/posts"; json = Dict("body" => "A reply", "reply_to" => hello.id), headers = auth)
        @test body(r)["reply_to"] == hello.id
        r = post(c, "/api/v1/posts"; json = Dict("body" => "x"^281, "reply_to" => nothing), headers = auth)
        @test r.status == 422
        @test body(r)["detail"][1]["loc"] == ["body", "body"]
        r = post(c, "/api/v1/posts"; json = Dict("reply_to" => nothing), headers = auth)
        @test r.status == 422                                     # body missing
        @test body(get(c, "/api/v1/members/ann/posts"; headers = auth))["count"] == 2

        # likes
        @test request(c, "PUT", "/api/v1/posts/$(hello.id)/like"; headers = auth).status == 204
        @test body(get(c, "/api/v1/posts/$(hello.id)"; headers = auth))["liked"] == true
        @test request(c, "DELETE", "/api/v1/posts/$(hello.id)/like"; headers = auth).status == 204
        @test !(ann in hello.likers)

        # pagination with limit and offset
        for i in 1:30
            create(Post; author = bob, body = "bob $i")
        end
        page = body(get(c, "/api/v1/timeline?limit=10&offset=5"; headers = auth))
        @test length(page["items"]) == 10
        @test page["count"] == 32

        # the OpenAPI description documents it all
        spec = body(get(c, "/api/v1/openapi.json"))
        @test haskey(spec["paths"], "/api/v1/timeline")
        @test haskey(spec["paths"], "/api/v1/posts/{id}/like")
    end
end

@testset "feeds and the sitemap" begin
    rollback_after() do
        cache_clear()
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        create(Post; author = ann, body = "First <post> & more")
        create(Post; author = ann, body = "Hidden", hidden = true)
        c = Client()
        r = get(c, "/@ann/feed/")
        @test r.status == 200
        @test occursin("rss", getheader(r, "Content-Type"))
        @test occursin("<title>Ann Lee on Juangout</title>", text(r))
        @test occursin("First &lt;post&gt; &amp; more", text(r))
        @test !occursin("Hidden", text(r))
        @test occursin("atom", getheader(get(c, "/@ann/feed/atom/"), "Content-Type"))
        @test get(c, "/@nobody/feed/").status == 404

        # cached: a new post doesn't show until the cache expires (here, until it's cleared)
        create(Post; author = ann, body = "Brand new")
        @test !occursin("Brand new", text(get(c, "/@ann/feed/")))
        cache_clear()
        @test occursin("Brand new", text(get(c, "/@ann/feed/")))

        # profiles point feed readers at the feed
        @test assert_contains(get(c, "/@ann/"), "application/rss+xml"; html = false)

        r = get(c, "/sitemap.xml")
        @test r.status == 200
        @test occursin("sitemap-members.xml", text(r))
        @test occursin("/@ann/", text(get(c, "/sitemap-members.xml")))
    end
end
```

Things worth noticing:

- The token test proves the security properties, not just that it works: the secret is shown once,
  and the database holds only its hash.
- The feed test checks escaping. A post containing `<post> & more` must come out as `&lt;post&gt; &amp;
  more`, or it would break every feed reader that reads it.
- `JSON.parse(text(r))` reads a JSON reply.

## Summary

- **`API(...)`** plus handlers whose argument types are the contract: path parameters, a struct body,
  query parameters. Bad input gets a **422** before your code runs. Return structs, and Juango encodes
  them.
- **`bearer_auth(f)`** authenticates each request by token. Store tokens **hashed**, made with
  `RandomDevice`.
- **`api_urls`** mounts the API with **OpenAPI** and interactive docs. Version the URL (`/api/v1/`).
- Add packages with **`Pkg.add`**. They go in `Project.toml` and `Manifest.toml`.
- **`Feed`** makes RSS and Atom from a few options. **`cache_page`** caches whole responses that are the
  same for everyone.
- **`sitemap_urls`** builds a sitemap from querysets and URL names.

The code at this point is tagged `ch14`.

One chapter to go. In chapter 15, Juangout leaves your laptop.
