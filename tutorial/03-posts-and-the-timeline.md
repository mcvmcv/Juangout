# Chapter 3: Posts and the timeline

Members can't say anything yet. In this chapter you add a second app, `posts`, with a `Post`
model that belongs to a member. You'll explore the ORM from the Julia REPL, show posts on a
paginated timeline and on profiles, and write a management command that fills the
database with demo data.

Juango ideas in this chapter: **foreign keys**, the **ORM** (querysets, lookups, ordering,
slicing), **generic views** (`ListView` and `DetailView`), **pagination**, `{% include %}`,
more **template filters**, and **custom management commands**.

## The posts app

Make the app as before:

```sh
julia --project manage.jl startapp posts
```

Delete `posts/templates/posts/index.html`, and make `posts/Posts.jl` export the model you're
about to write. It also declares a management command, `seed`, which you'll write at the end
of the chapter:

```julia
# The posts app: what members write, and the timeline that shows it.
module Posts

using Juango
using Dates

export Post

const APP = App("posts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                commands = Dict("seed" => ("Create demo members and posts", args -> seed(args))))

include("models.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")
include("commands.jl")

end
```

Install it like `accounts`: load it in `project.jl` after `accounts`,

```julia
Juango.project_include(joinpath(BASE_DIR, "accounts", "Accounts.jl"))
using .Accounts
Juango.project_include(joinpath(BASE_DIR, "posts", "Posts.jl"))
using .Posts
```

and add `Posts.APP` to `INSTALLED_APPS` in `settings.jl`:

```julia
                      Accounts.APP, Posts.APP],
```

## The Post model

`posts/models.jl`:

```julia
@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, p::Post) = print(io, length(p.body) > 50 ? first(p.body, 49) * "…" : p.body)

Juango.get_absolute_url(p::Post) = reverse_url("posts:detail"; id = p.id)
```

There's a lot packed into those few lines:

- **`ForeignKey`** links each post to one member. In the database it's a column, `author_id`,
  holding the member's id. In Julia, `post.author` is the `Member` itself, fetched when you
  first use it.
- **`USER_MODEL`** stands for "whatever `AUTH_USER_MODEL` says". You could write `Member`, but
  `USER_MODEL` keeps the posts app independent of `accounts`, so it would work in a
  project with a different user model.
- **`on_delete = :CASCADE`** says what happens to a member's posts if the member is deleted:
  they're deleted too. Other choices include `:PROTECT` (refuse to delete the member) and
  `:SET_NULL`.
- **`related_name = :posts`** names the other side of the relation: `member.posts` is all of a
  member's posts.
- **`auto_now_add = true`** fills in `created` with the current time when the post is first
  saved.
- **`Meta(ordering = ["-created"])`** sets the default order of query results: newest first
  (the `-` means descending).
- Every model also gets an `id` field, an integer that the database assigns.

Make and apply the migration:

```sh
julia --project manage.jl makemigrations
julia --project manage.jl migrate
```

> **If you know Django:** `ForeignKey(Model; on_delete = ..., related_name = ...)` works as in
> Django, `USER_MODEL` plays the part of `settings.AUTH_USER_MODEL`, and `Meta(...)` is
> `class Meta`. Every model gets an automatic `id` primary key.

## Exploring the ORM

The **ORM** (object-relational mapper) is how you read and write the database in Julia. The
best way to learn it is to try it at the REPL. Start Julia with the project loaded:

```sh
julia --project -i manage.jl
```

`-i` keeps Julia open after the script runs. With no command, `manage.jl` just loads the
project. (`manage.jl shell` reminds you of this.) First fetch the member you made in
chapter 2. Use your own username:

```julia
julia> ann = get(Member; username = "ann")
<Member: @ann>
```

`get` returns the one row that matches, and throws an error if there's none (or more than one).
The `<Member: @ann>` uses the `Base.show` method you wrote. Now create a post:

```julia
julia> p = create(Post; author = ann, body = "Typed this in the REPL.")
<Post: Typed this in the REPL.>

julia> p.id
13

julia> p.author
<Member: @ann>

julia> p.created
2026-11-18T22:39:20.964+00:00
```

`create` makes the row and returns it. `created` is a `ZonedDateTime` in UTC: the project has
`USE_TZ = true`, so times are stored unambiguously and shown in local time on pages. Chapter 13
covers time zones.

Most queries start with `objects(Model)`, which means "all the rows". It returns a
**QuerySet**:

