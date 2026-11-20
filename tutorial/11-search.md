# Chapter 11: Search

A growing network needs ways to find things. In this chapter posts get **hashtags**, each with
its own page, and Juangout gets a **search** page for posts and members, with filters, that
updates as you type.

Juango ideas in this chapter: **overriding `save!`**, `get_or_create` and `set!`, **custom
template filters** in a tag library, **`FilterSet`**, `{% querystring %}`, and htmx **active
search** with `htmx_partial`.

## Hashtags

### The Tag model

A tag is just a name, and posts and tags are many-to-many. Add to `posts/models.jl`, *before*
`Post`:

```julia
# A hashtag. Posts get their tags from the #words in their body (see save! below).
@model struct Tag
    name = CharField(max_length = 50, unique = true)      # lowercase, without the #
    Meta(ordering = ["name"])
end

Base.show(io::IO, t::Tag) = print(io, "#", t.name)
Juango.get_absolute_url(t::Tag) = reverse_url("posts:tag"; name = t.name)
```

and give `Post` the relation, after `likers`:

```julia
    tags = ManyToManyField(Tag; related_name = :posts, blank = true)
```

There's no `through` model this time, because a post's tag needs nothing recorded about it.
Juango makes a plain join table, `post_tags`. Make and apply the migration, and export `Tag`.

### Finding the tags: overriding `save!`

Members won't pick tags from a list. They'll write `#julia` in their post, so the tags should
follow the text. Every time a post is saved, its tags should be brought up to date with the
`#words` in its body.

Chapter 9 used signals to react to saves, but that was for code in *another* app. When the
behaviour belongs to the model itself, it's clearer to say so on the model, by adding a method
of **`save!`** for `Post`. Add to `posts/models.jl`, after `get_absolute_url`:

```julia
# "#word", but not the "#x27" inside an escaped apostrophe ("&#x27;") or a word like "C#"
const HASHTAG = r"(?<![&\w])#(\w{1,50})"
hashtags(text) = unique(lowercase(m.captures[1]) for m in eachmatch(HASHTAG, text))

# Saving a post also brings its tags up to date with the #words in its body. A method of
# save! for Post runs wherever a post is saved: forms, the admin, create, your own code.
function Juango.save!(p::Post; kw...)
    invoke(Juango.save!, Tuple{Juango.Model}, p; kw...)     # the usual save!, for any model
    set!(p.tags, [first(get_or_create(Tag; name)) for name in hashtags(p.body)])
    p
end
```

- **The regular expression** finds `#` followed by word characters. `(?<![&\w])` means "not just
  after `&` or a letter", so `C#` isn't a tag. Nor is the `#x27` in `&#x27;`, which is how an
  escaped apostrophe looks in HTML, as you'll see in a moment.
- **`invoke(Juango.save!, Tuple{Juango.Model}, p; kw...)`** calls the general `save!` method, the
  one for any model, on `p`. That's how a Julia method calls the method it's replacing (Python
  would say `super().save()`). The `kw...` passes along options such as `update_fields`.
- **`get_or_create(Tag; name)`** returns `(tag, created)`: the existing tag, or a new one.
- **`set!(p.tags, tags)`** makes the relation exactly that list, adding and removing only what's
  different.

The tags have to be set *after* the post is saved: a brand-new post has no id until then, and a
relation needs one.

> **If you know Django:** this is overriding `Model.save()`. `get_or_create` and `set` are the
> same as Django's.

### Linking hashtags: a custom template filter

In a post, `#julia` should be a link to the tag's page. That's a job for a **template filter**,
and Juango lets you write your own. Create `posts/templatetags.jl`:

```julia
# A template tag library: `{% load posts_extras %}` in a template, then `{{ text|hashtags }}`.
const posts_extras = TagLibrary("posts_extras")

# Turn #words into links to their tag pages. The text is escaped first (unless it's already
# safe HTML, as linebreaksbr's output is), so only our own <a> tags are HTML.
function linkify_hashtags(value, _)
    html = value isa SafeString ? string(value) : escape_html(string(value))
    mark_safe(replace(html, HASHTAG => function (m)
        name = lowercase(m[2:end])
        "<a class=\"hashtag\" href=\"$(reverse_url("posts:tag"; name))\">$m</a>"
    end))
end
filter!(linkify_hashtags, posts_extras, "hashtags")
```

A filter is a function of the value and an argument (`{{ x|filter:arg }}`). This one ignores the
argument. **`filter!`** adds it to the **`TagLibrary`**, which templates load with
**`{% load posts_extras %}`**. Include the file in `Posts.jl`, before `views.jl`.

