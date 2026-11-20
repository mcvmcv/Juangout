# Chapter 9: Notifications

When someone follows you, likes your post or replies to it, you should hear about it. In this
chapter you'll add a third app, `notifications`, that records these events, shows an unread
count in the header, and emails members about new followers and replies, without the posts
and accounts apps knowing anything about it.

Juango ideas in this chapter: **choices** (`@choices`), **signals** (`post_save`,
`m2m_changed`) and an app's **`ready`** hook, **indexes**, **context processors**, the
**`Paginator`**, bulk **`update!`**, **email** (`send_mail`, backends, `render_to_string`),
**background tasks** (`@background`, `enqueue`), **`on_commit`**, and testing mail with
**`outbox`**.

## The notifications app

Make the app, `julia --project manage.jl startapp notifications`, and delete its sample
template. A notification records who did what to whom. In `notifications/models.jl`:

```julia
# The kinds of notification: a value stored in the database, and a label for people
@choices Verb begin
    FOLLOW = "follow", "followed you"
    LIKE = "like", "liked your post"
    REPLY = "reply", "replied to your post"
end

@model struct Notification
    recipient = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :notifications)
    actor = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :notifications_caused)
    verb = CharField(max_length = 10, choices = Verb)
    post = ForeignKey(Post; null = true, blank = true, on_delete = :CASCADE, related_name = :notifications)
    read = BooleanField(default = false)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"],
         # every page asks "how many unread notifications has this member?"; an index answers fast
         indexes = [Index(:recipient, :read; name = "notification_unread")])
end

Base.show(io::IO, n::Notification) = print(io, n.actor, " ", n.get_verb_display)
```

- **`@choices`** defines a fixed set of values. Each has a short value for the database
  (`"follow"`) and a label for people (`"followed you"`). `choices = Verb` restricts the field to
  those values, in forms and the admin as well. In code you write `Verb.FOLLOW` rather than a
  bare string that a typo could break. **`n.get_verb_display`** gives the label, in Julia and in
  templates.
- **Two foreign keys to the user model**, so each needs a `related_name`: `ann.notifications`
  are the ones Ann receives.
- **`post`** is optional, because follows aren't about a post.
- **An index** makes a common query fast. The unread count, `filter(Notification; recipient =
  me, read = false)`, will run on every page, and an index on those two columns lets the
  database answer without reading the whole table. Foreign keys get an index of their own
  automatically.

The app needs `Post` and `Member`. In `notifications/Notifications.jl`:

```julia
# The notifications app: telling members when someone follows them, likes or replies to a post.
module Notifications

using Juango
using Dates
using ..Posts: Post
using ..Accounts: Member

export Notification, Verb, unread_notifications

const APP = App("notifications"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                ready = () -> connect_signals(),     # run once, when the app is installed
                # a setting of the app's own, for links in emails; the project can override it
                settings = Dict(:SITE_URL => "http://127.0.0.1:8000"))

include("models.jl")
include("tasks.jl")
include("signals.jl")
include("views.jl")
include("urls.jl")

end
```

Load it in `project.jl` after `accounts`, add `Notifications.APP` to `INSTALLED_APPS`, and mount
its URLs in `urls.jl` with `path("", include_urls(Notifications.APP))`. You'll write
`connect_signals`, the **`ready`** hook, in a moment.

## Signals: reacting to events elsewhere

Something has to create a notification whenever someone follows, likes or replies. You
*could* add a line to each of the `follow`, `like` and `post_create` views. But then those
apps would depend on notifications, and every new way of liking a post (an API in chapter 14,
the admin, a script) would have to remember to notify too.

**Signals** turn this around. Juango announces events, such as "a model instance was saved" or
"a many-to-many relation changed", and any code can listen for them. The notifications app
listens, and the other apps don't change at all. Create `notifications/signals.jl`:

```julia
# Signal receivers: Juango calls these when members follow, like or reply, wherever in the code
# that happens. The posts and accounts apps don't need to know notifications exist.

const EMAILED = (Verb.FOLLOW, Verb.REPLY)       # likes are too frequent to email about

function notify!(recipient, actor, verb; post = nothing)
    recipient.id == actor.id && return nothing  # liking or replying to your own post
    n = create(Notification; recipient, actor, verb, post)
    # email once the transaction commits: the task runs elsewhere, and must see the notification
    verb in EMAILED && on_commit(() -> enqueue(email_notification, n.id))
    n
end

# Follows and likes are made with add!, which sends m2m_changed, with the through model as
# the sender. `instance` is the object add! was called on and `pk_set` the ids it added to the
# other side; `reverse` says which side add! was called from (post.likers or member.liked_posts).
function on_follow(sender; action, instance, pk_set, reverse, kw...)
    action === :post_add || return
    for id in pk_set
        other = get(get_user_model(); id)
        follower, followed = reverse ? (other, instance) : (instance, other)
        notify!(followed, follower, Verb.FOLLOW)
    end
end

function on_like(sender; action, instance, pk_set, reverse, kw...)
    action === :post_add || return
    for id in pk_set
        post, member = reverse ? (get(Post; id), instance) : (instance, get(get_user_model(); id))
        notify!(post.author, member, Verb.LIKE; post)
    end
end

# A reply is an ordinary Post being saved, so post_save
function on_reply(sender; instance, created, kw...)
    (created && instance.reply_to_id !== nothing) || return
    notify!(instance.reply_to.author, instance.author, Verb.REPLY; post = instance)
end

function connect_signals()
    connect!(m2m_changed, on_follow; sender = through(Member, :following), dispatch_uid = "notify_on_follow")
    connect!(m2m_changed, on_like; sender = through(Post, :likers), dispatch_uid = "notify_on_like")
    connect!(post_save, on_reply; sender = Post, dispatch_uid = "notify_on_reply")
end
```

A **receiver** is a function that takes the sender and keyword arguments. Always end with
`kw...`, so a receiver keeps working if the signal gains more arguments. **`connect!`**
subscribes it:

- **`post_save`** is sent after any instance is saved, with `instance` and `created` (true for a
  new row). `sender = Post` limits it to posts.