```julia
julia> count(objects(Post))
13

julia> count(ann.posts)
4

julia> filter(Post; body__icontains = "cat")
<QuerySet [The cat has claimed my keyboard. Send help.]>

julia> objects(Post)[1:3]
<QuerySet [Typed this in the REPL., Coffee number four. Productivity unchanged., Today I learned that octopuses have three hearts.]>

julia> first(objects(Post))
<Post: Typed this in the REPL.>
```

Some things to notice:

- **Lookups** go in keyword arguments. `body = "..."` is an exact match, and a double
  underscore adds a lookup type: `body__icontains` (contains, ignoring case), `created__year`,
  `id__in`, `id__gt` and so on. Lookups also follow relations: `filter(Post;
  author__username = "ann")`.
- **QuerySets are lazy.** Building one doesn't run any SQL. It runs when you need the
  results: when you iterate, `count`, `first`, or show it.
- **QuerySets chain.** `filter`, `exclude` and `order_by` each return a new QuerySet, so you can
  build a query up in steps:

  ```julia
  julia> others = exclude(Post; author = ann);

  julia> oldest_first = order_by(others, "created");
  ```

- **Slicing** becomes `LIMIT`/`OFFSET` in SQL. `objects(Post)[1:3]` fetches three rows, not
  thirteen.
- The results come back in `Meta.ordering` order, newest first, unless you `order_by`
  something else.

Changing and deleting rows:

```julia
julia> p.body = "Edited in the REPL."; save!(p)

julia> delete!(p)
```

And when nothing matches:

```julia
julia> get(Post; id = 999)
ERROR: Post.DoesNotExist: no object matches id=999
```

In a view, use `get_object_or_404` instead, as in chapter 2, so a missing row becomes a 404 page.

> **If you know Django:** `objects(Post)` is `Post.objects.all()`, `filter(Post; ...)` is
> `Post.objects.filter(...)`, and lookups such as `__icontains` and `__in` are the same.
> Functions take the model or queryset as their first argument, the Julia way, rather than
> being methods on a manager.

## Posts in the admin

Register `Post` in `posts/admin.jl`:

```julia
Admin.register!(Post;
    list_display = [:body, :author, :created],
    search_fields = [:body, :author__username],
    list_filter = [:created])
```

`list_display` picks the columns of the list page, `search_fields` adds a search box (note the
lookup across the relation), and `list_filter` adds a sidebar of filters. Start the server and
look at *Posts* in the admin.

## The timeline: generic views

Showing a list of rows, or one row, is so common that Juango has ready-made **generic
views** for it. Rather than write a function, you configure one. `posts/views.jl`:

```julia
# Generic views: configured, not written. ListView fetches a page of rows and renders a
# template with them; DetailView fetches one row by the id in the URL.
const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20)

const post_detail = DetailView(Post; template = "posts/detail.html")
```

`ListView` gives its template the posts as `post_list`. With `paginate_by` it shows 20 at a
time, reads the page number from `?page=`, and adds `page_obj`, `paginator` and `is_paginated`
for links between pages. A page number past the end is a 404. `DetailView` takes the `id` from
the URL, fetches that post (or gives a 404), and passes it to its template as `post`.

`posts/urls.jl`:

```julia
const urlpatterns = [
    path("", timeline; name = "timeline"),
    path("posts/<int:id>/", post_detail; name = "detail"),
]
```

The timeline replaces chapter 1's home page. Delete the project's `views.jl` and
`templates/home.html`, take `views.jl` out of `project.jl`, and change `urls.jl` to:

```julia
const urlpatterns = [
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("", include_urls(Accounts.APP)),            # /@username/
    path("", include_urls(Posts.APP)),               # the timeline at /, posts at /posts/<id>/
]
```

In `templates/base.html`, the two links to `{% url 'home' %}` become `{% url 'posts:timeline' %}`.

> **If you know Django:** these are Django's class-based views, configured with keywords
> instead of subclassing. To customise a step, pass a hook such as
> `get_queryset = v -> ...` or `get_context_data = (v, ctx) -> ...`. You'll do that in chapter 4.

## Templates for posts

A post looks the same on the timeline, on a profile, and on its own page, so write its HTML
once, in `posts/templates/posts/_post.html`:

```html
<article class="post">
  <header>
    <a class="author" href="{{ post.author.get_absolute_url }}">{{ post.author.name }}</a>
    <span class="handle">@{{ post.author.username }}</span> ·
    <a class="when" href="{{ post.get_absolute_url }}" title="{{ post.created|date:'j M Y, H:i' }}">{{ post.created|timesince }} ago</a>
  </header>
  <p class="body">{{ post.body|linebreaksbr }}</p>
</article>
```

