# Chapter 12: Moderation

Sooner or later someone posts spam. In this chapter members can **report** posts, and a group
of **moderators** gets a queue of reported posts, where they can hide them or dismiss the
reports. Moderators get their powers from **permissions** and **groups**, so making someone a
moderator is just adding them to a group.

Juango ideas in this chapter: **permissions** (built-in and custom), **groups**, `has_perm`,
**`permission_required`**, `{% if perms... %}`, the **`post_migrate`** signal, `Count` with a
**`filter`**, **`Prefetch`** with `to_attr`, and **admin actions**.

## Permissions and groups

Juango creates four **permissions** for every model: `add_`, `change_`, `delete_` and `view_`
(for example `posts.change_post`). The admin uses them to decide who may do what. You can add
your own, and you can give permissions to a member directly or, better, to a **group** the
member belongs to. Superusers have every permission.

Moderators need one thing members don't: to hide posts. That's not adding, changing or
deleting, so declare a permission of your own in `Post`'s `Meta`, along with a field to record
it:

```julia
    hidden = BooleanField(default = false, help_text = "Hidden by a moderator: shown to moderators only.")
    Meta(ordering = ["-created"],
         # a permission of our own, beside the add/change/delete/view ones every model gets
         permissions = [("hide_post", "Can hide posts")])
```

A permission's full name is `"<app label>.<codename>"`, here **`"posts.hide_post"`**.
**`has_perm(user, "posts.hide_post")`** asks whether a member has it, through their own
permissions, their groups, or being a superuser.

Permissions are rows in the database, created by `migrate`, so run `makemigrations` and
`migrate`. The migration only adds the `hidden` column. Permissions aren't part of the schema,
so `migrate` creates new ones every time it runs.

Hidden posts should vanish from every list, except for moderators. All the lists go through
`for_display`, so that's the one place to change. At its start:

```julia
function for_display(posts, user)
    # hidden posts are left out, except for moderators
    has_perm(user, "posts.hide_post") || (posts = filter(posts; hidden = false))
    ...
```

Because a post's own page uses `for_display` too, a hidden post is a 404 for members, but
moderators can still see it. In `_post.html`, show moderators which posts are hidden:

```html
    {% if post.hidden %}<span class="badge hidden-badge">hidden</span>{% endif %}
```

## The moderation app

Make an app, `julia --project manage.jl startapp moderation`, for reports and the queue. A report
records who reported which post, and why. In `moderation/models.jl`:

```julia
@choices Reason begin
    SPAM = "spam", "Spam or advertising"
    ABUSE = "abuse", "Harassment or abuse"
    OTHER = "other", "Something else"
end

@model struct Report
    post = ForeignKey(Post; on_delete = :CASCADE, related_name = :reports)
    reporter = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :reports_made)
    reason = CharField(max_length = 10, choices = Reason, default = Reason.SPAM)
    note = TextField(max_length = 500, blank = true, verbose_name = "Anything to add?")
    created = DateTimeField(auto_now_add = true)
    resolved = BooleanField(default = false)
    resolved_by = ForeignKey(USER_MODEL; null = true, blank = true, on_delete = :SET_NULL, related_name = :reports_resolved)
    Meta(ordering = ["-created"],
         constraints = [UniqueConstraint(fields = [:post, :reporter], name = "report_once")])
end

Base.show(io::IO, r::Report) = print(io, r.get_reason_display, " (", r.reporter, ")")
```

`on_delete = :SET_NULL` on `resolved_by` keeps a report if the moderator who resolved it is
deleted, which is why that field allows `null`. Reporting the same post twice is refused by a
constraint, as with likes in chapter 5.

`moderation/Moderation.jl`:

```julia
# The moderation app: members report posts, moderators hide them.
module Moderation

using Juango
using Dates
using ..Posts: Post, for_display

export Report, Reason

const APP = App("moderation"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                ready = () -> connect!(post_migrate, setup_moderators; sender = "moderation",
                                       dispatch_uid = "moderation_setup"))

include("models.jl")
include("setup.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")

end
```