Filters that produce HTML need care, because this is where cross-site scripting bugs come from:

- Templates escape everything by default, so `<script>` in a post shows as text. A filter that
  returns HTML must say it's **safe** (`mark_safe`), or its `<a>` tags would be escaped as well.
- So the filter must escape the post's text *itself* first. Otherwise marking the result safe
  would also let through any HTML a member typed. **`escape_html`** does it, unless the value is
  already a **`SafeString`**, meaning someone (here `linebreaksbr`) has escaped it already.
- Escaped text contains things like `&#x27;` (an apostrophe), which is why `HASHTAG` refuses a `#`
  that comes just after `&`.

Use it in `_post.html`: load the library on the first line,

```html
{% load posts_extras %}
```

and pass the body through the filter:

```html
  <p class="body">{{ post.body|linebreaksbr|hashtags }}</p>
```

### Tag pages

One more `ListView`, in `posts/views.jl`:

```julia
# The posts with one tag: /tags/julia/
const tag_posts = ListView(Post; template = "posts/tag.html", paginate_by = 20,
    get_queryset = v -> for_display(filter(Post; tags = get_object_or_404(Tag; name = v.kwargs[:name])), v.request.user),
    get_context_data = (v, ctx) -> (ctx["tag"] = get(Tag; name = v.kwargs[:name]); ctx))
```

`filter(Post; tags = tag)` finds posts with that tag among their tags. The URL is
`path("tags/<str:name>/", tag_posts; name = "tag")`, and the template,
`posts/templates/posts/tag.html`, is:

```html
{% extends "base.html" %}

{% block title %}#{{ tag.name }} · Juangout{% endblock %}

{% block content %}
  <h1>#{{ tag.name }}</h1>
  <p class="aside">{{ paginator.count }} post{{ paginator.count|pluralize }}</p>
  {% for post in post_list %}
    {% include "posts/_post.html" %}
  {% endfor %}
  {% include "_pagination.html" %}
{% endblock %}
```

`paginator.count` is the total across all pages.

## Search

### Filters from the query string: `FilterSet`

A search page is a list whose contents depend on the query string: `?q=garden&author=bob`. Each
parameter becomes a condition, but only when it's present, and a malformed one (a date like
`2026-13-45`) should be ignored, not crash the page. **`FilterSet`** handles all that. You
describe the filters, and it builds a form from them, reads `req.GET` into it, and applies the
valid ones to a queryset. In `posts/views.jl`:

```julia
# Search: members whose name matches, and posts filtered by a FilterSet from the query string.
function search(req)
    q = strip(get(req.GET, "q", ""))
    posts = FilterSet(Post, [
        :q => CharFilter(label = "Search for", distinct = true, method = (qs, name, v) ->
            filter(qs, Q(body__icontains = v) | Q(author__username__icontains = v) | Q(tags__name = lowercase(lstrip(v, '#'))))),
        :author => CharFilter(field_name = "author__username", lookup = "iexact", label = "By"),
        :pictures => BooleanFilter(label = "With pictures", method = (qs, name, v) ->
            v ? exclude(qs; image = "") : filter(qs; image = "")),
        :created => DateFromToRangeFilter(label = "Posted"),
    ]; data = req.GET, queryset = for_display(objects(Post), req.user), request = req)
    members = isempty(q) ? [] :
        collect(filter(get_user_model(), Q(username__icontains = q) | Q(display_name__icontains = q); is_active = true)[1:10])
    page = get_page(Paginator(posts.qs, 20), get(req.GET, "page", "1"))
    render(req, "posts/search.html",
           Dict("q" => q, "filter" => posts, "members" => members, "page_obj" => page,
                "searched" => any(!isempty(get(req.GET, k, "")) for k in ("q", "author", "pictures", "created_after", "created_before")));
           htmx_partial = "results")     # htmx asks for just the results as you type
end
```

Each filter is a name (the query-string parameter) and a filter type:

- **`CharFilter(field_name = "author__username", lookup = "iexact")`** is the simple kind:
  `?author=bob` becomes `filter(qs; author__username__iexact = "bob")`.
- **`method = (qs, name, value) -> ...`** replaces that with your own code. The main search box
  matches the text, the author's username, or a tag, with a leading `#` meaning just the tag.
  `distinct = true`, because the join through tags could otherwise list a post twice.
- **`BooleanFilter`** shows a yes/no/either choice. Posts without a picture store an empty
  string, hence `exclude(qs; image = "")`.
- **`DateFromToRangeFilter`** is two date fields, `?created_after=...&created_before=...`.
- **`queryset`** is where filtering starts: `for_display`, so results show like-counts and
  everything else as usual.