The leading underscore is just a convention for "a piece of a page, not a page". Templates can
follow relations (`post.author.name`) and call `get_absolute_url`. `timesince` turns a time into
"3 hours" or "2 days, 4 hours".

The timeline, `posts/templates/posts/timeline.html`:

```html
{% extends "base.html" %}

{% block content %}
  {% if page_obj.number == 1 %}
    <section class="hero">
      <h1>Welcome to Juangout</h1>
      <p>Say what's on your mind. Briefly.</p>
    </section>
  {% endif %}

  {% for post in post_list %}
    {% include "posts/_post.html" %}
  {% empty %}
    <p class="empty">Nothing to read yet.</p>
  {% endfor %}

  {% include "_pagination.html" %}
{% endblock %}
```

`{% include %}` inserts another template, which sees the same variables, including the loop's
`post`. `{% empty %}` is what a `for` loop shows when there's nothing to loop over.

The links between pages go in the project's `templates/_pagination.html`, so every paginated
list can use them:

```html
{% if is_paginated %}
  <nav class="pagination">
    {% if page_obj.has_previous %}<a href="?page={{ page_obj.previous_page_number }}">← Newer</a>{% endif %}
    <span>Page {{ page_obj.number }} of {{ paginator.num_pages }}</span>
    {% if page_obj.has_next %}<a href="?page={{ page_obj.next_page_number }}">Older →</a>{% endif %}
  </nav>
{% endif %}
```

A post's own page, `posts/templates/posts/detail.html`:

```html
{% extends "base.html" %}

{% block title %}{{ post.author.name }}: “{{ post.body|truncatechars:40 }}” · Juangout{% endblock %}

{% block content %}
  {% include "posts/_post.html" %}
  <p><a href="{% url 'posts:timeline' %}">← Back to the timeline</a></p>
{% endblock %}
```

And profiles list the member's posts, using the reverse relation. Add this to the end of the
`content` block in `accounts/templates/accounts/profile.html`:

```html
  <h2 class="section-title">Posts</h2>
  {% for post in member.posts %}
    {% include "posts/_post.html" %}
  {% empty %}
    <p class="empty">{{ member.name }} hasn't posted anything yet.</p>
  {% endfor %}
```

The `accounts` template includes a `posts` template. That works because Juango searches every
app's `templates/` directory. It's also why the app's name is in each template's path.

Some CSS for posts and pagination, at the end of `static/style.css`:

```css
.section-title { font-size: 1rem; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 2rem 0 .75rem; }

.post {
  background: var(--card); border: 1px solid var(--line); border-radius: 10px;
  padding: .85rem 1rem; margin-bottom: .75rem;
}
.post header { font-size: .92rem; color: var(--muted); }
.post .author { font-weight: 700; color: var(--ink); text-decoration: none; }
.post .author:hover { text-decoration: underline; }
.post .when { color: var(--muted); text-decoration: none; }
.post .when:hover { text-decoration: underline; }
.post .body { margin: .35rem 0 0; white-space: normal; overflow-wrap: anywhere; }

.pagination { display: flex; justify-content: space-between; align-items: center; margin-top: 1.25rem; color: var(--muted); }
.pagination a { text-decoration: none; font-weight: 600; }
```

## Demo data: a management command

An empty timeline is hard to design for. Rather than type posts into the admin, write a
command that makes some. `posts/commands.jl`:

```julia
# `julia --project manage.jl seed`: some members and posts to look at while developing.
const DEMO_MEMBERS = [
    ("ann", "Ann Lee", "Gardener, cyclist, occasional poet."),
    ("bob", "", ""),
    ("chen", "Chen Wei", "I write Julia for a living and for fun."),
    ("dee", "Dee", "Mostly here for the cat pictures."),
]

const DEMO_POSTS = [
    "First post! Is this thing on?",
    "The tomatoes are finally turning red.",
    "Hot take: tabs in YAML should be a criminal offence.",
    "Rode 60 km today and only got lost twice.",
    "Just discovered that Julia's REPL has a shell mode. Press ; and you're in.",
    "Does anyone else read the last page of a book first?",
    "Rain again. The garden is happy, I am not.",
    "Multiple dispatch is the best idea in programming languages and I will not be taking questions.",
    "Made bread. It's flat, but it's bread.",
    "The cat has claimed my keyboard. Send help.",
    "Today I learned that octopuses have three hearts.",
    "Coffee number four. Productivity unchanged.",
]

function seed(args)
    members = map(DEMO_MEMBERS) do (username, display_name, bio)
        m = first(filter(get_user_model(); username), 1)
        isempty(m) ? create_user(username; password = "juangout-demo", display_name, bio) : only(m)
    end
    for (i, body) in enumerate(DEMO_POSTS)
        p = create(Post; author = members[mod1(i, length(members))], body)
        p.created = timezone_now() - Minute(17 * (length(DEMO_POSTS) - i) + rand(0:9))
        save!(p)
    end
    println("Created $(length(DEMO_POSTS)) posts by $(length(members)) members (password: juangout-demo).")
end
```