Load it in `project.jl` after `notifications`, add `Moderation.APP` to `INSTALLED_APPS`, and mount
its URLs with `path("", include_urls(Moderation.APP))`.

### The Moderators group, made by `migrate`

There should be a "Moderators" group with the right permissions. You *could* tell everyone to make
it in the admin, but then every new copy of the site (a colleague's laptop, the test database,
production) would need the same clicking, done the same way. It's better as code that runs
whenever the database is set up.

The **`post_migrate`** signal is sent after `migrate` has run each app's migrations. Juango's own
`auth` app creates permissions in a `post_migrate` receiver that runs before other apps', so a
receiver for `moderation` can rely on `posts.hide_post` existing. `moderation/setup.jl`:

```julia
# The Moderators group, with the permissions moderating needs. A post_migrate receiver: it runs
# after every `migrate` (once auth has created the permissions), so the group always exists and
# is up to date. get_or_create and add! make running it again harmless.
const MODERATOR_PERMISSIONS = ["hide_post", "view_report", "change_report"]

function setup_moderators(sender; kw...)
    group, _ = get_or_create(Group; name = "Moderators")
    add!(group.permissions, collect(filter(Permission; codename__in = MODERATOR_PERMISSIONS))...)
end
```

The `ready` hook in `Moderation.jl` connects it, with `sender = "moderation"` so it runs once, for
this app. `Group` and `Permission` are ordinary models: a group has a name and `permissions`, and
every member has `groups`.