`posts.qs` is the filtered queryset, and `posts.form` the form, bound to the query string, for the
template. Members are searched separately, by username or display name.

> **If you know Django:** this is django-filter's `FilterSet`, built in, with the filters as
> name/filter pairs rather than class attributes.

### The page

Add `path("search/", search; name = "search")` to `posts/urls.jl` and a "Search" link to the
header in `base.html`. Then create `posts/templates/posts/search.html`:

```html
{% extends "base.html" %}

{% block title %}{% if q %}{{ q }} · {% endif %}Search · Juangout{% endblock %}

{% block content %}
  <h1>Search</h1>
  {# An ordinary GET form. With htmx, typing or changing a filter fetches just the results, #}
  {# and hx-push-url keeps the address bar (and so the back button and sharing) up to date. #}
  <form method="get" action="{% url 'posts:search' %}" class="form search-form" role="search"
        hx-get="{% url 'posts:search' %}" hx-trigger="input changed delay:300ms, change" hx-target="#results" hx-push-url="true">
    <div class="search-main">
      <label for="id_q">{{ filter.form.q.label }}</label>
      <input type="search" name="q" id="id_q" value="{{ q }}" placeholder="Words, @names or #tags" autofocus>
    </div>
    <details class="filters"{% if request.GET.author or request.GET.pictures or request.GET.created_after or request.GET.created_before %} open{% endif %}>
      <summary>Filters</summary>
      <div>{{ filter.form.author.label_tag }} {{ filter.form.author }}</div>
      <div>{{ filter.form.pictures.label_tag }} {{ filter.form.pictures }}</div>
      <div>{{ filter.form.created.label_tag }} {{ filter.form.created }}</div>
    </details>
    <noscript><button type="submit">Search</button></noscript>
  </form>

  <div id="results">
    {% partialdef results inline %}
      {% if members %}
        <h2 class="section-title">Members</h2>
        <ul class="members">
          {% for m in members %}
            <li>{% include "accounts/_avatar.html" with member=m size=28 %}
              <a class="author" href="{{ m.get_absolute_url }}">{{ m.name }}</a> <span class="handle">@{{ m.username }}</span></li>
          {% endfor %}
        </ul>
      {% endif %}
      {% if searched %}
        <h2 class="section-title">{{ page_obj.paginator.count }} post{{ page_obj.paginator.count|pluralize }}</h2>
        {% for post in page_obj %}
          {% include "posts/_post.html" %}
        {% empty %}
          <p class="empty">No posts match.</p>
        {% endfor %}
        {% if page_obj.has_next %}
          <p class="pagination"><a href="{% querystring page=page_obj.next_page_number %}">More results →</a></p>
        {% endif %}
      {% endif %}
    {% endpartialdef %}
  </div>
{% endblock %}
```

- **A search form is a GET form.** Searching changes nothing, and GET puts the query in the URL,
  so results can be bookmarked and shared.
- **Active search.** `hx-trigger="input changed delay:300ms, change"` sends the form 300 ms after
  you stop typing (and whenever a filter changes), and `hx-target="#results"` swaps in the reply.
  **`hx-push-url="true"`** updates the address bar to match, so the back button and sharing keep
  working.
- **`render(...; htmx_partial = "results")`** is chapter 8's partials made easy. For an htmx request
  `render` sends only the `results` partial, and for anything else the whole page.
- **`{% querystring page=... %}`** builds a link to the current URL with one parameter changed, so
  "More results" keeps `q` and the filters. A plain `?page=2` would lose them.
- Without JavaScript, the `<noscript>` button submits the form the ordinary way.

Finally, the CSS:

```css
/* search and tags */
.hashtag { text-decoration: none; font-weight: 600; }
.hashtag:hover { text-decoration: underline; }
.search-main input { width: 100%; padding: .65rem .8rem; font: inherit; font-size: 1.1rem; border: 1px solid var(--line); border-radius: 8px; background: var(--card); }
.filters { margin-top: .75rem; color: var(--muted); }
.filters summary { cursor: pointer; }
.filters > div { margin: .5rem 0; }
.filters label { display: inline-block; min-width: 7rem; font-weight: 400; }
.filters input, .filters select { padding: .3rem .5rem; font: inherit; border: 1px solid var(--line); border-radius: 6px; background: var(--card); }
```

`icontains` is fine for a few thousand posts. For millions, and for searches that understand
language ("gardening" finding "garden"), you want a real full-text index. PostgreSQL has one,
and chapter 15, which moves Juangout to PostgreSQL, shows Juango's support for it.

