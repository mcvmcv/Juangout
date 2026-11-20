# Chapter 13: Polish

This chapter is a collection of finishing touches, each a small Juango feature: a **Trending** page
made affordable with **caching**, friendlier times and numbers with **humanize**, members' own
**time zones** (through a **middleware** you write yourself), and a second language, German, with
**translations** and a language switcher.

Juango ideas in this chapter: the **cache** (`get_or_set`, `cache_delete`, `cache_clear`), the
**humanize** filters, **`with_timezone`**, writing **middleware**, the order of `MIDDLEWARE`,
**translations** (`{% translate %}`, `makemessages`, `.po` files, `LocaleMiddleware`, `set_language`),
and `Accept-Language`.

## Trending, and caching

### What's trending

Trending means "liked most recently": the top-level posts with the most likes in the last day,
and the tags used most in the last week. Both are aggregates over the whole site. Create
`posts/trending.jl`:

```julia
# Trending: computed from every post and like, so worth caching. The cache keeps the results
# for a few minutes and everyone shares them; a slightly stale trending list is fine.

"The ids of the top-level posts liked most in the last `hours` hours, most liked first."
function trending_post_ids(; hours = 24, n = 20)
    get_or_set("trending:posts", function ()
        since = timezone_now() - Hour(hours)
        qs = filter(Post; hidden = false, reply_to__isnull = true)
        qs = annotate(qs; recent_likes = Count(:likes; filter = Q(likes__created__gte = since)))
        qs = order_by(filter(qs; recent_likes__gt = 0), "-recent_likes", "-created")
        collect(values_list(qs[1:n], :id; flat = true))
    end; timeout = 300)
end

"The tags used most in the last week, as (name, uses) pairs."
function trending_tags(; days = 7, n = 12)
    get_or_set("trending:tags", function ()
        since = timezone_now() - Day(days)
        qs = annotate(objects(Tag); uses = Count(:posts; filter = Q(posts__created__gte = since, posts__hidden = false)))
        [(name = t.name, uses = t.uses) for t in order_by(filter(qs; uses__gt = 0), "-uses", "name")[1:n]]
    end; timeout = 600)
end
```

The queries use chapter 12's `Count(...; filter = ...)`. `:likes` is the reverse relation from
posts to their `Like` rows, which record *when* each like happened. That's the payoff for giving
likes a through model back in chapter 5.

### Caching with `get_or_set`

These queries read every recent like on the site. Running them on every page view would be
wasteful, and pointless too, since trending barely changes from one second to the next. The
**cache** is a key-value store for results like these:

- **`get_or_set(key, f; timeout)`** returns the cached value for `key` if there is one.
  Otherwise it calls `f`, stores the result for `timeout` seconds, and returns it.
- **`cache_get`/`cache_set`/`cache_delete`** do the individual steps, and **`cache_clear()`**
  empties the cache.

By default the cache is in the server process's memory (`:locmem`). The `CACHES` setting can
point it at Redis, memcached, the database or files instead, which you'd want with several server
processes, so they share one cache.

**What to cache** matters. Notice that the functions cache post *ids*, not finished pages, or even
posts. Every member sees the same trending posts, but each sees their *own* hearts filled in. So
the expensive, shared part (which posts are trending) is cached, and the cheap, personal part
(`for_display` for this member) runs on every request:

```julia
# The page: the cached ids, then the posts for this member (their own likes), in trending order.
function trending(req)
    ids = trending_post_ids()
    posts = sort(collect(for_display(filter(Post; id__in = ids), req.user)); by = p -> findfirst(==(p.id), ids))
    render(req, "posts/trending.html", Dict("posts" => posts, "tags" => trending_tags(), "tab" => "trending"))
end
```

`for_display` sorts newest first, so the posts are put back into trending order in Julia. Caching ids
has another advantage: if a moderator hides a cached post, `for_display` still leaves it out.

Juango can also cache whole responses (`cache_page(view; timeout)`) and pieces of templates
(`{% cache 600 "name" %}...{% endcache %}`). Neither suits Juangout's pages, which are personal
(`cache_page` won't store a response that depends on who's logged in), but both are worth knowing
for public pages. Chapter 14 uses `cache_page` for feeds.

> **If you know Django:** `get_or_set`, `cache_page`, `{% cache %}` and `CACHES` are Django's
> cache framework.

Include `trending.jl` in `Posts.jl` after `live.jl`, add
`path("trending/", trending; name = "trending")`, and add a "Trending" tab to `_tabs.html`. The
template, `posts/templates/posts/trending.html` (with the `{% translate %}` tags explained later in
this chapter):

