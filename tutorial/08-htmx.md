# Chapter 8: htmx

Every like, follow and post so far reloads the whole page, and loses your place in the
timeline. In this chapter you'll make those actions update just the part of the page that
changed, and make the timeline load older posts as you scroll. You won't write any JavaScript.

The tool is **[htmx](https://htmx.org)**, a small library that comes with Juango. It lets any
HTML element make a request and swap the response into the page, using attributes like
`hx-post` and `hx-target`. The server keeps rendering HTML with the same templates as before.
Everything also keeps working with JavaScript turned off, because every htmx form is still an
ordinary form.

Juango ideas in this chapter: **`{% htmx_script %}`**, **`is_htmx`**, **template partials**
(`{% partialdef %}` and `"template.html#partial"`), **out-of-band swaps**, **`form_status`**
and the 422 status, **messages after htmx requests**, and **`htmx = true`** in tests.

## Setting up

Add one tag to the `<head>` of `templates/base.html`:

```html
  <link rel="stylesheet" href="{% static 'style.css' %}">
  {% htmx_script %}
```

`{% htmx_script %}` loads the copy of htmx that comes with Juango, sends the CSRF token with
every htmx request (so `hx-post` passes the CSRF check), and tells htmx to swap in responses
with status 422 (see below).

Then wrap the messages loop in a `<div id="messages">`:

```html
    <div id="messages">
      {% for message in messages %}<p class="msg {{ message.tags }}">{{ message }}</p>{% endfor %}
    </div>
```

After an htmx request, the page doesn't reload, so the messages loop never runs again. Juango
deals with that: it adds any waiting messages to the end of htmx responses, as a replacement
for `#messages`. That's an *out-of-band swap*, which you'll meet properly further down.

## The like button

Here's the plan for a like:

1. The like form gets `hx-post`, so htmx sends the POST in the background instead of the
   browser submitting it.
2. The view sees that it's an htmx request and answers with just the new button.
3. htmx replaces the old button with it.

### Partials

The view needs to render *just the button*. You could move it into a template of its own,
but it's nicer to keep it where it is and give it a name. In `posts/_post.html`, wrap the like
form in **`{% partialdef %}`**, and add three htmx attributes:

```html
    {% if user.is_authenticated %}
      {% partialdef like_button inline %}
      <form method="post" action="{% url 'posts:like' post.id %}" class="like-form"
            hx-post="{% url 'posts:like' post.id %}" hx-target="this" hx-swap="outerHTML">
        {% csrf_token %}
        <input type="hidden" name="next" value="{{ request.get_full_path }}">
        <button type="submit" class="like{% if post.liked %} liked{% endif %}"
                aria-pressed="{% if post.liked %}true{% else %}false{% endif %}"
                title="{% if post.liked %}Unlike{% else %}Like{% endif %}">♥ {{ post.like_count }}</button>
      </form>
      {% endpartialdef %}
    {% else %}
```

- `{% partialdef like_button inline %}` names the piece of template between it and
  `{% endpartialdef %}`. **`inline`** means it still renders where it is. Without `inline`
  it would only be a definition. Anyone can now render just that piece, by naming the template
  and the partial: **`"posts/_post.html#like_button"`**.
- **`hx-post`** is the URL htmx POSTs the form's fields to.
- **`hx-target="this"`** says where the response goes (this form), and **`hx-swap="outerHTML"`**
  says how: replace the whole element. Other swaps include `innerHTML`, `beforeend` (append)
  and `afterbegin` (prepend).

The `action` stays, so without JavaScript the form still works as before.

### The view

In the `like` view, before the redirect:

```julia
    if is_htmx(req)       # just the button, with its new count, for htmx to swap in
        post = first(for_display(filter(Post; id), req.user))
        return render(req, "posts/_post.html#like_button", Dict("post" => post))
    end
    redirect_back(req, get_absolute_url(post))
```

**`is_htmx(req)`** is true when htmx sent the request (it adds an `HX-Request` header). The view
fetches the post again with `for_display`, so `like_count` and `liked` are up to date, and
renders just the partial. That's all. Try it: click a heart and watch the count change,
without the page moving.

## The follow button

The same idea works for following, but this time the box to replace holds the button *and* the
follower count, which changes too. In `profile.html`, wrap them both in a partial with an id:

```html
    {% partialdef follow_box inline %}
    <div id="follow-box">
      <p class="counts">
        <a href="{% url 'accounts:followers' member.username %}"><strong>{{ follower_count }}</strong> follower{{ follower_count|pluralize }}</a>
        <a href="{% url 'accounts:following' member.username %}"><strong>{{ following_count }}</strong> following</a>
      </p>
      {% if user.is_authenticated and not is_me %}
        <form method="post" hx-target="#follow-box" hx-swap="outerHTML"
              {% if i_follow %}action="{% url 'accounts:unfollow' member.username %}" hx-post="{% url 'accounts:unfollow' member.username %}"
              {% else %}action="{% url 'accounts:follow' member.username %}" hx-post="{% url 'accounts:follow' member.username %}"{% endif %}>
          {% csrf_token %}
          {% if i_follow %}<button type="submit" class="secondary">Unfollow</button>
          {% else %}<button type="submit">Follow</button>{% endif %}
        </form>
      {% endif %}
    </div>
    {% endpartialdef %}
```

`hx-target="#follow-box"` takes a CSS selector, so the response replaces the whole box, not just
the form.

The partial needs the same context as the profile page: the counts, `i_follow` and so on. So
move that part of the `profile` view into a function both can use. In `accounts/views.jl`:

```julia
# What the profile page, and its follow box, need to know.
function profile_context(req, member)
    me = req.user
    Dict(
        "member" => member,
        "follower_count" => count(member.followers),
        "following_count" => count(member.following),
        "is_me" => is_authenticated(me) && me.id == member.id,
        "i_follow" => is_authenticated(me) && member in me.following,
        "follows_me" => is_authenticated(me) && me in member.following,
    )
end

function profile(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    ctx = profile_context(req, member)
    ctx["posts"] = for_display(member.posts, req.user)[1:20]
    render(req, "accounts/profile.html", ctx)
end

# After following or unfollowing: the follow box for htmx, or the whole profile page.
after_follow(req, member) =
    is_htmx(req) ? render(req, "accounts/profile.html#follow_box", profile_context(req, member)) : redirect(member)
```

`follow` and `unfollow` now end with `after_follow(req, member)` instead of `redirect(member)`.
Their messages ("You're following Bob.") still appear: Juango adds them to the htmx response for
`#messages`.

## Posting without a reload

The compose form is a bit more involved, because a successful post changes *two* parts of the
page: the form should come back empty, *and* the new post should appear at the top of the
timeline. And an invalid post should show its errors in place.

Give the form htmx attributes, in `_compose_form.html`:

```html
<form method="post" class="form compose" enctype="multipart/form-data"
      action="{% if reply_to %}{% url 'posts:reply' reply_to.id %}{% else %}{% url 'posts:create' %}{% endif %}"
      hx-post="{% if reply_to %}{% url 'posts:reply' reply_to.id %}{% else %}{% url 'posts:create' %}{% endif %}"
      hx-target="this" hx-swap="outerHTML">
```

htmx sends files too, so pictures keep working.

### Two targets in one response: out-of-band swaps

The response's main content replaces the form, as `hx-target` says. To update a second place in
the same response, an element can carry **`hx-swap-oob`** ("out of band"). htmx takes it out of
the response and swaps it in wherever it names. Create `posts/templates/posts/_compose_done.html`:

```html
{# After posting with htmx: a fresh form replaces the submitted one, and the new post is added #}
{# to the list it belongs in, with an out-of-band swap (a second target in the same response). #}
{% include "posts/_compose_form.html" %}
<div hx-swap-oob="{% if reply_to %}beforeend:#replies{% else %}afterbegin:#post-list{% endif %}">
  {% include "posts/_post.html" %}
</div>
```

`afterbegin:#post-list` means "put my contents at the start of `#post-list`". A reply goes at the
end of the thread instead (`beforeend:#replies`). Give those two lists their ids: the timeline's
list in the next section, and in `detail.html`, `<div class="replies" id="replies">`.

### The view

In `post_create`:

```julia
    if posting && is_valid(form)
        post = save!(form)
        message!(req, :success, parent === nothing ? "Posted." : "Replied.")
        if is_htmx(req)
            # an empty form in place of the one submitted, and the new post added to the page
            return render(req, "posts/_compose_done.html", Dict("form" => post_form(), "reply_to" => parent,
                          "post" => first(for_display(filter(Post; id = post.id), req.user))))
        end
        return parent === nothing ? redirect("posts:timeline") : redirect(parent)
    end
    if is_htmx(req)       # the form again, with its errors, in place (422: "not accepted")
        return render(req, "posts/_compose_form.html", Dict("form" => form, "reply_to" => parent);
                      status = form_status(form))
    end
    render(req, "posts/compose.html", Dict("form" => form, "parent" => parent))
```

`save!(form)` returns the saved post. For an invalid form, the view sends back just the form,
with its errors. **`form_status(form)`** is 422 ("Unprocessable Content") for a submitted form
with errors, and 200 otherwise. The status matters: it tells your tests, logs and monitoring
that the request *failed*. htmx normally ignores error responses, but `{% htmx_script %}` set it
up to swap 422s in, so the errors appear where the form was.

## Infinite scroll

Instead of an "Older posts" link at the bottom of the timeline, the next page can load itself
when you reach the bottom. In `timeline.html`, replace the posts loop and the pagination include
with:

```html
  <div id="post-list">
    {% partialdef page inline %}
      {% for post in post_list %}
        {% include "posts/_post.html" %}
      {% empty %}
        {% if tab == "feed" and user.is_authenticated %}
          <p class="empty">Nothing here yet. Follow some people from <a href="{% url 'posts:everyone' %}">Everyone</a>, or write the first post.</p>
        {% else %}
          <p class="empty">Nothing to read yet.</p>
        {% endif %}
      {% endfor %}
      {% if page_obj.has_next %}
        {# replaced by the next page when it scrolls into view; a plain link without JavaScript #}
        <div class="load-more" hx-get="?page={{ page_obj.next_page_number }}" hx-trigger="revealed" hx-swap="outerHTML">
          <a href="?page={{ page_obj.next_page_number }}">Older posts</a>
        </div>
      {% endif %}
    {% endpartialdef %}
  </div>
```

- **`hx-get`** makes a GET request. **`hx-trigger="revealed"`** sends it when the element scrolls
  into view, rather than on a click.
- **`hx-swap="outerHTML"`** replaces the "load more" element with what comes back: the next
  page's posts, followed by *its* "load more" element, if there's a page after it. So the
  timeline grows a page at a time, and stops at the last page.
- The `page` partial is exactly one page of posts plus the next "load more", which is what an
  htmx request should get.

The timeline is a `ListView`, which picks its template with a `get_template_names` hook. Make
it pick the partial for htmx requests:

```julia
# The whole page normally; for htmx's "load the next page" requests, just the posts.
timeline_template(v) = is_htmx(v.request; boosted = false) ? ["posts/timeline.html#page"] : ["posts/timeline.html"]
```

and add `get_template_names = timeline_template` to both `timeline` and `everyone`.
(`boosted = false` leaves out requests from `hx-boost`, an htmx feature for whole-page
navigation that Juangout doesn't use but that would want the whole page.)

The CSS:

```css
/* htmx */
.load-more { text-align: center; padding: 1rem; color: var(--muted); }
.htmx-request button { opacity: .6; cursor: progress; }
```

htmx adds the class `htmx-request` to an element while its request is in flight, so buttons dim
while they wait.

> **If you know Django:** this is django-htmx and django-template-partials, built in.
> `is_htmx(req)` is `request.htmx`, and `{% partialdef %}` and `"template.html#name"` work the
> same. `HtmxMiddleware` is in the default `MIDDLEWARE`.

## Tests

The test client sends htmx's header with **`htmx = true`**. Responses to htmx requests should be
fragments, so check that they *don't* contain `<html`. In `posts/tests.jl`:

```julia
@testset "htmx: likes, posting and infinite scroll" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "Hello")
        c = Client()
        force_login!(c, ann)

        # the page loads htmx and has somewhere for messages to go
        r = get(c, "/")
        @test assert_contains(r, "htmx.min.js")
        @test assert_contains(r, "id=\"messages\"")

        # liking with htmx returns just the button, with the new count
        r = post(c, "/posts/$(p.id)/like/"; htmx = true)
        @test r.status == 200
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "aria-pressed=\"true\"")
        @test assert_contains(r, "♥ 1")
        @test ann in p.likers

        # posting with htmx returns a fresh form and the new post, swapped in out of band
        r = post(c, "/posts/new/", Dict("body" => "Posted without a reload"); htmx = true)
        @test r.status == 200
        @test assert_contains(r, "hx-swap-oob=\"afterbegin:#post-list\"")
        @test assert_contains(r, "Posted without a reload")
        @test assert_contains(r, "Posted.")                  # the message, out of band too
        @test count(objects(Post)) == 2

        # replying adds the reply to the end of the thread
        r = post(c, "/posts/$(p.id)/reply/", Dict("body" => "A reply"); htmx = true)
        @test assert_contains(r, "hx-swap-oob=\"beforeend:#replies\"")

        # an invalid post comes back as the form with its errors, status 422
        r = post(c, "/posts/new/", Dict("body" => ""); htmx = true)
        @test r.status == 422
        @test haskey(r.context["form"].errors, :body)
        @test assert_not_contains(r, "<html"; status = 422)

        # infinite scroll: htmx asks for the next page and gets just its posts
        for i in 1:25
            create(Post; author = ann, body = "filler $i")
        end
        r = get(c, "/")
        @test assert_contains(r, "hx-get=\"?page=2\"")
        r = get(c, "/?page=2"; htmx = true)
        @test assert_not_contains(r, "<html")
        @test assert_not_contains(r, "id=\"post-list\"")     # the posts only, not their container
        @test length(r.context["post_list"]) == 7
        @test assert_not_contains(r, "hx-get=\"?page=3\"")   # the last page
    end
end
```

`assert_contains` and `assert_not_contains` also check the status, which should be 200 unless
you say otherwise, hence `status = 422` for the invalid post. The pagination test from chapter 3
looks for "Older →", so change it to look for "Older posts". And in `accounts/tests.jl`:

```julia
@testset "htmx: following" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = post(c, "/@bob/follow/"; htmx = true)
        @test r.status == 200
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "id=\"follow-box\"")
        @test assert_contains(r, "Unfollow")
        @test assert_contains(r, "<strong>1</strong> follower")
        @test assert_contains(r, "You&#x27;re following bob.")   # the message, out of band
        r = post(c, "/@bob/unfollow/"; htmx = true)
        @test assert_contains(r, "<strong>0</strong> followers")
    end
end
```

These tests check what the server sends. Checking that htmx then does the right thing with it
in a real browser is a job for browser automation. Juango's `with_live_server` runs the app for
tools like that, and chapter 10 uses it.

## Summary

- **htmx** attributes (`hx-get`, `hx-post`, `hx-target`, `hx-swap`, `hx-trigger`) make
  elements request HTML and swap it into the page. `{% htmx_script %}` sets it up, CSRF
  included.
- Views check **`is_htmx(req)`** and return a fragment instead of a page or a redirect.
- **`{% partialdef name inline %}`** names part of a template, and **`"template.html#name"`**
  renders just that part. Partials keep fragments next to the page they belong to.
- **`hx-swap-oob`** updates a second part of the page from the same response. Juango uses it to
  deliver messages to `#messages`.
- For invalid forms, return the form with **`form_status(form)`** (422).
- Keep `action` on every htmx form, so the site works without JavaScript too.
- Test with **`htmx = true`**, and check that fragments aren't whole pages.

The code at this point is tagged `ch08`.

Members still have to come back to find out that someone liked their post. In chapter 9
Juangout starts telling them: notifications, email and background tasks.