Run `migrate` once more, and the group appears. To make someone a moderator, add them to it, in
the admin (a member's page has their groups) or in Julia:

```julia
julia> add!(get(Member; username = "dee").groups, get(Group; name = "Moderators"))
```

> **If you know Django:** permissions, groups, `Meta.permissions`, `has_perm` and `post_migrate`
> are Django's. The receiver here is the usual way to create default groups.

## Reporting a post

Members see a "report" link on other people's posts. In `_post.html`, the delete link becomes:

```html
    {% if post.author_id == user.id %}· <a class="delete" href="{% url 'posts:delete' post.id %}">delete</a>
    {% elif user.is_authenticated %}· <a class="report" href="{% url 'moderation:report' post.id %}">report</a>{% endif %}
```

The view, in `moderation/views.jl`, is the familiar form pattern, with the post and reporter set on
the instance:

```julia
report_form(data = nothing; instance = nothing) = ModelForm(Report; data, instance, fields = [:reason, :note])

# Reporting a post: a form, then back to the post.
function report(req; id)
    post = get_object_or_404(Post; id, hidden = false)
    if exists(filter(Report; post, reporter = req.user))
        message!(req, :info, "You've already reported this post. Thank you.")
        return redirect(post)
    end
    form = report_form(req.method == "POST" ? req.POST : nothing; instance = Report(; post, reporter = req.user))
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, "Thanks. A moderator will take a look.")
        return redirect(post)
    end
    render(req, "moderation/report.html", Dict("form" => form, "post" => post))
end
```

`exists(qs)` asks whether a queryset has any rows, without fetching them.
`moderation/templates/moderation/report.html`:

```html
{% extends "base.html" %}

{% block title %}Report a post · Juangout{% endblock %}

{% block content %}
  <h1>Report this post</h1>
  {% include "posts/_post.html" %}
  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <button type="submit">Send report</button>
    <a href="{{ post.get_absolute_url }}">Cancel</a>
  </form>
{% endblock %}
```

A `CharField` with `choices` becomes a `<select>` of the reasons.

## The moderation queue

The queue lists posts with open reports, most-reported first, each with its reports. Two queries
do it, however many posts there are:

```julia
# The moderation queue: reported posts, most reported first, each with its open reports.
function queue(req)
    open_reports = Q(reports__resolved = false)
    posts = for_display(filter(Post, open_reports; hidden = false), req.user)   # as posts show everywhere
    posts = annotate(posts; report_count = Count(:reports; filter = open_reports, distinct = true))
    # each post's open reports (and their reporters), all in one more query, as post.open_reports
    posts = prefetch_related(posts, Prefetch(:reports; to_attr = :open_reports,
                                             queryset = select_related(filter(Report; resolved = false), :reporter)))
    posts = order_by(posts, "-report_count", "-created")
    page = get_page(Paginator(posts, 20), get(req.GET, "page", "1"))
    # (templates can't see to_attr lists yet, Juango #263, so hand them over alongside each post)
    rows = [(post = p, reports = p.open_reports) for p in page]
    render(req, "moderation/queue.html", Dict("page_obj" => page, "rows" => rows))
end
```

- **`Count(:reports; filter = open_reports)`** counts only the reports that match a condition,
  here the unresolved ones.
- **`Prefetch(:reports; queryset = ..., to_attr = :open_reports)`** is `prefetch_related` with
  control. `queryset` chooses which related rows to fetch (unresolved reports, with their
  reporters), and `to_attr` stores them on each post as `post.open_reports`, so that `post.reports`
  still means *all* of them.
- **`rows`** works around a current Juango bug
  ([#263](https://github.com/mcvmcv/Juango/issues/263)): templates can't read `to_attr` lists yet,
  so the view passes each post together with its reports as a `NamedTuple`.

Moderators decide with one of two buttons, which both post to one view:

```julia
# A moderator's decision on a reported post: hide it, or dismiss the reports.
function decide(req; id)
    post = get_object_or_404(Post; id)
    if get(req.POST, "decision", "") == "hide"
        post.hidden = true
        save!(post; update_fields = [:hidden])
        message!(req, :success, "The post is hidden.")
    else
        message!(req, :success, "The reports were dismissed.")
    end
    update!(filter(Report; post, resolved = false); resolved = true, resolved_by = req.user)
    redirect("moderation:queue")
end
```

`save!(post; update_fields = [:hidden])` writes just that column, so it can't overwrite a change
someone else made to the post at the same moment.

The URLs are where access is controlled, in `moderation/urls.jl`:

```julia
const urlpatterns = [
    path("posts/<int:id>/report/", login_required(report); name = "report"),
    path("moderation/", permission_required("posts.hide_post")(queue); name = "queue"),
    path("moderation/<int:id>/", require_POST(permission_required("posts.hide_post")(decide)); name = "decide"),
]
```

**`permission_required("posts.hide_post")`** makes a wrapper for views. Visitors who aren't logged
in are sent to log in, and members without the permission get "403 Forbidden".

`moderation/templates/moderation/queue.html`:

```html
{% extends "base.html" %}

{% block title %}Moderation · Juangout{% endblock %}

{% block content %}
  <h1>Moderation</h1>
  {% for row in rows %}
    <section class="reported">
      {% include "posts/_post.html" with post=row.post %}
      <p class="report-count">{{ row.post.report_count }} open report{{ row.post.report_count|pluralize }}</p>
      <ul class="reports">
        {% for r in row.reports %}
          <li><strong>{{ r.get_reason_display }}</strong>, from @{{ r.reporter.username }} {{ r.created|timesince }} ago
              {% if r.note %}<div class="note">{{ r.note }}</div>{% endif %}</li>
        {% endfor %}
      </ul>
      <form method="post" action="{% url 'moderation:decide' row.post.id %}" class="decide">
        {% csrf_token %}
        <button type="submit" name="decision" value="hide" class="danger">Hide post</button>
        <button type="submit" name="decision" value="dismiss" class="secondary">Dismiss reports</button>
      </form>
    </section>
  {% empty %}
    <p class="empty">Nothing to review. 🎉</p>
  {% endfor %}
  {% include "_pagination.html" %}
{% endblock %}
```

A submit button with a `name` and `value` sends them with the form, which is how `decide` knows
which one was pressed.

Moderators need a way in. In `base.html`, after "Edit profile":

```html
        {% if perms.posts.hide_post %}<a href="{% url 'moderation:queue' %}">Moderation</a>{% endif %}
```

**`perms`** is in every template's context: `perms.posts.hide_post` is `has_perm(user,
"posts.hide_post")`. Hiding the link is only a convenience, though. The real protection is
`permission_required` on the view.

## Admin actions

Staff who use the admin can moderate there too. An **admin action** runs on the rows selected in a
change list. In `moderation/admin.jl`:

```julia
# Admin actions: run on the reports selected in the change list.
function resolve_reports(admin, req, qs)
    n = update!(filter(qs; resolved = false); resolved = true, resolved_by = req.user)
    message!(req, :success, "Resolved $n report$(n == 1 ? "" : "s").")
end

function hide_reported_posts(admin, req, qs)
    post_ids = collect(values_list(qs, :post_id; flat = true))
    update!(filter(Post; id__in = post_ids); hidden = true)
    update!(filter(Report; post_id__in = post_ids, resolved = false); resolved = true, resolved_by = req.user)
    message!(req, :success, "Hid $(length(unique(post_ids))) post(s).")
end

Admin.register!(Report;
    list_display = [:post, :reason, :reporter, :created, :resolved],
    list_filter = [:resolved, :reason],
    search_fields = [:post__body, :reporter__username, :note],
    date_hierarchy = :created,
    readonly_fields = [:post, :reporter, :created],
    actions = [Admin.action(resolve_reports; description = "Mark selected reports resolved"),
               Admin.action(hide_reported_posts; description = "Hide the reported posts", confirm = true,
                            permission = :change)])
```

An action is a function of the admin, the request and the selected queryset. `update!` returns
how many rows it changed. `confirm = true` asks "are you sure?" first, and `permission = :change`
offers the action only to people allowed to change reports. `date_hierarchy` adds year/month/day
links above the list, and `readonly_fields` shows those fields without letting them be edited.

The CSS for the chapter:

```css
/* moderation */
.post .report { color: var(--muted); }
.hidden-badge { background: #fdecec; color: #b42318; margin-left: .3rem; }
.reported { border-bottom: 1px solid var(--line); padding-bottom: 1rem; margin-bottom: 1.25rem; }
.report-count { font-weight: 700; margin: .25rem 0; }
.reports { margin: 0 0 .75rem; padding-left: 1.2rem; color: var(--muted); }
.reports .note { color: var(--ink); font-style: italic; }
.decide button { margin-right: .5rem; }
```

## Tests

Create `moderation/tests.jl`, and `tests/test_moderation.jl` to run it:

```julia
using Test
using Juango.Testing

@testset "moderation" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        mod = create_user("mo"; password = "correct-horse-battery")
        spam = create(Post; author = bob, body = "BUY CHEAP WATCHES")

        # migrate made the Moderators group (the post_migrate receiver); joining it grants the permission
        moderators = get(Group; name = "Moderators")
        @test Set(p.codename for p in moderators.permissions) == Set(["hide_post", "view_report", "change_report"])
        @test !has_perm(mod, "posts.hide_post")
        add!(mod.groups, moderators)
        mod = get(Member; id = mod.id)                 # permissions are cached on the user: fetch it again
        @test has_perm(mod, "posts.hide_post")

        # members report posts, once each
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/everyone/"), "/posts/$(spam.id)/report/")
        r = post(c, "/posts/$(spam.id)/report/", Dict("reason" => "spam", "note" => "Obvious spam"); follow = true)
        @test assert_contains(r, "A moderator will take a look.")
        r = post(c, "/posts/$(spam.id)/report/", Dict("reason" => "abuse"); follow = true)
        @test assert_contains(r, "already reported")
        force_login!(c, cat)
        post(c, "/posts/$(spam.id)/report/", Dict("reason" => "abuse"))
        @test count(spam.reports) == 2

        # only moderators can see the queue
        @test get(c, "/moderation/").status == 403
        @test assert_not_contains(get(c, "/"), ">Moderation</a>")      # no link in the header
        @test assert_redirects(get(Client(), "/moderation/"), "/accounts/login/?next=%2Fmoderation%2F")
        force_login!(c, mod)
        r = get(c, "/moderation/")
        @test r.status == 200
        p = only(r.context["page_obj"])
        @test p.report_count == 2
        @test length(p.open_reports) == 2
        @test assert_contains(r, "Obvious spam")

        # hiding: gone from timelines and its page for members, but still there for moderators
        post(c, "/moderation/$(spam.id)/", Dict("decision" => "hide"))
        @test get(Post; id = spam.id).hidden
        @test count(filter(Report; post = spam, resolved = false)) == 0
        @test get(Report; post = spam, reporter = ann).resolved_by == mod
        @test isempty(get(c, "/moderation/").context["page_obj"])
        force_login!(c, ann)
        @test assert_not_contains(get(c, "/everyone/"), "BUY CHEAP WATCHES")
        @test get(c, "/posts/$(spam.id)/").status == 404
        force_login!(c, mod)
        @test assert_contains(get(c, "/posts/$(spam.id)/"), "hidden")

        # dismissing leaves the post alone
        fine = create(Post; author = bob, body = "A perfectly fine post")
        create(Report; post = fine, reporter = ann, reason = Reason.OTHER)
        post(c, "/moderation/$(fine.id)/", Dict("decision" => "dismiss"))
        @test !get(Post; id = fine.id).hidden
        @test all(r.resolved for r in fine.reports)

        # deciding is POST only, and moderators only
        @test get(c, "/moderation/$(fine.id)/").status == 405
        force_login!(c, ann)
        @test post(c, "/moderation/$(fine.id)/", Dict("decision" => "hide")).status == 403
    end
end

@testset "moderation in the admin" begin
    rollback_after() do
        boss = create_superuser("boss"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        spam = create(Post; author = bob, body = "spam spam spam")
        r1 = create(Report; post = spam, reporter = boss, reason = Reason.SPAM)
        c = Client()
        force_login!(c, boss)
        @test get(c, "/admin/moderation/report/").status == 200
        # run the "hide the reported posts" action on the selected report
        r = post(c, "/admin/moderation/report/", Dict("action" => "hide_reported_posts", "_selected_action" => string(r1.id),
                                                      "post" => "yes"); follow = true)
        @test r.status == 200
        @test get(Post; id = spam.id).hidden
        @test get(Report; id = r1.id).resolved
    end
end
```

- The test database is made by running the migrations, so the `post_migrate` receiver runs and
  the Moderators group exists from the start, just as on a real site.
- **Permissions are cached** on a user object the first time they're checked, so after changing
  someone's groups, fetch the user again.
- Test the refusals as carefully as the successes: a 403 for members, a login redirect for
  visitors, and a 405 for GET.
- An admin action is a POST to the change list, with the action's name (the function's) and the
  selected ids. `"post" => "yes"` answers the confirmation.

## Summary

- Every model gets **`add_`, `change_`, `delete_` and `view_`** permissions. Add your own with
  `Meta(permissions = [(codename, description)])`. Names are `"app.codename"`.
- Give permissions to **groups** and put members in groups. **`has_perm`** checks, and
  superusers have everything.
- **`permission_required(perm)(view)`** protects a view. **`{% if perms.app.codename %}`** adapts
  templates, but only views enforce.
- A **`post_migrate`** receiver is the place for default data such as groups, idempotent with
  `get_or_create`.
- **`Count(...; filter = Q(...))`** counts some related rows. **`Prefetch(...; queryset, to_attr)`**
  prefetches a chosen subset.
- **Admin actions** (`Admin.action(f; description, confirm, permission)`) act on selected rows.

The code at this point is tagged `ch12`.

In chapter 13 Juangout gets some polish: a trending page made fast with caching, friendlier
numbers and times, members' own time zones, and a second language.
