# Chapter 5: Follows and likes

A social network is about connections. In this chapter members **follow** each other, the
home timeline shows posts by the people you follow, and members **like** posts. You'll
model both with **many-to-many relations** that have a model of their own, count likes with
**annotations**, and meet **constraints** that the database enforces.

Juango ideas in this chapter: **`ManyToManyField`** (self-referential, with a `through`
model), `add!` and `remove!`, **`Q` objects** for OR conditions, **`annotate`** with `Count`
and `Exists`, **`UniqueConstraint`** and **`CheckConstraint`**, `require_POST`, and
transactions in tests.

## Follows: a relation from members to members

A foreign key links each post to *one* author. Following is different: a member can follow
many members, and be followed by many. That's a **many-to-many** relation, and in the
database it's a separate table with one row per pair, "Ann follows Bob".

Juango can make that table for you, but follows deserve a model of their own, so that each
follow can record *when* it happened. A model that stands in the middle of a many-to-many
relation is called a **through model**. Add it to the end of `accounts/models.jl`:

```julia
# One member following another. An explicit "through" model, so it can record when.
@model struct Follow
    follower = ForeignKey(Member; on_delete = :CASCADE, related_name = :outgoing_follows)
    followed = ForeignKey(Member; on_delete = :CASCADE, related_name = :incoming_follows)
    created = DateTimeField(auto_now_add = true)
    Meta(constraints = [
        UniqueConstraint(fields = [:follower, :followed], name = "follow_once"),
        CheckConstraint(condition = !Q(follower = F(:followed)), name = "no_following_yourself"),
    ])
end
```

Both foreign keys point at `Member`, so each needs its own `related_name`. Otherwise both
reverse relations would get the same default name. The two **constraints** are rules that
the database itself enforces, whatever code is writing to it:

- `UniqueConstraint` means you can follow someone only once.
- `CheckConstraint` says the follower may not be the member being followed. `F(:followed)`
  refers to the value of another column in the same row, and `!` negates the `Q` condition.

Then give `Member` the relation itself:

```julia
@model struct Member <: AbstractUser
    display_name = CharField(max_length = 50, blank = true,
                             help_text = "The name shown on your posts. Leave blank to use your username.")
    bio = TextField(max_length = 300, blank = true)
    # who this member follows: a one-way relation from members to members, stored as Follow rows
    following = ManyToManyField(:self; symmetrical = false, through = :Follow,
                                through_fields = (:follower, :followed), related_name = :followers, blank = true)
end
```

- **`:self`** means the relation goes from members to other members.
- **`symmetrical = false`**: following is one-way. (A symmetrical relation, like friendship,
  would add the reverse link automatically.)
- **`through = :Follow`** names the through model. It's a symbol because `Follow` is defined
  later in the file.
- **`through_fields = (:follower, :followed)`** says which of `Follow`'s two foreign keys is
  "this member" and which is "the member followed". Juango can't guess when both point at
  `Member`.
- **`related_name = :followers`** names the other direction. `ann.following` is everyone Ann
  follows, and `ann.followers` is everyone who follows Ann.

Export `Follow` from `Accounts.jl` (`export Member, Follow`).

## Likes

Likes are another many-to-many relation, between members and posts. In `posts/models.jl`, add
a field to `Post` and a through model:

```julia
@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    # the members who like this post, stored as Like rows
    likers = ManyToManyField(USER_MODEL; through = :Like, related_name = :liked_posts, blank = true)
    Meta(ordering = ["-created"])
end

@model struct Like
    member = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :likes)
    post = ForeignKey(Post; on_delete = :CASCADE, related_name = :likes)
    created = DateTimeField(auto_now_add = true)
    Meta(constraints = [UniqueConstraint(fields = [:member, :post], name = "like_once")])
end
```

`post.likers` is everyone who likes a post, and `member.liked_posts` is every post a member
likes. Make the migrations:

```sh
julia --project manage.jl makemigrations
```

```
Migrations for 'accounts':
  accounts/migrations/0002_follow.jl
    - Create model Follow (table follow)
Migrations for 'posts':
  posts/migrations/0002_like.jl
    - Create model Like (table like)
```

