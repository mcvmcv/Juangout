# Chapter 10: Live updates

Juangout only changes when you ask it to: load a page, click a button. In this chapter you'll
build a **Live** tab where new posts and likes from everyone appear as they happen, without
reloading. The compose box there counts characters and checks your post as you type.

The tool is a **live view**, a page that stays connected to the server. It's one of Juango's
newer features (the documentation calls it experimental), and it's a different way of building
pages from everything so far, so this chapter takes it slowly.

Juango ideas in this chapter: **live views** (`LiveView`, `mount`, `handle_event`,
`handle_info`, `live`), the **`{% liveview %}`** tag, **`j-` bindings** (`j-change`,
`j-submit`, `j-click`), **`LiveForm`**, **`publish`/`subscribe`**, and testing with
**`live_test`**. At the end there's a look at the alternatives: server-sent events and plain
WebSockets.

## How a live view works

1. The browser asks for `/live/`. Juango creates the view, calls its **`mount`**, and renders the
   template as ordinary HTML. The page works, and can be read, without JavaScript.
2. A small script that comes with Juango (`live.js`) opens a **WebSocket**, a connection that
   stays open, back to the same URL. On the server a fresh view is mounted for it and kept in
   memory for as long as the page is open.
3. When something happens in the page, such as typing in a field marked `j-change` or clicking
   an element marked `j-click`, `live.js` sends an *event* over the socket, and Juango calls the
   view's **`handle_event`**.
4. When something happens elsewhere (someone else posts), code anywhere can **`publish`** a
   message to a topic. Every open view that **`subscribe`d** to that topic gets it in
   **`handle_info`**.
5. After each event or message, Juango renders the live part of the template again and sends the
   browser only what changed. The browser merges it into the page, keeping your cursor and what
   you've typed.

So all the state and logic stay on the server, in Julia, and you write no JavaScript. The cost is
a connection and a little memory per open page.

## The view

A live view is a mutable struct that subtypes `LiveView`. Its fields are the template's variables.
Create `posts/live.jl`:

```julia
# The live timeline: everyone's latest posts, updating while you watch. A live view is a page
# that stays connected to the server over a WebSocket: browser events go to handle_event,
# messages published to its topics go to handle_info, and after each one Juango renders the
# {% liveview %} part of the template again and sends the browser what changed.

Base.@kwdef mutable struct LiveTimeline <: LiveView      # its fields are the template's variables
    posts::Vector{Any} = []
    form::Any = nothing                                   # a LiveForm, made in mount
    chars_left::Int = 280
    me::Any = nothing                                     # the member watching
end

refresh_posts!(v::LiveTimeline) = (v.posts = collect(for_display(top_level(objects(Post)), v.me)[1:30]))
```

`Base.@kwdef` lets the struct be made with no arguments (`LiveTimeline()`), each field taking
its default. Juango needs that to create views. `refresh_posts!` fetches the latest 30 posts,
with the same `for_display` as every other timeline.

### `mount`

```julia
# (`files = nothing`: LiveForm makes its first, empty form with one argument, Juango #256)
new_post_form(me) = LiveForm((data, files = nothing) -> post_form(data; files, instance = Post(; author = me)))

# For the first page load, and each time the WebSocket connects
function Juango.mount(v::LiveTimeline, req, params)
    v.me = req.user
    v.form = new_post_form(req.user)
    subscribe("posts")                  # deliver publish("posts", ...) to handle_info
    refresh_posts!(v)
end
```

`mount` sets the view up, from the request (the WebSocket's request has the session and
`req.user`, like any other) and `params` (URL captures and the query string). The view keeps the
member in a field, because `handle_event` and `handle_info` don't get the request.
**`subscribe("posts")`** asks for messages published to the topic `"posts"`.

**`LiveForm`** wraps a form so it can be validated as you type. You give it a function that builds
the form from the submitted data. Here that's chapter 4's `post_form`, with the author already
set. (The `files = nothing` default works around a bug in the current version of Juango.)

### `handle_event`

```julia
function Juango.handle_event(v::LiveTimeline, name, params)
    if name == "validate"               # typing in the compose box (j-change)
        live_change!(v.form, params)
        v.chars_left = 280 - length(get(params, "body", ""))
    elseif name == "post" && is_authenticated(v.me)       # submitting it (j-submit)
        if live_submit!(v.form, params)
            save!(v.form.form)          # the post_saved signal publishes it, to every open page
            v.form = new_post_form(v.me)
            v.chars_left = 280
        end
    elseif name == "like" && is_authenticated(v.me)       # a heart (j-click)
        post = get(Post; id = parse(Int, params["id"]))
        v.me in post.likers ? remove!(post.likers, v.me) : add!(post.likers, v.me)
    end
end
```

An event has a `name`, chosen in the template, and `params` from the page. The handler just
changes the view's fields, and Juango takes care of rendering and sending.

- **`live_change!(form, params)`** rebuilds and validates the form from what's been typed so far,
  but only shows errors for fields the member has actually touched. Nobody wants "This field is
  required" before they've started typing.