```html
{% extends "base.html" %}
{% load i18n humanize %}

{% block title %}{% translate "Trending" %} · Juangout{% endblock %}

{% block content %}
  {% include "posts/_tabs.html" %}
  {% if tags %}
    <section class="trending-tags">
      <h2 class="section-title">{% translate "Tags this week" %}</h2>
      {% for t in tags %}
        <a class="tag-chip" href="{% url 'posts:tag' t.name %}">#{{ t.name }} <span>{{ t.uses|intcomma }}</span></a>
      {% endfor %}
    </section>
  {% endif %}
  <h2 class="section-title">{% translate "Most liked today" %}</h2>
  {% for post in posts %}
    {% include "posts/_post.html" %}
  {% empty %}
    <p class="empty">{% translate "Nothing has been liked today. Yet." %}</p>
  {% endfor %}
{% endblock %}
```

## humanize

Since chapter 3, post times have been `{{ post.created|timesince }} ago`, with the "ago" typed in the
template, which can't be translated and reads oddly for a post made seconds ago ("0 minutes ago").
**`{% load humanize %}`** adds filters that handle this properly:

- **`naturaltime`**: "now", "5 minutes ago", "2 hours ago", and in the future "in 3 hours".
- **`intcomma`**: `12345` → `12,345`, with the active language's separator.
- **`intword`**: `1200000` → `1.2 million`. Also `naturalday` ("today", "yesterday"), `ordinal`
  ("22nd") and `apnumber` ("four").

In `_post.html`, load it on the first line (`{% load posts_extras humanize i18n %}` loads three
libraries at once) and use it for the time:

```html
    <a class="when" href="{{ post.get_absolute_url }}" title="{{ post.created|date:'j M Y, H:i T' }}">{{ post.created|naturaltime }}</a>
```

The `title`, shown when you hover, keeps the exact time, and `T` adds the time zone's abbreviation.
Use `naturaltime` in the notifications list too, and `intcomma` for the follower counts on profiles.

## Time zones

Since chapter 3, times have been stored in UTC (`USE_TZ = true`) and shown in `TIME_ZONE`, also
UTC. A member in Auckland sees "posted at 23:00" for something posted at their lunchtime. Let
members choose their zone.

### The setting

In `accounts/models.jl`, a list of zones to choose from, before `Member`:

```julia
# Time zones members can choose from (any IANA name would work; a short list makes a tidy menu)
const TIME_ZONES = [tz => replace(tz, "_" => " ") for tz in [
    "UTC", "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Athens", "Africa/Lagos",
    "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Shanghai", "Asia/Tokyo",
    "Australia/Perth", "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "America/New_York",
    "America/Chicago", "America/Denver", "America/Los_Angeles", "Pacific/Honolulu"]]
```

and a field on `Member`:

```julia
    time_zone = CharField(max_length = 50, blank = true, choices = TIME_ZONES,
                          help_text = "Times are shown in this zone. Leave blank for UTC.")
```

Choices can be plain `value => label` pairs, as well as `@choices`. Add `:time_zone` to the
profile form's fields, then `makemigrations` and `migrate`.

### Applying it: a middleware

Juango shows times in the **current time zone**, and **`with_timezone(f, zone)`** runs `f` with a
different one. To use the member's zone for a whole request (every template, every form), wrap
the request. That's what **middleware** is for: code that runs around every request.

A middleware is a function that takes the next step, `get_response`, and returns a new step, a
function from a request to a response. Create `accounts/middleware.jl`:

```julia
# Middleware: code that wraps every request. This one shows times in the member's own time
# zone: while the request is handled (templates rendered, forms read), their zone is the
# current one. It needs req.user, so it goes after AuthenticationMiddleware.
function MemberTimezoneMiddleware(get_response)
    function (req)
        u = req.user
        if is_authenticated(u) && !isempty(u.time_zone)
            with_timezone(() -> get_response(req), u.time_zone)
        else
            get_response(req)
        end
    end
end
```

Include it in `Accounts.jl` and export `MemberTimezoneMiddleware`.

### The order of middleware

Until now Juangout used Juango's default middleware, plus the debug toolbar. Now the list needs
writing out, because **order matters**. A request passes through the middleware from first to
last, the view runs, and the response passes back out in reverse. A middleware can only use what
an earlier one has set up. In `settings.jl`:

```julia
    # Every request passes through these in order (and the response back out in reverse).
    # The debug toolbar first, in development; LocaleMiddleware after sessions, which it reads;
    # members' time zones after authentication, which tells us who the member is.
    MIDDLEWARE = [(debug ? [DebugToolbarMiddleware] : [])..., Juango.SecurityMiddleware, Juango.SessionMiddleware,
                  LocaleMiddleware, Juango.CommonMiddleware, Juango.CsrfViewMiddleware, Juango.AuthenticationMiddleware,
                  MemberTimezoneMiddleware, HtmxMiddleware],
```