- **`m2m_changed`** is sent when a many-to-many relation changes through `add!`, `remove!`,
  `set!` or `clear!`. It's sent *before* (`:pre_add`) and *after* (`:post_add`) the change, with
  the ids added in `pk_set`. Its sender is the relation's through model, which
  **`through(Post, :likers)`** looks up (it's `Like`). A relation can be changed from either end
  (`add!(post.likers, ann)` or `add!(ann.liked_posts, post)`), and `reverse` says which, so the
  receivers handle both.
- **`dispatch_uid`** names the connection, so connecting twice (after a code reload, say)
  doesn't make every notification twice.

Connecting happens in the app's **`ready`** function, which Juango runs once, when the app is
installed. That's the right place for setup that should happen exactly once.

> **If you know Django:** signals work as in Django, and `ready` is `AppConfig.ready()`. One
> difference: `m2m_changed`'s `action` is a Julia Symbol (`:post_add`), not a string.

## Showing notifications

### The unread count, on every page: a context processor

The header should show "Notifications 3" on every page. Passing `unread_count` from every view
would be tedious and easy to forget. A **context processor** is a function from the request to a
`Dict` that's merged into *every* template's context. `user`, `messages` and `request` all come
from Juango's own context processors. In `notifications/views.jl`:

```julia
# A context processor: its Dict is added to every template's context. This one gives the
# header its unread count.
unread_notifications(req) =
    is_authenticated(req.user) ? Dict{String,Any}("unread_count" => count(filter(Notification; recipient = req.user, read = false))) :
                                 Dict{String,Any}()
```

Add it after Juango's own in `settings.jl`:

```julia
    # values every template gets: Juango's own (user, messages, ...) and the unread count
    CONTEXT_PROCESSORS = [Juango.default_settings()[:CONTEXT_PROCESSORS]..., unread_notifications],
```

and show it in `base.html`, as the first link for members:

```html
        <a href="{% url 'notifications:list' %}">Notifications{% if unread_count %} <span class="count-badge" aria-label="{{ unread_count }} unread">{{ unread_count }}</span>{% endif %}</a>
```

A context processor runs for every page, so keep it cheap. This one is one indexed `COUNT`
query, and nothing at all for visitors.

### The notifications page

Viewing your notifications should mark them read, but the page should still highlight which
ones were new. So the view fetches the page *first*, then marks everything read:

```julia
# Your notifications, newest first. Seeing them marks them read.
function notification_list(req)
    qs = select_related(filter(Notification; recipient = req.user), :actor, :post)
    page = get_page(Paginator(qs, 30), get(req.GET, "page", "1"))
    notifications = collect(page)          # fetch this page now, while the unread ones are unread
    update!(filter(Notification; recipient = req.user, read = false); read = true)
    render(req, "notifications/list.html", Dict("notifications" => notifications, "page_obj" => page,
           "paginator" => page.paginator, "is_paginated" => page.paginator.num_pages > 1, "unread_count" => 0))
end
```

- **`Paginator(qs, 30)`** splits a queryset into pages of 30, and **`get_page`** gets one by
  number. It's what `ListView` uses inside, here used directly.
- **`collect`** runs the query now. QuerySets are lazy, and without it the rows would only be
  fetched while the template renders, *after* the next line had already marked them read.
- **`update!(queryset; read = true)`** changes every matching row in one `UPDATE` statement,
  without loading them.
- `"unread_count" => 0` overrides the context processor's value, which was counted before the
  `update!`.

The URL, in `notifications/urls.jl`:

```julia
const urlpatterns = [
    path("notifications/", login_required(notification_list); name = "list"),
]
```

and the template, `notifications/templates/notifications/list.html`:

```html
{% extends "base.html" %}

{% block title %}Notifications · Juangout{% endblock %}

{% block content %}
  <h1>Notifications</h1>
  <ul class="notifications">
    {% for n in notifications %}
      <li class="{% if not n.read %}unread{% endif %}">
        {% include "accounts/_avatar.html" with member=n.actor size=28 %}
        <a class="author" href="{{ n.actor.get_absolute_url }}">{{ n.actor.name }}</a>
        {% if n.post %}<a href="{{ n.post.get_absolute_url }}">{{ n.get_verb_display }}</a>{% else %}{{ n.get_verb_display }}{% endif %}
        <span class="when">{{ n.created|timesince }} ago</span>
        {% if n.post %}<div class="excerpt">{{ n.post.body|truncatechars:80 }}</div>{% endif %}
      </li>
    {% empty %}
      <li class="empty">Nothing yet. When people follow you, or like or reply to your posts, you'll hear about it here.</li>
    {% endfor %}
  </ul>
  {% include "_pagination.html" %}
{% endblock %}
```

## Email

### Sending mail

**`send_mail(subject, body, from, to)`** sends an email. Where it actually goes depends on the
**`EMAIL_BACKEND`** setting: `:smtp` sends it through a mail server, `:console` prints it in
the terminal, and `:locmem` collects it in a list for tests. In development, printing is just
right. In `settings.jl`:

```julia
    # email: printed to the terminal in development, sent through a mail server in production
    EMAIL_BACKEND = debug ? :console : :smtp,
    DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    SITE_URL = env("SITE_URL"; default = "http://127.0.0.1:8000"),     # for links in emails
```

`DEFAULT_FROM_EMAIL` is used when `from` is `nothing`. `SITE_URL` isn't one of Juango's
settings: it's the notifications app's own, declared with a default by `settings = Dict(...)` in
its `App(...)` (Juango warns about settings nobody declared, to catch typos), and read as
`Juango.settings.SITE_URL`. Emails need full URLs, because they aren't read on your site.

This also brings to life the "forgot your password?" pages from `auth_urls()`. Visit
`/accounts/password_reset/`, enter a member's email, and the reset link appears in the
server's terminal.

### Members choose

Some members won't want email, so give them a choice. In `accounts/models.jl`, add a field to
`Member` after `avatar`,

```julia
    email_notifications = BooleanField(default = true, verbose_name = "Email me about new followers and replies")
```

and add `:email_notifications` to the profile form's `fields`. A `BooleanField` becomes a
checkbox.

### Background tasks

Talking to a mail server can take seconds, or fail. That work shouldn't hold up the request
of the member who clicked "Reply". A **background task** runs it separately. Create
`notifications/tasks.jl`:

```julia
# Email about a notification. A background task: it runs outside the request, so a slow mail
# server never slows a page down. (With the default TASKS = :immediate it runs straight away;
# chapter 15 hands tasks to a worker process.)
@background function email_notification(id)
    n = get(select_related(objects(Notification), :recipient, :actor, :post); id)
    member = n.recipient
    (isempty(member.email) || !member.email_notifications) && return
    body = render_to_string("notifications/email.txt", Dict("n" => n, "site_url" => Juango.settings.SITE_URL))
    send_mail("$(n.actor.name) $(n.get_verb_display) on Juangout", body, nothing, [member.email])
end
```

- **`@background`** marks a function as a task. **`enqueue(email_notification, n.id)`** asks
  for it to run. Calling it directly still just runs it.
- **The `TASKS` setting** decides how tasks run. The default, `:immediate`, runs them straight
  away, which is simple for development. With `:database`, tasks are stored in a table and a
  separate `manage.jl db_worker` process runs them. Chapter 15 sets that up for production.
- A task takes **ids, not objects**. A task might run in another process, later, so its
  arguments must be plain data (JSON-friendly), and it fetches fresh rows itself.
- **`render_to_string`** renders a template to a string, here a plain-text email body.

`notifications/templates/notifications/email.txt`:

```
{% autoescape off %}Hi {{ n.recipient.name }},

{{ n.actor.name }} (@{{ n.actor.username }}) {{ n.get_verb_display }} on Juangout.
{% if n.post %}
  "{{ n.post.body|truncatechars:200 }}"

See it at {{ site_url }}{{ n.post.get_absolute_url }}
{% else %}
See their profile at {{ site_url }}{{ n.actor.get_absolute_url }}
{% endif %}
You can turn these emails off on your profile page: {{ site_url }}{% url 'accounts:profile_edit' %}
{% endautoescape %}
```

**`{% autoescape off %}`**: this is plain text, not HTML, so `&` should stay `&` and not become
`&amp;`.

### `on_commit`: waiting for the data to be saved

Look again at this line in `notify!`:

```julia
    verb in EMAILED && on_commit(() -> enqueue(email_notification, n.id))
```

Why not just `enqueue` the task? Because the notification is created inside a database
**transaction**. Turn one on for every request now, in `settings.jl`:

```julia
    # each view runs in a database transaction: its changes are saved together, or not at all
    ATOMIC_REQUESTS = true,
```

With **`ATOMIC_REQUESTS`**, each view runs inside `atomic()`. If it throws an error halfway, none
of its changes are kept, so you never get a reply without its notification. Until the
transaction commits, though, other database connections can't see the new notification. A worker process that picked the task up immediately might look for
notification `n.id`, find nothing, and fail. And if the request failed and rolled back, the
email would announce something that never happened.

**`on_commit(f)`** runs `f` once the current transaction commits, and drops it if the
transaction rolls back. Outside any transaction it runs `f` at once. Use it whenever you start something outside the database (a task, an
email, a call to another service) that depends on what you've just written.

> **If you know Django:** `send_mail`, `EMAIL_BACKEND` and `DEFAULT_FROM_EMAIL` are the same,
> `ATOMIC_REQUESTS` too, and `on_commit` is `transaction.on_commit`. `@background`/`enqueue` follow Django 6's tasks
> framework (`@task` and `.enqueue()`), with `TASKS` choosing the backend.

## Styling

```css
/* notifications */
.count-badge { display: inline-block; min-width: 1.3em; padding: 0 .35em; border-radius: 999px; background: var(--accent); color: #fff; font-size: .75rem; font-weight: 700; text-align: center; }
.notifications { list-style: none; padding: 0; }
.notifications li { padding: .7rem .5rem; border-bottom: 1px solid var(--line); }
.notifications li.unread { background: var(--accent-soft); }
.notifications .when { color: var(--muted); font-size: .85rem; }
.notifications .excerpt { color: var(--muted); margin: .2rem 0 0 36px; }
.form input[type=checkbox] { margin-right: .4rem; }
```

Make the migrations (one for `accounts`, one for `notifications`) and migrate. Then follow,
like and reply between two members in two browsers, and watch the replies' emails appear in the
server's terminal.

## Tests

Create `notifications/tests.jl`, and `tests/test_notifications.jl` to run it, like the others:

```julia
using Test
using Juango.Testing

@testset "notifications" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", email = "ann@example.com")
        bob = create_user("bob"; password = "correct-horse-battery", email = "bob@example.com")
        p = create(Post; author = ann, body = "Hello")

        # the signals turn follows, likes and replies into notifications
        add!(bob.following, ann)
        add!(p.likers, bob)
        create(Post; author = bob, body = "Hi Ann!", reply_to = p)
        @test [n.verb for n in ann.notifications] == ["reply", "like", "follow"]     # newest first
        @test all(n.actor == bob for n in ann.notifications)
        @test first(ann.notifications).get_verb_display == "replied to your post"

        # ...from either side of the relation
        add!(ann.followers, create_user("cat"; password = "correct-horse-battery"))
        @test count(filter(Notification; recipient = ann, verb = Verb.FOLLOW)) == 2

        # nothing for your own likes and replies
        add!(p.likers, ann)
        create(Post; author = ann, body = "Replying to myself", reply_to = p)
        @test count(ann.notifications) == 4
        @test count(bob.notifications) == 0

        # the header shows the unread count; the page shows them and marks them read
        c = Client()
        force_login!(c, ann)
        r = get(c, "/")
        @test r.context["unread_count"] == 4
        @test assert_contains(r, "4 unread")
        r = get(c, "/notifications/")
        @test length(r.context["notifications"]) == 4
        @test count(r.context["notifications"]) do n; !n.read; end == 4     # shown as unread this time
        @test assert_contains(r, "replied to your post")
        @test count(filter(Notification; recipient = ann, read = false)) == 0
        @test get(c, "/").context["unread_count"] == 0

        @test assert_redirects(get(Client(), "/notifications/"), "/accounts/login/?next=%2Fnotifications%2F")
    end
end

@testset "notification emails" begin
    # Collect mail in `outbox`. (Juango's test runner only does this itself when the backend is
    # :smtp, Juango #254, and in development ours prints mail to the console.)
    override_settings(EMAIL_BACKEND = :locmem) do
        rollback_after() do
            ann = create_user("ann"; password = "correct-horse-battery", email = "ann@example.com")
            bob = create_user("bob"; password = "correct-horse-battery", email = "bob@example.com")
            p = create(Post; author = ann, body = "Hello")
            empty!(outbox)

            # The email is sent when the transaction commits, which a test's rollback_after never
            # does. capture_on_commit_callbacks runs the callbacks registered inside it.
            capture_on_commit_callbacks(; execute = true) do
                create(Post; author = bob, body = "Hi Ann!", reply_to = p)
            end
            @test length(outbox) == 1
            mail = only(outbox)
            @test mail.to == ["ann@example.com"]
            @test mail.subject == "bob replied to your post on Juangout"
            @test occursin("Hi Ann!", mail.body)
            @test occursin("/posts/", mail.body)

            # likes aren't emailed
            capture_on_commit_callbacks(; execute = true) do
                add!(p.likers, bob)
            end
            @test length(outbox) == 1

            # and members can turn emails off
            ann.email_notifications = false
            save!(ann)
            capture_on_commit_callbacks(; execute = true) do
                add!(bob.following, ann)
            end
            @test length(outbox) == 1
            @test count(ann.notifications) == 3         # the notifications are still made
        end
    end
end
```

- **`outbox`** collects the messages sent with the `:locmem` backend. **`empty!(outbox)`** starts
  each test with a clean slate.
- **`capture_on_commit_callbacks(; execute = true)`** solves a puzzle: `rollback_after` never
  commits (that's the point of it), so `on_commit` callbacks would never run and no email would
  be sent. Inside this block, the callbacks registered are run at the end of the block instead.

## Summary

- **`@choices`** gives a field a fixed set of values with labels. `obj.get_<field>_display` shows
  the label.
- **Signals** (`post_save`, `m2m_changed`, ...) let one app react to events in another.
  Connect receivers in the app's **`ready`** hook, with `dispatch_uid`.
- **Indexes** (`Meta(indexes = [...])`) speed up the queries you run most.
- **Context processors** add values to every template's context.
- **`Paginator`** and `get_page` paginate by hand. **`update!`** changes many rows in one query.
- **`send_mail`** sends email. **`EMAIL_BACKEND`** decides where it goes, and
  **`render_to_string`** renders an email body from a template.
- **`@background`** tasks and **`enqueue`** move slow work out of the request. Pass ids, not
  objects.
- **`on_commit`** waits until the data is really saved. In tests, use
  **`capture_on_commit_callbacks`**, and check **`outbox`**.

The code at this point is tagged `ch09`.

The notification count only changes when you load a page. In chapter 10, new posts and
notifications will appear while you watch.