## Tests

In `posts/tests.jl`:

```julia
@testset "hashtags" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        @test Posts.hashtags("Loving #Julia and #juliaLang, not C# or &#x27;") == ["julia", "julialang"]

        # saving a post gives it its tags, and editing it keeps them up to date
        p = create(Post; author = ann, body = "Learning #Julia today #til")
        @test Set(t.name for t in p.tags) == Set(["julia", "til"])
        p.body = "Learning #Julia, still"
        save!(p)
        @test [t.name for t in p.tags] == ["julia"]
        @test count(Tag) == 2                           # the #til tag remains, with no posts

        # the filter links hashtags, and leaves everything else escaped
        r = get(Client(), get_absolute_url(p))
        @test assert_contains(r, "<a class=\"hashtag\" href=\"/tags/julia/\">#Julia</a>"; html = false)
        create(Post; author = ann, body = "It's <b>bold</b> #fun")
        r = get(Client(), "/tags/fun/")
        @test assert_contains(r, "It&#x27;s &lt;b&gt;bold&lt;/b&gt;"; html = false)   # escaped, apostrophe not a tag
        @test assert_not_contains(r, "/tags/x27/")

        # a tag's page lists its posts; an unknown tag is a 404
        r = get(Client(), "/tags/julia/")
        @test [q.body for q in r.context["post_list"]] == ["Learning #Julia, still"]
        @test get(Client(), "/tags/nosuchtag/").status == 404
    end
end

@testset "search" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        create(Post; author = ann, body = "Tomatoes are ripe #garden")
        create(Post; author = bob, body = "My garden is a jungle")
        create(Post; author = bob, body = "Nothing to see here")
        found(r) = Set(p.body for p in r.context["page_obj"])
        c = Client()

        @test get(c, "/search/").status == 200
        @test isempty(get(c, "/search/").context["members"])

        r = get(c, "/search/?q=garden")                 # in the text, or as a tag
        @test found(r) == Set(["Tomatoes are ripe #garden", "My garden is a jungle"])
        @test found(get(c, "/search/?q=%23garden")) == Set(["Tomatoes are ripe #garden"])  # just the tag
        @test found(get(c, "/search/?q=garden&author=bob")) == Set(["My garden is a jungle"])
        @test found(get(c, "/search/?author=ANN")) == Set(["Tomatoes are ripe #garden"])     # iexact

        # members by username or display name
        @test [m.username for m in get(c, "/search/?q=lee").context["members"]] == ["ann"]

        # a picture filter, and a date range
        p = first(filter(Post; author = bob, body = "Nothing to see here"))
        update!(filter(Post; id = p.id); image = "posts/x.png")
        @test found(get(c, "/search/?pictures=true")) == Set(["Nothing to see here"])
        @test length(found(get(c, "/search/?created_after=2000-01-01"))) == 3
        @test isempty(found(get(c, "/search/?created_before=2000-01-01")))

        # htmx gets just the results; the next-page link keeps the filters
        r = get(c, "/search/?q=garden"; htmx = true)
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "2 posts")
        for i in 1:25
            create(Post; author = bob, body = "garden note $i")
        end
        r = get(c, "/search/?q=garden&author=bob")
        link = match(r"href=\"([^\"]*page=2[^\"]*)\"", text(r))
        @test link !== nothing
        @test occursin("q=garden", link[1]) && occursin("author=bob", link[1])
    end
end
```

The hashtag test includes the two classic mistakes, an apostrophe and some HTML, to prove they
come out escaped. `%23` is how `#` is written in a URL (a bare `#` would start the URL's
fragment). `text(r)` is the response body as a string.

## Summary

- **A method of `save!`** for a model adds behaviour to every save. `invoke(save!,
  Tuple{Juango.Model}, obj; kw...)` runs the usual save.
- **`get_or_create`** fetches or makes a row. **`set!`** makes a many-to-many relation exactly a
  given list.
- **Custom filters** go in a `TagLibrary` (`filter!`) and are loaded with `{% load %}`. A filter
  that makes HTML must escape its input and `mark_safe` its output.
- **`FilterSet`** turns query-string parameters into validated filters on a queryset:
  `CharFilter`, `BooleanFilter`, `DateFromToRangeFilter`, and your own with `method`.
- Search with **GET** forms. **`{% querystring %}`** keeps parameters in links.
- **Active search**: `hx-trigger` with `delay`, `hx-push-url`, and `render(...; htmx_partial =
  "name")`.

The code at this point is tagged `ch11`.

As Juangout grows, someone has to deal with posts that break the rules. In chapter 12 some
members become moderators.