- **`live_submit!(form, params)`** validates every field and returns whether the form is valid.
  `v.form.form` is the `ModelForm` inside, so `save!` works as usual.

`params` comes from the browser, so treat it like any submitted data. The `like` branch parses
the id, and `get` throws if there's no such post.

### `handle_info`

```julia
# Something changed somewhere: a new post, or a like. Fetch the latest again.
Juango.handle_info(v::LiveTimeline, msg) = refresh_posts!(v)
```

Each published message re-fetches the posts. That's simple, and cheap enough for 30 posts. A
busier site might publish the new post's id and add just that one.

### Publishing

What publishes to `"posts"`? The views could, but chapter 9 showed a better place: signals. Then
*every* new post or like reaches the live timeline, however it was made. At the end of
`posts/live.jl`:

```julia
# Tell open live pages about new posts and likes, once they're saved.
announce(sender; kw...) = on_commit(() -> publish("posts", "changed"))
function connect_live_signals()
    connect!(post_save, announce; sender = Post, dispatch_uid = "live_on_post")
    connect!(m2m_changed, announce; sender = through(Post, :likers), dispatch_uid = "live_on_like")
end
```

The message itself doesn't matter here, since every view just refreshes. `on_commit` waits until
the post is really saved, for the same reason as chapter 9's emails: the views fetch posts on
their own connections, and must be able to see the new one.

Wire it up in `Posts.jl`: `include("live.jl")` after `views.jl`, export `LiveTimeline`, and give
the app a `ready` hook:

```julia
const APP = App("posts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                commands = Dict("seed" => ("Create demo members and posts", args -> seed(args))),
                ready = () -> connect_live_signals())
```

### The URL

A live view gets its URL from **`live`** instead of `path`, with the view type and its template.
In `posts/urls.jl`:

```julia
    live("live/", LiveTimeline, "posts/live.html"; name = "live"),
```

## The template

`posts/templates/posts/live.html`:

```html
{% extends "base.html" %}

{% block title %}Live · Juangout{% endblock %}

{% block content %}
  {% include "posts/_tabs.html" with tab="live" %}
  {% liveview %}
    {% if user.is_authenticated %}
      {# j-change validates as you type; j-submit sends the post over the WebSocket. #}
      {# Without JavaScript, it's an ordinary form for post_create. #}
      <form method="post" action="{% url 'posts:create' %}" enctype="multipart/form-data"
            class="form compose" j-change="validate" j-submit="post">
        {% csrf_token %}
        {{ form.form.as_div }}
        <p class="chars-left{% if chars_left < 0 %} over{% endif %}">{{ chars_left }} characters left</p>
        <button type="submit">Post</button>
      </form>
    {% endif %}
    <div class="live-posts">
      {% for post in posts %}
        {% include "posts/_post.html" with live=True %}
      {% empty %}
        <p class="empty">Nothing yet. Say something!</p>
      {% endfor %}
    </div>
  {% endliveview %}
{% endblock %}
```

- **`{% liveview %}`** marks the part of the page that the view renders again. Everything outside
  it (the header, the tabs) is rendered once. It also loads `live.js`.
- **`j-change="validate"`** on the form sends a `validate` event, with the form's fields, as you
  type (after a short pause, so not on every keystroke). **`j-submit="post"`** sends the fields as
  a `post` event instead of submitting the form. Files are uploaded over the socket too, so
  pictures work.
- The form still has `method`, `action` and `{% csrf_token %}`, so without JavaScript it's an
  ordinary form for chapter 4's `post_create`.

The like button on the live page should be a live event too, so `_post.html` takes a `live` flag.
Put this before the existing `{% if user.is_authenticated %}`, turning that into an `elif`:

```html
    {% if live and user.is_authenticated %}
      {# on the live page, a live view event instead of a form #}
      <button type="button" class="like{% if post.liked %} liked{% endif %}" j-click="like" j-value-id="{{ post.id }}"
              aria-pressed="{% if post.liked %}true{% else %}false{% endif %}"
              title="{% if post.liked %}Unlike{% else %}Like{% endif %}">♥ {{ post.like_count }}</button>
    {% elif user.is_authenticated %}
      {% partialdef like_button inline %}
      ...
```

**`j-click="like"`** sends a `like` event when the button is clicked, with every `j-value-*`
attribute as a parameter, so `j-value-id` arrives as `params["id"]`.

The tabs now appear on two pages, so move them into `posts/templates/posts/_tabs.html`, with the
new tab:

```html
{% if user.is_authenticated %}
  <nav class="tabs">
    <a href="{% url 'posts:timeline' %}"{% if tab == "feed" %} aria-current="page"{% endif %}>Following</a>
    <a href="{% url 'posts:everyone' %}"{% if tab == "everyone" %} aria-current="page"{% endif %}>Everyone</a>
    <a href="{% url 'posts:live' %}"{% if tab == "live" %} aria-current="page"{% endif %}>Live</a>
  </nav>
{% endif %}
```

and `{% include "posts/_tabs.html" %}` in `timeline.html` where the tabs were. Finally, the CSS:

```css
/* live */
.chars-left { color: var(--muted); font-size: .85rem; margin: -.4rem 0 .6rem; }
.chars-left.over { color: #b42318; font-weight: 600; }
```

Open `/live/` in two browser windows, logged in as different members. Post in one and watch it
appear in the other. Like a post and watch both counts change. Type more than 280 characters and
watch the counter turn red.

## Tests

**`live_test`** mounts a live view without a browser or a socket. **`live_event!`** sends it an
event, **`live_flush!`** delivers messages published to its topics, and both return the live part's
HTML. `lt.view` is the view itself. In `posts/tests.jl`:

```julia
@testset "the live timeline" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        create(Post; author = bob, body = "Already here")

        # the page itself is ordinary HTML, with the live part marked for live.js
        c = Client()
        force_login!(c, ann)
        r = get(c, "/live/")
        @test r.status == 200
        @test assert_contains(r, "data-j-live=\"/live/\"")
        @test assert_contains(r, "live.js")
        @test assert_contains(r, "Already here")

        # live_test mounts the view without a browser; events and messages return the new HTML
        lt = live_test(LiveTimeline, "posts/live.html"; user = ann, path = "/live/")
        @test occursin("Already here", lt.html)

        # typing: validated as you go, with a running count
        html = live_event!(lt, "validate", Dict("body" => "x"^290, "_target" => "body"))
        @test occursin("-10 characters left", html)
        @test haskey(lt.view.form.form.errors, :body)

        # posting over the socket saves the post (and the form starts again)
        capture_on_commit_callbacks(; execute = true) do
            live_event!(lt, "post", Dict("body" => "Hello, live!"))
        end
        @test count(filter(Post; author = ann, body = "Hello, live!")) == 1
        @test lt.view.chars_left == 280

        # someone else posts: the published message reaches the view, which shows it
        capture_on_commit_callbacks(; execute = true) do
            create(Post; author = bob, body = "Breaking news")
        end
        html = live_flush!(lt)
        @test occursin("Breaking news", html)
        @test occursin("Hello, live!", html)

        # likes are live events too
        p = get(Post; body = "Breaking news")
        capture_on_commit_callbacks(; execute = true) do
            live_event!(lt, "like", Dict("id" => string(p.id)))
        end
        @test ann in p.likers
        @test occursin("j-click=\"like\"", live_flush!(lt))
    end
end
```

`_target` names the field that changed, as `live.js` sends it, so `live_change!` knows which
errors to show. The `capture_on_commit_callbacks` blocks run the `on_commit` callbacks, which here
publish the messages, as in chapter 9.

These tests drive the view directly. They don't run `live.js`, the WebSocket or a real browser.
Checking those means browser automation. `with_live_server() do s ... end` runs the app on a real
port for the length of a block, for a browser driver to visit. The Juangout repository has a
small one in `tools/browser_check_live.mjs`, which opens the live page in two headless Chromium
tabs and checks that a post made in one appears in the other.

## The alternatives

Live views suit a page whose content is mostly server state: here, a timeline. Juango has two
lower-level tools for pushing data to the browser, which you may want elsewhere:

- **Server-sent events** (`EventStreamResponse`): a response that stays open, sending events
  as they happen, which the browser receives with `EventSource`. They're one-way (server to
  browser), simple and cheap. A natural use would be pushing the unread notification count to
  every page. For now, though, Juango's `subscribe` only works inside live views
  ([#255](https://github.com/mcvmcv/Juango/issues/255)), so an event stream has no easy way to
  hear about new notifications.
- **WebSockets** (`websocket((ws, req) -> ...)`): two-way messages, with you deciding what they
  mean. Live views are built on them. Reach for them for things like a chat protocol or a
  multiplayer game.

And for the record, "publish" here is within one server process. Chapter 15 runs several, and
`LIVE_PUBSUB = :postgres` carries messages between them through PostgreSQL.

> **If you know Django:** Django has no built-in live views. The nearest are Django Channels
> plus a library such as django-unicorn, or Phoenix LiveView in Elixir, which Juango's are modelled on. `EventStreamResponse`
> is a `StreamingHttpResponse` for `text/event-stream`, and `websocket` handlers are like a
> Channels consumer.

## Summary

- A **live view** is a `LiveView` struct whose fields are its template's variables. **`mount`**
  sets it up, **`handle_event`** reacts to the page, and **`handle_info`** reacts to published
  messages. Juango re-renders and sends only what changed.
- **`live(route, View, template)`** gives it a URL. **`{% liveview %}`** marks the part that
  updates.
- **`j-change`**, **`j-submit`** and **`j-click`** (with `j-value-*`) send events.
- **`LiveForm`** with `live_change!`/`live_submit!` validates forms as people type.
- **`subscribe(topic)`** in `mount`, **`publish(topic, msg)`** anywhere. Signals plus `on_commit` are
  a good place to publish from.
- Test with **`live_test`**, `live_event!` and `live_flush!`.

The code at this point is tagged `ch10`.

Next, in chapter 11, members get to find each other and the things they care about: search.
