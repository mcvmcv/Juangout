# Chapter 6: Replies and threads

Conversations need replies. In this chapter a post can answer another post, and each post's
page shows its thread. Then you'll look at the cost: how many database queries a page runs,
why that number can grow with every post on it, and how to keep it small and constant. Along
the way you'll meet Juango's tools for spotting the problem.

Juango ideas in this chapter: **self-referencing foreign keys**, `__isnull` lookups,
`{% include ... with %}`, **`Count(...; distinct = true)`**, **N+1 queries**,
**`select_related`** and **`prefetch_related`**, the **debug toolbar**, and **query-count
tests**.

## A reply is a post

A reply is a post with one extra piece of information: the post it answers. So it doesn't
need a model of its own. Give `Post` a foreign key to another `Post`:

```julia
@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    # the post this one answers, if it's a reply (deleting a post deletes its replies)
    reply_to = ForeignKey(:self; null = true, blank = true, on_delete = :CASCADE, related_name = :replies)
    # the members who like this post, stored as Like rows
    likers = ManyToManyField(USER_MODEL; through = :Like, related_name = :liked_posts, blank = true)
    Meta(ordering = ["-created"])
end
```

`:self` points the foreign key at the model it's in. **`null = true`** lets the column be
empty in the database, because most posts aren't replies. (`blank = true` is the forms' half
of the same idea: the field may be left empty.) `post.reply_to` is the post a reply answers,
or `nothing`, and `post.replies` is a post's replies.

```sh
julia --project manage.jl makemigrations
```

```
Migrations for 'posts':
  posts/migrations/0003_add_post_reply_to_id.jl
    - Add field reply_to_id to post
```

This time the migration *alters* an existing table, adding a column. Existing posts get `NULL`,
which is why the field had to allow it. Run `migrate`.

## Writing replies

Writing a reply is writing a post with `reply_to` set, so `post_create` can do both. It takes
an optional `id`, the post being answered:

```julia
# The form for writing a post: a ModelForm builds its fields from the model's.
post_form(data = nothing; instance = nothing, label = "What's on your mind?") =
    ModelForm(Post; data, instance, fields = [:body], labels = Dict(:body => label))

# Writing a post or a reply: GET shows the form, a valid POST saves it and redirects,
# an invalid POST shows the form again with its errors.
function post_create(req; id = nothing)
    parent = id === nothing ? nothing : get_object_or_404(Post; id)
    form = post_form(req.method == "POST" ? req.POST : nothing;
                     instance = Post(; author = req.user, reply_to = parent),
                     label = parent === nothing ? "What's on your mind?" : "Your reply")
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, parent === nothing ? "Posted." : "Replied.")
        return parent === nothing ? redirect("posts:timeline") : redirect(parent)
    end
    render(req, "posts/compose.html", Dict("form" => form, "parent" => parent))
end
```

One view, two URLs. The new one captures the id:

```julia
    path("posts/<int:id>/reply/", login_required(post_create); name = "reply"),
```

The compose form now posts to whichever URL fits. In `posts/_compose_form.html`:

```html
{# The form for a new post, or for a reply when `reply_to` is set. #}
<form method="post" class="form compose"
      action="{% if reply_to %}{% url 'posts:reply' reply_to.id %}{% else %}{% url 'posts:create' %}{% endif %}">
  {% csrf_token %}
  {{ form.as_div }}
  <button type="submit">{% if reply_to %}Reply{% else %}Post{% endif %}</button>
</form>
```

**`{% include "..." with name=value %}`** passes extra variables to an included template.
`compose.html`, the page you see when a reply has an error, uses it:

```html
{% extends "base.html" %}

{% block title %}{% if parent %}Reply{% else %}New post{% endif %} · Juangout{% endblock %}

{% block content %}
  {% if parent %}
    <h1>Reply to {{ parent.author.name }}</h1>
    <blockquote class="quoted">{{ parent.body|linebreaksbr }}</blockquote>
    {% include "posts/_compose_form.html" with reply_to=parent %}
  {% else %}
    <h1>New post</h1>
    {% include "posts/_compose_form.html" %}
  {% endif %}
{% endblock %}
```

## Threads

Timelines show the first post of each conversation, and its replies live on its own page.
Add a helper to `posts/views.jl` and use it in both timelines:

```julia
# Timelines show conversations' first posts; replies are on each post's page.
top_level(posts) = filter(posts; reply_to__isnull = true)
```

The `isnull` lookup finds rows where a column is (or with `false`, isn't) empty.

A post's page shows the post it replies to (if any), the post itself, a reply form, and the
replies, oldest first so they read as a conversation:

```julia
# A post's page: the post it replies to (if any), the post, a reply form, and the replies,
# oldest first so they read as a conversation.
const post_detail = DetailView(Post; template = "posts/detail.html",
    get_queryset = v -> for_display(objects(Post), v.request.user),
    get_context_data = function (v, ctx)
        post, user = v.object, v.request.user
        ctx["parent"] = post.reply_to_id === nothing ? nothing :
                        first(for_display(filter(Post; id = post.reply_to_id), user))
        ctx["replies"] = order_by(for_display(post.replies, user), "created")
        ctx["form"] = post_form(; label = "Your reply")
        ctx
    end)
```

`for_display` is the new name for chapter 5's `with_like_info`, which is about to do more
than likes. It's coming up next. In the `get_context_data` hook, `v.object` is the post the
view found. The hook is long enough to deserve `function (v, ctx) ... end` instead of `->`.

`posts/templates/posts/detail.html`:

```html
{% extends "base.html" %}

{% block title %}{{ post.author.name }}: “{{ post.body|truncatechars:40 }}” · Juangout{% endblock %}

{% block content %}
  {% if parent %}
    <div class="thread-parent">
      {% include "posts/_post.html" with post=parent %}
    </div>
  {% endif %}

  <div class="thread-focus">
    {% include "posts/_post.html" %}
  </div>

  {% if user.is_authenticated %}
    {% include "posts/_compose_form.html" with reply_to=post %}
  {% endif %}

  <h2 class="section-title">{{ post.reply_count }} repl{{ post.reply_count|pluralize:"y,ies" }}</h2>
  <div class="replies">
    {% for reply in replies %}
      {% include "posts/_post.html" with post=reply %}
    {% empty %}
      <p class="empty">No replies yet.</p>
    {% endfor %}
  </div>
{% endblock %}
```

`pluralize:"y,ies"` gives the singular and plural endings: "1 reply", "3 replies". `_post.html`
gets two additions: a "replying to" line in the `<header>`, after the delete link,

```html
    {% if post.reply_to %}
      <div class="replying-to">replying to <a href="{{ post.reply_to.get_absolute_url }}">@{{ post.reply_to.author.username }}</a></div>
    {% endif %}
```

and a reply count, linking to the thread, at the start of the `<footer>`:

```html
    <a class="replies-link" href="{{ post.get_absolute_url }}" title="Replies">💬 {{ post.reply_count }}</a>
```

The CSS:

```css
/* replies and threads */
.replies-link { color: var(--muted); text-decoration: none; margin-right: .75rem; }
.replies-link:hover { color: var(--accent); }
.replying-to { font-size: .85rem; }
.replying-to a { color: var(--muted); }
.thread-parent .post { border-bottom-left-radius: 0; border-bottom-right-radius: 0; margin-bottom: 0; opacity: .85; }
.thread-focus .post { border-color: var(--accent); }
.replies { margin-left: 1.25rem; padding-left: .75rem; border-left: 2px solid var(--line); }
.quoted { margin: 0 0 1rem; padding: .5rem 1rem; border-left: 3px solid var(--line); color: var(--muted); }
```

(Also remove the `margin-left: -.5rem;` from the `button.like, span.like` rule. The like
button no longer comes first in the footer.)

## Counting two things at once

Each post now shows two counts. The obvious change to chapter 5's function is to add a
second `Count`:

```julia
annotate(posts; like_count = Count(:likers), reply_count = Count(:replies))     # wrong!
```

Try it on a post with 2 likes and 3 replies, and both counts come out as **6**. To count
both, the database joins each post to its likes *and* to its replies, which makes one row for
every like-and-reply pair: 2 × 3 = 6. Counting rows of that join counts pairs. The fix is to
count *distinct* likers and replies:

```julia
like_count = Count(:likers; distinct = true),
reply_count = Count(:replies; distinct = true),
```

This is the classic aggregation trap, so it gets its own test below.

## How many queries does a page run?

Start the server with the demo data (`julia --project manage.jl seed`) and watch its log
while you load the timeline:

```
┌ Warning: N+1 queries: Post.author was loaded for 20 objects one at a time in one request (in a template). Add select_related(:author) to the queryset.
```

Juango is pointing at a problem that has been there since chapter 3. The timeline fetches
its 20 posts in one query. Then the template shows `{{ post.author.name }}` for each one,
and each `post.author` is fetched separately, when it's first used: 20 more queries. One query
for the list plus *N* for the authors is called an **N+1** problem. It's invisible with 12
posts on your laptop, and it's the most common reason a web app gets slow as its data grows.

### Seeing it: the debug toolbar

Juango has a **debug toolbar**: a panel on every page that lists the SQL the page ran, the
templates it rendered, and how long everything took. Turn it on for development in
`settings.jl`:

```julia
debug = env("DEBUG", Bool; default = true)

configure!(
    DEBUG = debug,
    # in development, a panel on every page with its SQL queries, templates and timings
    MIDDLEWARE = debug ? [DebugToolbarMiddleware, Juango.default_settings()[:MIDDLEWARE]...] :
                         Juango.default_settings()[:MIDDLEWARE],
    INTERNAL_IPS = ["127.0.0.1", "::1"],
    # ... the rest as before
```

**Middleware** is code that runs on every request and response: sessions, authentication,
CSRF and messages are all middleware. This puts the toolbar's in front of Juango's default
list. It shows only while `DEBUG` is on, and only to browsers on your own machine
(`INTERNAL_IPS`). Reload the timeline and open the SQL panel. Queries that differ only in their
parameters are grouped as "similar", and there will be a stack of `SELECT ... FROM "member"
WHERE "id" = ?`, one per post.

### Fixing it: `select_related`

`select_related` fetches related objects in the same query, with a SQL `JOIN`. With ten posts
in the database:

```julia
julia> _, n = count_queries(() -> [p.author.username for p in objects(Post)]); n
11

julia> _, n = count_queries(() -> [p.author.username for p in select_related(objects(Post), :author)]); n
1
```

(`count_queries(f)` runs `f` and returns its result and the number of queries it ran.) Here is
the finished `for_display`, which replaces `with_like_info` in `posts/models.jl`:

```julia
"""
    for_display(posts, user)

The posts, ready for the `posts/_post.html` template: with `like_count`, `reply_count` and
`liked` (whether `user` likes the post), each post's author (and the author of the post it
replies to) fetched in the same query, newest first.
"""
function for_display(posts, user)
    posts = annotate(posts;
        # two counts over two different relations: distinct, or each would multiply the other
        like_count = Count(:likers; distinct = true),
        reply_count = Count(:replies; distinct = true),
        liked = is_authenticated(user) ? Exists(filter(Like; post = OuterRef(:id), member = user)) : Value(false))
    posts = select_related(posts, :author, :reply_to__author)
    # Count makes this a GROUP BY query, which leaves out Meta.ordering, so order explicitly
    order_by(posts, "-created")
end
```

`:reply_to__author` follows two foreign keys: the post a reply answers, and *its* author, for
the "replying to @..." line. Rename the function everywhere it's used: in the views, in
`export Post, Like, for_display` in `Posts.jl`, in `using ..Posts: for_display` in
`Accounts.jl`, and in the profile view.

Everything a post's template needs now arrives in one query per list, however many posts
there are. The timeline, a profile and a thread each run the same handful of queries
whether they show 3 posts or 20.

### The other direction: `prefetch_related`

`select_related` follows foreign keys forwards: from a post to *its one* author. For the other
direction (a post's *many* likers, or a member's posts) a join would repeat each post once per
liker. **`prefetch_related`** fetches them in one separate query for the whole list, and
matches them up in Julia:

```julia
julia> _, n = count_queries(() -> [[m.username for m in p.likers] for p in objects(Post)]); n
11

julia> _, n = count_queries(() -> [[m.username for m in p.likers] for p in prefetch_related(objects(Post), :likers)]); n
2
```

Juangout doesn't list likers' names yet, so it doesn't need `prefetch_related` today. But
it's the tool you'll want when a page shows "liked by ann, bob and 3 others" under each post.

> **If you know Django:** `select_related`, `prefetch_related` and `Prefetch(...)` work as in
> Django. Juango's built-in N+1 detector is like the `nplusone` package, and the toolbar is
> django-debug-toolbar.

## Tests

Two kinds of test this time: replies, and **query budgets**. In `posts/tests.jl`:

```julia
@testset "replies" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        question = create(Post; author = ann, body = "Tabs or spaces?")
        c = Client()
        force_login!(c, bob)

        r = post(c, "/posts/$(question.id)/reply/", Dict("body" => "Spaces, obviously"); follow = true)
        @test assert_contains(r, "Replied.")
        @test r.context["post"] == question                    # back on the question's page
        answer = only(question.replies)
        @test answer.author == bob
        @test answer.reply_to == question

        # the question's page shows the reply and counts it
        @test [p.body for p in r.context["replies"]] == ["Spaces, obviously"]
        @test r.context["post"].reply_count == 1
        # the reply's page shows what it replies to
        r = get(c, get_absolute_url(answer))
        @test r.context["parent"] == question
        @test assert_contains(r, "replying to")

        # timelines show only conversations' first posts; profiles show replies too
        @test [p.body for p in get(c, "/everyone/").context["post_list"]] == ["Tabs or spaces?"]
        @test assert_contains(get(c, "/@bob/"), "Spaces, obviously")

        @test post(c, "/posts/999999/reply/", Dict("body" => "?")).status == 404
        # deleting a post deletes its replies
        delete!(question)
        @test count(objects(Post)) == 0
    end
end

@testset "counting likes and replies together" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "Popular")
        add!(p.likers, ann, bob)
        for i in 1:3
            create(Post; author = bob, body = "reply $i", reply_to = p)
        end
        # Without distinct = true, joining both likes and replies would give 2 × 3 = 6 of each
        row = first(for_display(filter(Post; id = p.id), ann))
        @test row.like_count == 2
        @test row.reply_count == 3
    end
end

@testset "queries per page" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        add!(ann.following, bob)
        c = Client()
        force_login!(c, ann)

        # NPLUSONE = :raise turns Juango's N+1 warning into an error
        override_settings(DEBUG = true, NPLUSONE = :raise) do
            make_posts(n) = for i in 1:n
                p = create(Post; author = isodd(i) ? ann : bob, body = "post $i")
                create(Post; author = bob, body = "reply to $i", reply_to = p)
            end
            make_posts(3)
            _, few = count_queries(() -> get(c, "/"))
            make_posts(15)
            _, many = count_queries(() -> get(c, "/"))
            @test few == many                 # the same number of queries, however many posts

            q = first(filter(Post; reply_to__isnull = true))
            for url in ("/", "/everyone/", "/@bob/", get_absolute_url(q), get_absolute_url(first(q.replies)))
                @test get(c, url).status == 200
            end
        end
    end
end
```

The last test guards performance in two ways:

- It loads the timeline with a few posts and then with many, and checks that the **number of
  queries doesn't change**. That's the definition of "no N+1". Pinning an exact number
  (`assert_num_queries(f, 7)`) works too, but breaks whenever you add an unrelated query.
- **`override_settings(NPLUSONE = :raise)`** makes Juango's N+1 detector throw an error instead
  of logging a warning, so if anyone removes a `select_related`, loading those pages fails the
  test. Here's what a page that forgot it gets:

  ```
  NPlusOneError: N+1 queries: Post.author was loaded for 5 objects one at a time in one request
  (from ... in a template). Add select_related(:author) to the queryset.
  ```

`override_settings` changes settings only for the block. The detector only works while `DEBUG`
is on, so the block turns it on explicitly, in case the tests run with it off. (Django's test
runner always switches `DEBUG` off. Juango's doesn't yet,
[#249](https://github.com/mcvmcv/Juango/issues/249).)

## Summary

- **`ForeignKey(:self; null = true)`** makes a model point at itself: replies, threads, trees.
  `__isnull` finds rows with or without one.
- **`{% include ... with name=value %}`** passes variables to included templates.
- Two aggregates over different relations multiply each other. Use **`Count(...; distinct = true)`**.
- An **N+1** problem is one query per row for related data. Juango warns about it in
  development, and the **debug toolbar** shows every query.
- **`select_related`** joins forward foreign keys into the same query, and **`prefetch_related`**
  fetches reverse and many-to-many relations in one extra query.
- Test query budgets with **`count_queries`** or `assert_num_queries`, and with
  **`NPLUSONE = :raise`**.

The code at this point is tagged `ch06`.

In chapter 7 members get faces: avatars, and pictures in posts.