These are Juango's defaults (security headers, sessions, `APPEND_SLASH`, CSRF, authentication and
htmx), with two additions: `LocaleMiddleware` (for translations, below) and yours. Some of Juango's
own middleware currently needs the `Juango.` prefix, because it isn't exported
([#264](https://github.com/mcvmcv/Juango/issues/264)).

> **If you know Django:** middleware has Django's shape, a factory taking `get_response`, as a
> function instead of a class. `with_timezone` is `timezone.override`.

## Translations

Juangout is in English. Making it available in German means three things: marking the text that
needs translating, translating it, and choosing which language each visitor sees.

### Marking text

In templates, load **`i18n`** and wrap text in **`{% translate %}`**. For example, in `base.html`:

```html
{% load i18n %}<!doctype html>
{% get_current_language as LANGUAGE_CODE %}
<html lang="{{ LANGUAGE_CODE }}">
...
      <a href="{% url 'posts:timeline' %}">{% translate "Home" %}</a>
      <a href="{% url 'posts:search' %}">{% translate "Search" %}</a>
      <a href="{% url 'about' %}">{% translate "About" %}</a>
```

`{% get_current_language %}` keeps the page's `lang` attribute right, which screen readers and
browsers' spelling checks rely on. Do the same for the rest of the header, the tabs, the welcome
on the timeline and the links in `_post.html`. The chapter's code marks about thirty strings. A
real translation would cover every template, and in Julia you'd use `gettext("...")` (and
`gettext_lazy` for labels defined when the code loads).

### Translating

**`makemessages`** collects every marked string into a catalogue for a language:

```sh
mkdir locale
julia --project manage.jl makemessages -l de
```

That writes `locale/de/LC_MESSAGES/juango.po`, a standard **gettext** file, one entry per string:

```
#: templates/base.html:15
msgid "Home"
msgstr ""
```

Fill in each `msgstr`:

```
msgid "Home"
msgstr "Start"

msgid "Notifications"
msgstr "Mitteilungen"

msgid "Welcome to Juangout"
msgstr "Willkommen bei Juangout"
```

Translators usually use a tool such as Poedit or Weblate rather than editing by hand. Running
`makemessages` again later adds new strings and keeps the translations you have. Juango reads `.po`
files directly. `compilemessages` builds the faster `.mo` files if you want them.

### Choosing the language

In `settings.jl`, list the languages and where the catalogues are:

```julia
    # languages: English, and a German translation in locale/de
    LANGUAGE_CODE = "en",
    LANGUAGES = [("en", "English"), ("de", "Deutsch")],
    LOCALE_PATHS = [joinpath(BASE_DIR, "locale")],
```

**`LocaleMiddleware`**, already in the `MIDDLEWARE` list above, picks each request's language: the
visitor's own choice if they've made one, else their browser's preference (the `Accept-Language`
header), else `LANGUAGE_CODE`. It goes after `SessionMiddleware`.

To let visitors choose, mount Juango's language switcher in `urls.jl`,

```julia
    path("i18n/", i18n_urls()),                       # setlang/: the language switcher
```

and put a small form in the footer of `base.html`:

```html
  <footer class="site-footer">
    {% translate "Made with Juango" %}
    <form action="{% url 'set_language' %}" method="post" class="language">
      {% csrf_token %}
      <input type="hidden" name="next" value="{{ request.get_full_path }}">
      <label for="language">{% translate "Language" %}</label>
      <select name="language" id="language" onchange="this.form.submit()">
        {% get_available_languages as LANGUAGES %}
        {% for code, name in LANGUAGES %}
          <option value="{{ code }}"{% if code == LANGUAGE_CODE %} selected{% endif %}>{{ code|language_name_local }}</option>
        {% endfor %}
      </select>
      <noscript><button type="submit">{% translate "Change" %}</button></noscript>
    </form>
  </footer>
```

Posting to `set_language` stores the choice in a cookie and goes back to `next`.
`language_name_local` shows each language in itself ("Deutsch"), which is what someone looking for
their language will recognise. Juango comes with German translations of its own messages too, such
as form errors.

> **If you know Django:** `{% translate %}`, `makemessages`, `LocaleMiddleware`, `set_language` and
> `.po` files are Django's i18n, unchanged. Juango's catalogue is called `juango.po` rather than
> `django.po`.

The CSS:

```css
/* polish */
.tag-chip { display: inline-block; margin: 0 .4rem .5rem 0; padding: .2rem .65rem; border-radius: 999px; background: var(--accent-soft); text-decoration: none; font-weight: 600; }
.tag-chip span { color: var(--muted); font-weight: 400; margin-left: .2rem; }
.site-footer { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.site-footer .language label { margin-right: .3rem; }
.site-footer select { font: inherit; padding: .15rem .3rem; border: 1px solid var(--line); border-radius: 6px; background: var(--card); color: inherit; }
```

## Tests

In `posts/tests.jl`, trending and the cache:

```julia
@testset "trending, cached" begin
    rollback_after() do
        cache_clear()                                     # start without anything cached
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        quiet = create(Post; author = ann, body = "Quiet #julia")
        popular = create(Post; author = ann, body = "Popular #julia #garden")
        add!(popular.likers, bob, cat)
        add!(quiet.likers, bob)

        @test Posts.trending_post_ids() == [popular.id, quiet.id]
        @test first(Posts.trending_tags()) == (name = "julia", uses = 2)

        # cached: a new like doesn't change the answer until the cache entry expires...
        add!(quiet.likers, ann, cat)
        @test Posts.trending_post_ids() == [popular.id, quiet.id]
        # ...or is deleted
        cache_delete("trending:posts")
        @test Posts.trending_post_ids() == [quiet.id, popular.id]

        r = get(Client(), "/trending/")
        @test [p.body for p in r.context["posts"]] == ["Quiet #julia", "Popular #julia #garden"]
        @test assert_contains(r, "#garden")
        # likes older than a day don't count
        update!(objects(Like); created = timezone_now() - Day(2))
        cache_clear()
        @test isempty(Posts.trending_post_ids())
    end
end
```

The cache isn't part of the database, so `rollback_after` doesn't undo it. A test that uses the
cache should start with **`cache_clear()`**, or it may see values left by another test.

In `accounts/tests.jl`, time zones, humanize and translations:

```julia
@testset "time zones and humanize" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "New year!")
        p.created = make_aware(DateTime(2026, 1, 1, 12, 0)); save!(p)          # noon, UTC (TIME_ZONE)

        # visitors see UTC; a member in Auckland (UTC+13 in January) sees their own time
        @test assert_contains(get(Client(), "/posts/$(p.id)/"), "1 Jan 2026, 12:00")
        ann.time_zone = "Pacific/Auckland"; save!(ann)
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/posts/$(p.id)/"), "2 Jan 2026, 01:00")

        # naturaltime: "5 minutes ago" rather than a date
        recent = create(Post; author = ann, body = "Just now-ish")
        recent.created = timezone_now() - Minute(5); save!(recent)
        @test assert_contains(get(c, "/posts/$(recent.id)/"), "5 minutes ago")
    end
end

@testset "translations" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        # the browser's preferred language
        r = get(Client(), "/"; headers = Dict("Accept-Language" => "de"))
        @test assert_contains(r, "Willkommen bei Juangout")
        @test assert_contains(r, "<html lang=\"de\">"; html = false)
        @test assert_contains(get(Client(), "/"), "Welcome to Juangout")

        # the switcher remembers a choice, and goes back where it came from
        c = Client()
        force_login!(c, ann)
        r = post(c, "/i18n/setlang/", Dict("language" => "de", "next" => "/everyone/"))
        @test assert_redirects(r, "/everyone/")
        r = get(c, "/everyone/")
        @test assert_contains(r, "Mitteilungen")
        @test assert_contains(r, ">Alle</a>")
    end
end
```

**`make_aware(DateTime(...))`** turns a plain date and time into one in the current time zone (UTC,
outside any request), so the test knows exactly when the post was made. `headers =` sends request
headers with the test client, here the language a browser would ask for.

## Summary

- **Cache** expensive, shared results with **`get_or_set(key, f; timeout)`**. Cache ids or data,
  not personal pages. Start cache-using tests with **`cache_clear()`**.
- **`{% load humanize %}`**: `naturaltime`, `intcomma`, `intword` and friends.
- Times are stored in UTC and shown in the **current time zone**. **`with_timezone`** changes it,
  for a whole request if a **middleware** does it.
- A **middleware** is `get_response -> (req -> response)`. **Order matters**: each can use only
  what earlier ones set up.
- **Translations**: mark text with `{% translate %}` (or `gettext`), collect it with
  **`makemessages -l xx`**, translate the `.po` file, and let **`LocaleMiddleware`** and
  **`set_language`** choose.

The code at this point is tagged `ch13`.

In chapter 14, Juangout opens up to other programs: a JSON API, and RSS feeds.