The `ManyToManyField`s themselves add no columns: the relation lives entirely in the through
tables. Run `migrate`.

## Working with many-to-many relations

Try it at the REPL (`julia --project -i manage.jl`):

```julia
julia> ann = get(Member; username = "ann"); bob = get(Member; username = "bob");

julia> add!(ann.following, bob)          # creates a Follow row

julia> bob in ann.following
true

julia> ann in bob.followers
true

julia> ann in bob.following              # one-way
false

julia> count(ann.following)
1

julia> remove!(ann.following, bob)       # deletes the Follow row
```

`ann.following` is a QuerySet of members, so everything from chapter 3 works on it:
`filter`, `order_by`, `count`, slicing. `add!` skips links that already exist, so adding
twice is harmless. `x in qs` asks the database whether that row is in the queryset, with one
query.

What about the constraint?

```julia
julia> create(Follow; follower = ann, followed = ann)
ERROR: IntegrityError: CHECK constraint failed: no_following_yourself
```

The database refused. Juango doesn't rely on every view remembering to check.

> **If you know Django:** `ManyToManyField("self", symmetrical=False, through="Follow",
> through_fields=(...))` is the same. `add!`, `remove!`, `set!` and `clear!` are the related
> manager's `add`, `remove`, `set` and `clear`, and `obj in qs` is `qs.contains(obj)`.

## Follow buttons

Following changes data, so it's a POST, like logging out. Add two views to
`accounts/views.jl`:

```julia
# Follow and unfollow: POSTs from the button on a profile.
function follow(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    if member.id == req.user.id
        message!(req, :error, "You can't follow yourself.")
    else
        add!(req.user.following, member)
        message!(req, :success, "You're following $(member.name).")
    end
    redirect(member)
end

function unfollow(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    remove!(req.user.following, member)
    message!(req, :success, "You've unfollowed $(member.name).")
    redirect(member)
end
```

`redirect(member)` redirects to the member's `get_absolute_url`. The constraint would stop a
self-follow anyway, but checking first gives a friendly message instead of an error page.

The profile page now shows follower counts and the button. Replace the `profile` view:

```julia
function profile(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    me = req.user
    render(req, "accounts/profile.html", Dict(
        "member" => member,
        "posts" => with_like_info(member.posts, me)[1:20],
        "follower_count" => count(member.followers),
        "following_count" => count(member.following),
        "is_me" => is_authenticated(me) && me.id == member.id,
        "i_follow" => is_authenticated(me) && member in me.following,
        "follows_me" => is_authenticated(me) && me in member.following,
    ))
end
```

(`with_like_info` is coming up in the section on likes.) Lists of followers and of followed
members are two more pages. They differ only in which relation they show, so one function
makes both `ListView`s:

```julia
# Who follows a member, and whom they follow: one ListView, two querysets.
function member_list(relation, heading)
    ListView(Member; template = "accounts/member_list.html", paginate_by = 50,
        get_queryset = v -> order_by(relation(get_object_or_404(Member; username = v.kwargs[:username])), "username"),
        get_context_data = (v, ctx) -> begin
            ctx["member"] = get(Member; username = v.kwargs[:username])
            ctx["heading"] = heading
            ctx
        end)
end
const followers = member_list(m -> m.followers, "Followers")
const following = member_list(m -> m.following, "Following")
```

`v.kwargs` holds the values captured from the URL. The URLs, in `accounts/urls.jl`:

```julia
const urlpatterns = [
    path("@<str:username>/", profile; name = "profile"),     # {% url 'accounts:profile' username %}
    path("@<str:username>/followers/", followers; name = "followers"),
    path("@<str:username>/following/", following; name = "following"),
    path("@<str:username>/follow/", require_POST(login_required(follow)); name = "follow"),
    path("@<str:username>/unfollow/", require_POST(login_required(unfollow)); name = "unfollow"),
    path("accounts/signup/", signup; name = "signup"),
    path("accounts/profile/", profile_edit; name = "profile_edit"),
]
```

**`require_POST`** answers anything but a POST with "405 Method Not Allowed". Wrappers like
this and `login_required` nest: each takes a view and returns a view.

The profile template, `accounts/templates/accounts/profile.html`, in full:

```html
{% extends "base.html" %}

{% block title %}{{ member.name }} (@{{ member.username }}) · Juangout{% endblock %}

{% block content %}
  <section class="profile">
    <h1>{{ member.name }}</h1>
    <p class="handle">@{{ member.username }}{% if follows_me %} <span class="badge">follows you</span>{% endif %}
       · joined {{ member.date_joined|date:"F Y" }}</p>
    {% if member.bio %}<p class="bio">{{ member.bio|linebreaksbr }}</p>{% endif %}
    <p class="counts">
      <a href="{% url 'accounts:followers' member.username %}"><strong>{{ follower_count }}</strong> follower{{ follower_count|pluralize }}</a>
      <a href="{% url 'accounts:following' member.username %}"><strong>{{ following_count }}</strong> following</a>
    </p>
    {% if user.is_authenticated and not is_me %}
      {% if i_follow %}
        <form method="post" action="{% url 'accounts:unfollow' member.username %}">
          {% csrf_token %}<button type="submit" class="secondary">Unfollow</button>
        </form>
      {% else %}
        <form method="post" action="{% url 'accounts:follow' member.username %}">
          {% csrf_token %}<button type="submit">Follow</button>
        </form>
      {% endif %}
    {% endif %}
  </section>

  <h2 class="section-title">Posts</h2>
  {% for post in posts %}
    {% include "posts/_post.html" %}
  {% empty %}
    <p class="empty">{{ member.name }} hasn't posted anything yet.</p>
  {% endfor %}
{% endblock %}
```

`pluralize` adds an "s" unless the number is 1: "1 follower", "2 followers".
`accounts/templates/accounts/member_list.html` lists members:

```html
{% extends "base.html" %}

{% block title %}{{ heading }} of {{ member.name }} · Juangout{% endblock %}

{% block content %}
  <p><a href="{{ member.get_absolute_url }}">← {{ member.name }}</a></p>
  <h1>{{ heading }}</h1>
  <ul class="members">
    {% for m in member_list %}
      <li><a class="author" href="{{ m.get_absolute_url }}">{{ m.name }}</a> <span class="handle">@{{ m.username }}</span>
        {% if m.bio %}<br><span class="bio">{{ m.bio|truncatechars:80 }}</span>{% endif %}</li>
    {% empty %}
      <li class="empty">Nobody yet.</li>
    {% endfor %}
  </ul>
  {% include "_pagination.html" %}
{% endblock %}
```

## Your timeline

Now the home timeline can be *yours*: posts by the people you follow, plus your own. In
`posts/views.jl`:

```julia
# What a member's home timeline shows: posts by the people they follow, and their own.
# Visitors who aren't logged in see everyone's.
function feed(user)
    is_authenticated(user) || return objects(Post)
    filter(Post, Q(author__in = user.following) | Q(author = user))
end
```

Keyword arguments to `filter` are always combined with AND. For OR, build **`Q` objects** and
combine them with `|` (OR), `&` (AND) and `!` (NOT). `author__in = user.following` is "the
author is one of the members the user follows". The `following` queryset becomes a subquery,
so the whole feed is still a single query.

The timeline now gets its posts from a `get_queryset` hook, and an `everyone` view shows all
posts, so there's somewhere to find new people to follow:

```julia
const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> with_like_info(feed(v.request.user), v.request.user),
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "feed"; ctx))

const everyone = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> with_like_info(objects(Post), v.request.user),
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "everyone"; ctx))
```

Add `path("everyone/", everyone; name = "everyone")` to `posts/urls.jl`, and tabs above the
posts in `timeline.html`:

```html
  {% if user.is_authenticated %}
    <nav class="tabs">
      <a href="{% url 'posts:timeline' %}"{% if tab == "feed" %} aria-current="page"{% endif %}>Following</a>
      <a href="{% url 'posts:everyone' %}"{% if tab == "everyone" %} aria-current="page"{% endif %}>Everyone</a>
    </nav>
  {% endif %}
```

A new member's feed is empty, so make the `{% empty %}` message helpful:

```html
  {% empty %}
    {% if tab == "feed" and user.is_authenticated %}
      <p class="empty">Nothing here yet. Follow some people from <a href="{% url 'posts:everyone' %}">Everyone</a>, or write the first post.</p>
    {% else %}
      <p class="empty">Nothing to read yet.</p>
    {% endif %}
  {% endfor %}
```