The `commands` entry in `App(...)` registers it, and `manage.jl help` lists it with its
description:

```sh
julia --project manage.jl seed
```

```
Created 12 posts by 4 members (password: juangout-demo).
```

The command reuses members that already exist, so you can run it more than once. It backdates
each post with `timezone_now()` (the current time in UTC) minus a few minutes, so the timeline
looks lived-in. Start the server and look at the timeline, a few profiles, and a post's own
page.

## Tests

`posts/tests.jl` tests the model, the views and pagination:

```julia
using Test
using Juango.Testing

@testset "posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        first_post = create(Post; author = ann, body = "Hello, Juangout!")
        first_post.created = timezone_now() - Minute(5); save!(first_post)    # so the order is certain
        create(Post; author = bob, body = "Bob was here")

        # the ORM
        @test count(objects(Post)) == 2
        @test count(ann.posts) == 1                          # the reverse relation
        @test first_post.author == ann
        @test only(filter(Post; author__username = "bob")).body == "Bob was here"
        @test first(objects(Post)).body == "Bob was here"     # Meta ordering: newest first

        # the timeline
        c = Client()
        r = get(c, "/")
        @test r.status == 200
        @test assert_template_used(r, "posts/timeline.html")
        @test assert_contains(r, "Hello, Juangout!")
        @test assert_contains(r, "Ann Lee")
        @test assert_contains(r, get_absolute_url(first_post))  # links to the post

        # a post's page
        r = get(c, get_absolute_url(first_post))
        @test r.status == 200
        @test r.context["post"] == first_post
        @test get(c, "/posts/999999/").status == 404

        # profiles list the member's posts
        r = get(c, get_absolute_url(ann))
        @test assert_contains(r, "Hello, Juangout!")
        @test assert_not_contains(r, "Bob was here")
    end
end

@testset "timeline pagination" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        for i in 1:25
            create(Post; author = ann, body = "Post number $i")
        end
        c = Client()
        r = get(c, "/")
        @test length(r.context["post_list"]) == 20
        @test r.context["is_paginated"]
        @test assert_contains(r, "Older →")

        r = get(c, "/?page=2")
        @test length(r.context["post_list"]) == 5
        @test assert_not_contains(r, "Welcome to Juangout")    # the welcome is only on page 1
        @test get(c, "/?page=3").status == 404
    end
end

@testset "post validation" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        @test isempty(full_clean(Post(; author = ann, body = "short and sweet")))
        errs = full_clean(Post(; author = ann, body = "x"^281))
        @test haskey(errs, :body)
    end
end
```

`full_clean` validates an instance without saving it, and returns its errors by field. A post
longer than 280 characters fails. Note that `create` doesn't validate: validation is the job
of forms, which you'll meet in the next chapter, and they call `full_clean` for you.

Add `tests/test_posts.jl`, as you did for accounts:

```julia
# manage.jl test only looks in tests/ for now (Juango #239), so run the app's tests from here.
include(joinpath(@__DIR__, "..", "posts", "tests.jl"))
```

In `tests/test_pages.jl`, the home page is now the timeline, so change `"home.html"` to
`"posts/timeline.html"`. Then run the tests:

```sh
julia --project manage.jl test
```

## Summary

- A **`ForeignKey`** links a row to another model's row, and `related_name` names the reverse
  relation (`member.posts`).
- **`objects`, `filter`, `exclude`, `order_by` and slicing** build lazy **QuerySets**. `get`,
  `create`, `save!` and `delete!` work on single rows, and lookups use `field__lookup = value`.
- **`ListView`** and **`DetailView`** are configured, not written. `paginate_by` adds
  pagination.
- `{% include %}` reuses template fragments, and filters such as `timesince`, `truncatechars`
  and `date` format values.
- Apps can add **management commands** through `App(...; commands = ...)`.

The code at this point is tagged `ch03`.

Posts can only be written in the admin so far. In chapter 4 members get to sign up, log in,
and write their own.