## Counting likes: annotations

Each post on a page should show how many likes it has, and whether *you* like it. You could
ask the database for each post separately, but a page of 20 posts would then run 40 extra
queries. Instead, ask the database to compute both in the same query that fetches the posts.
That's what **`annotate`** does: it adds computed columns to each row. In `posts/models.jl`:

```julia
"""
    with_like_info(posts, user)

The posts with two extra columns for templates: `like_count`, and `liked` (whether `user`
likes the post).
"""
function with_like_info(posts, user)
    # Count makes this a GROUP BY query, which leaves out Meta.ordering, so order explicitly
    posts = order_by(annotate(posts; like_count = Count(:likers)), "-created")
    is_authenticated(user) || return annotate(posts; liked = Value(false))
    annotate(posts; liked = Exists(filter(Like; post = OuterRef(:id), member = user)))
end
```

- **`Count(:likers)`** counts each post's likers. In SQL that's a join and a `GROUP BY`, but you
  don't have to write it.
- **`Exists(...)`** is true when a subquery finds any rows. Here the subquery asks for "a Like for
  this post by this member", and **`OuterRef(:id)`** means "the id of the post in the outer
  query".
- **`Value(false)`** is a constant column, so templates can rely on `liked` being there even for
  visitors.
- **`order_by` again.** An aggregate such as `Count` turns the query into a `GROUP BY`, and
  for those queries Juango (like Django) leaves out the model's default `Meta.ordering`. Without
  the `order_by` the timeline would come back in whatever order the database likes. It's an
  easy one to miss. With `DEBUG` on, the development server logs a warning ("Paginating an
  unordered Post queryset...") when it happens, and the tests below check the order too.

Annotated values read like fields: `post.like_count`, `{{ post.liked }}`. The function takes any
queryset of posts, so the timeline, the "everyone" page, a post's own page and profiles can all
use it. Export it from `Posts.jl` (`export Post, Like, with_like_info`), and give `post_detail`
the annotated queryset too:

```julia
const post_detail = DetailView(Post; template = "posts/detail.html",
    get_queryset = v -> with_like_info(objects(Post), v.request.user))
```

Profiles use it as well, so the `accounts` app now uses something from `posts`. Load `posts`
first in `project.jl`:

```julia
# (posts first: accounts' profile pages use it)
Juango.project_include(joinpath(BASE_DIR, "posts", "Posts.jl"))
using .Posts
Juango.project_include(joinpath(BASE_DIR, "accounts", "Accounts.jl"))
using .Accounts
```

and import the function in `Accounts.jl`, after `using Dates`:

```julia
using ..Posts: with_like_info     # profiles show posts
```

This works because `posts` never mentions `Member`: its foreign keys point at `USER_MODEL`.

> **If you know Django:** `annotate`, `Count`, `Exists`, `OuterRef`, `Value`, `F` and `Q` are
> the expressions you know from `django.db.models`.

## The like button

Liking is a toggle: one view that likes a post, or unlikes it if you already do. Afterwards
it should go back to whatever page the button was on. In `posts/views.jl`:

```julia
# Like or unlike (a POST from the heart button), then go back to the page it was on.
function like(req; id)
    post = get_object_or_404(Post; id)
    if post in req.user.liked_posts
        remove!(post.likers, req.user)
    else
        add!(post.likers, req.user)
    end
    redirect_back(req, get_absolute_url(post))
end

# The page named by the form's `next` field, if it's on this site (never redirect to a URL
# a visitor could have planted), else `fallback`.
function redirect_back(req, fallback)
    next = get(req.POST, "next", "")
    url_has_allowed_host_and_scheme(next, [Juango.get_host(req)]) ? redirect(next) : redirect(fallback)
end
```

Never redirect to a URL taken from a request without checking it. Otherwise
`https://juangout.example/...?next=https://evil.example` becomes a convincing link to a
phishing site. `url_has_allowed_host_and_scheme` allows only URLs on this site.

The URL: `path("posts/<int:id>/like/", require_POST(login_required(like)); name = "like")`.

The button goes in a `<footer>` at the end of the `<article>` in `posts/_post.html`:

```html
  <footer>
    {% if user.is_authenticated %}
      <form method="post" action="{% url 'posts:like' post.id %}" class="like-form">
        {% csrf_token %}
        <input type="hidden" name="next" value="{{ request.get_full_path }}">
        <button type="submit" class="like{% if post.liked %} liked{% endif %}"
                aria-pressed="{% if post.liked %}true{% else %}false{% endif %}"
                title="{% if post.liked %}Unlike{% else %}Like{% endif %}">♥ {{ post.like_count }}</button>
      </form>
    {% else %}
      <span class="like" title="Likes">♥ {{ post.like_count }}</span>
    {% endif %}
  </footer>
```

Templates can use **`request`**, and `request.get_full_path` is the current path with its query
string, so a like on page 3 of the timeline comes back to page 3. `aria-pressed` tells screen
readers that the button is a toggle and which way it's set.

And the CSS for this chapter:

```css
/* follows and likes */
.post footer { margin-top: .4rem; }
.like-form { display: inline; }
button.like, span.like {
  background: none; color: var(--muted); padding: .1rem .5rem; margin-left: -.5rem;
  font-weight: 400; border-radius: 999px;
}
button.like:hover { color: var(--accent); background: var(--accent-soft); filter: none; }
button.like.liked { color: var(--accent); font-weight: 700; }
button.secondary { background: var(--card); color: var(--ink); border: 1px solid var(--line); }

.counts a { margin-right: 1rem; color: var(--muted); text-decoration: none; }
.counts a strong { color: var(--ink); }
.badge { font-size: .75rem; background: var(--accent-soft); color: var(--accent); padding: .1rem .45rem; border-radius: 4px; }

.tabs { display: flex; gap: 1.25rem; border-bottom: 1px solid var(--line); margin-bottom: 1rem; }
.tabs a { padding: .4rem 0; color: var(--muted); text-decoration: none; border-bottom: 2px solid transparent; margin-bottom: -1px; }
.tabs a[aria-current=page] { color: var(--ink); font-weight: 600; border-bottom-color: var(--accent); }

.members { list-style: none; padding: 0; }
.members li { padding: .6rem 0; border-bottom: 1px solid var(--line); }
.members .handle, .members .bio { color: var(--muted); }
```

Finally, make `seed` add some follows and likes. Before its `println`:

```julia
    # everyone follows a couple of people, and likes some posts
    for (i, m) in enumerate(members)
        add!(m.following, members[mod1(i + 1, length(members))], members[mod1(i + 2, length(members))])
        for p in objects(Post)[1:6]
            rand() < 0.5 && add!(p.likers, m)
        end
    end
```

## Tests

In `accounts/tests.jl`:

```julia
@testset "following" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")

        # the relation, in Julia
        add!(ann.following, bob)
        @test bob in ann.following
        @test ann in bob.followers
        @test !(ann in bob.following)                 # one-way: symmetrical = false
        @test count(Follow) == 1
        add!(ann.following, bob)                      # adding again changes nothing
        @test count(Follow) == 1
        remove!(ann.following, bob)
        @test count(ann.following) == 0

        # the database refuses a member following themselves. A failed write spoils the
        # transaction it's in, so give it a transaction of its own (a savepoint) with atomic.
        @test_throws IntegrityError atomic() do
            create(Follow; follower = ann, followed = ann)
        end

        # through the buttons
        c = Client()
        @test assert_redirects(post(c, "/@bob/follow/"), "/accounts/login/?next=%2F%40bob%2Ffollow%2F")
        force_login!(c, ann)
        @test get(c, "/@bob/follow/").status == 405   # POST only
        r = post(c, "/@bob/follow/"; follow = true)
        @test assert_contains(r, "You&#x27;re following bob.")
        @test r.context["i_follow"]
        @test r.context["follower_count"] == 1
        @test bob in ann.following

        r = post(c, "/@ann/follow/"; follow = true)
        @test assert_contains(r, "You can&#x27;t follow yourself.")

        r = get(Client(), "/@ann/following/")
        @test [m.username for m in r.context["member_list"]] == ["bob"]
        r = get(Client(), "/@bob/followers/")
        @test [m.username for m in r.context["member_list"]] == ["ann"]
        @test get(Client(), "/@nobody/followers/").status == 404

        force_login!(c, bob)
        @test get(c, "/@ann/").context["follows_me"]

        force_login!(c, ann)
        post(c, "/@bob/unfollow/")
        @test count(ann.following) == 0
    end
end
```

Look closely at the `IntegrityError` test. `rollback_after` runs the whole test in one database
transaction. When a statement fails inside a transaction, the database marks the whole
transaction as failed, and Juango refuses to run any more queries in it. Wrapping the failing
write in its own **`atomic()`** block makes it a *savepoint*, a transaction inside the
transaction, so only that part is rolled back and the test can carry on. You'd do the same in
a view that expects a write might fail.

In `posts/tests.jl`:

```julia
@testset "the following feed" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        for (i, m) in enumerate((ann, bob, cat))           # an hour apart, ann's the oldest
            p = create(Post; author = m, body = "by $(m.username)")
            p.created = timezone_now() - Hour(4 - i); save!(p)
        end
        add!(ann.following, bob)

        bodies(r) = Set(p.body for p in r.context["post_list"])
        c = Client()
        @test bodies(get(c, "/")) == Set(["by ann", "by bob", "by cat"])        # visitors see everyone
        force_login!(c, ann)
        @test bodies(get(c, "/")) == Set(["by ann", "by bob"])                  # people ann follows, and ann
        @test bodies(get(c, "/everyone/")) == Set(["by ann", "by bob", "by cat"])
        # newest first, even though like counts make it a GROUP BY query
        @test [p.body for p in get(c, "/everyone/").context["post_list"]] == ["by cat", "by bob", "by ann"]
    end
end

@testset "likes" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        p = create(Post; author = bob, body = "Like me")

        # annotate: one query, with the count and whether this member likes each post
        add!(p.likers, bob)
        row = only(with_like_info(objects(Post), ann))
        @test row.like_count == 1
        @test row.liked == false
        @test only(with_like_info(objects(Post), bob)).liked == true
        @test only(with_like_info(objects(Post), AnonymousUser())).like_count == 1

        # the heart button toggles, and goes back to the page it was on
        c = Client()
        force_login!(c, ann)
        r = post(c, "/posts/$(p.id)/like/", Dict("next" => "/everyone/?page=1"))
        @test assert_redirects(r, "/everyone/?page=1")
        @test ann in p.likers
        @test count(Like) == 2
        r = get(c, "/posts/$(p.id)/")
        @test r.context["post"].like_count == 2
        @test r.context["post"].liked
        @test assert_contains(r, "aria-pressed=\"true\"")

        post(c, "/posts/$(p.id)/like/")
        @test !(ann in p.likers)

        # never redirect off the site
        r = post(c, "/posts/$(p.id)/like/", Dict("next" => "https://evil.example/"))
        @test assert_redirects(r, "/posts/$(p.id)/")
        @test post(Client(), "/posts/$(p.id)/like/").status == 302       # to the login page
        @test get(c, "/posts/$(p.id)/like/").status == 405
    end
end
```

Testing the open-redirect protection takes one line, and it's the kind of test that stops
someone "simplifying" `redirect_back` later.

## Summary

- **`ManyToManyField`** links many rows to many rows. A **`through`** model stores each link
  as a row with extra fields. `:self` and `symmetrical = false` make one-way relations between
  members.
- **`add!`, `remove!` and `obj in qs`** work on relations. Relations are QuerySets, so they
  filter, count and slice.
- **`Q`** objects combine conditions with `|`, `&` and `!`. A queryset used as an `__in` value
  becomes a subquery.
- **`annotate`** adds computed columns, such as `Count`, or `Exists` with `OuterRef`, so a
  page needs one query instead of one per row.
- **Constraints** (`UniqueConstraint`, `CheckConstraint`) are enforced by the database. Wrap
  writes that may fail in `atomic()`.
- **`require_POST`** for views that change things. Check `next` URLs with
  `url_has_allowed_host_and_scheme`.

The code at this point is tagged `ch05`.

The timeline is starting to do a lot of work. In chapter 6 you'll add replies, and then
look at how many queries a page really runs.
