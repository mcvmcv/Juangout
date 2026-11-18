# Chapter 2: Members

A social network needs members. In this chapter you create Juangout's first **app**,
`accounts`, give it a custom **user model** called `Member`, create the database with
**migrations**, and meet the **admin**, a ready-made back office for your data. You'll finish
with a public profile page for each member at `/@username/`.

Juango ideas in this chapter: **apps**, **models**, **custom user models**, **migrations**,
the **admin**, `get_object_or_404`, and tests that use the database.

## Apps

So far everything has been in the project's top-level files. That's fine for a home page,
but a real site has several areas (members, posts, notifications), and each comes with its
own models, views, URLs and templates. Juango groups each area into an **app**: a Julia
module that the project installs as a unit.

Create the `accounts` app:

```sh
julia --project manage.jl startapp accounts
```

```
accounts/
├── Accounts.jl          the module
├── models.jl  admin.jl  views.jl  urls.jl  tests.jl
├── templates/accounts/  this app's templates
├── static/accounts/     this app's static files
└── migrations/          this app's migrations
```

`Accounts.jl` defines the module and its `APP`, which tells Juango where the app's files are.
Change it so that it also **exports** `Member`, the model you're about to write, so the rest of
the project can use the name:

```julia
# The accounts app: Juangout's members and their profiles.
module Accounts

using Juango
using Dates

export Member

const APP = App("accounts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

include("models.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")

end
```

Templates go in `templates/accounts/`, not straight in `templates/`. Juango looks for a
template in the project's `templates/` and then in every app's, so `"accounts/profile.html"`
is unambiguous even if another app has a `profile.html` of its own. Delete the sample
`templates/accounts/index.html`.

> **If you know Django:** `App(...)` is `AppConfig`, and the module is the app package. The
> `templates/<app>/` namespacing convention is Django's.

## The Member model

A **model** describes one kind of thing your site stores. Each model becomes a database
table, each field a column, and each instance a row. You write models with `@model`.

Juango already has a `User` model, with a username, a hashed password, an email address, and
flags such as `is_staff`. Juangout members need more than that: a display name and a short
bio. Rather than keep those in a separate table, make Juangout's own user model by extending
`AbstractUser`. It inherits every field `User` has, and you add your own.

Replace `accounts/models.jl` with:

```julia
# Juangout's members. A custom user model: everything Juango's User has (username, password,
# email, is_staff, ...) plus our own fields. AUTH_USER_MODEL in settings.jl points at it.
@model struct Member <: AbstractUser
    display_name = CharField(max_length = 50, blank = true,
                             help_text = "The name shown on your posts. Leave blank to use your username.")
    bio = TextField(max_length = 300, blank = true)
end

Base.show(io::IO, m::Member) = print(io, "@", m.username)

# `member.name` in Julia, `{{ member.name }}` in templates
Juango.tattr(m::Member, ::Val{:name}) = isempty(m.display_name) ? m.username : m.display_name

Juango.get_absolute_url(m::Member) = reverse_url("accounts:profile"; username = m.username)
```

Here's what's going on:

- **Fields.** `CharField` is a short string with a `max_length`, and `TextField` is text of any
  length (`max_length` here only limits what forms accept). `blank = true` means the field may
  be left empty. Fields are required unless you say otherwise.
- **`Base.show`** controls how a member prints: in the REPL, in the admin, and in error
  messages. It's the Julia counterpart of a Python `__str__`.
- **`tattr`** adds a computed attribute. Members are shown by their display name, or by their
  username if they haven't set one. Defining that once as `name` means every template can say
  `{{ member.name }}`.
- **`get_absolute_url`** gives the canonical URL of a member's page. Templates and the admin
  ("View on site") use it.

Then tell Juango that `Member` is the user model, and install the app. In `settings.jl`:

```julia
    INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages",
                      Accounts.APP],
    AUTH_USER_MODEL = "accounts.Member",
```

`"accounts.Member"` is the model's **label**: its app's name and the model name. Then load the
app in `project.jl`, before the files that use it:

```julia
const BASE_DIR = @__DIR__

# Apps: each is a module with its own models, views, urls, templates and migrations
Juango.project_include(joinpath(BASE_DIR, "accounts", "Accounts.jl"))
using .Accounts
```

### Why a custom user model now?

You could have kept Juango's `User` and added a `Profile` model alongside it. But you can't
know today what a member will need next year, and changing the user model once a site has
users is a migration with a lot of moving parts. Starting with a custom user model, even one
with no extra fields at all, costs nothing and leaves room to grow. It's the first thing to do
in any project that will have users, before the first `migrate`. That's why chapter 1 left
the database alone.

> **If you know Django:** this is the setup Django's documentation recommends for every new
> project: `class Member(AbstractUser)` and `AUTH_USER_MODEL = "accounts.Member"`. Juango even
> has a `swap_user_model` command for moving an existing site over later, but it's still best
> not to need it.

## Migrations

The model describes the table, but the table doesn't exist yet. Changes to models reach the
database through **migrations**: small, versioned files that say how to get from one version
of the schema to the next. Juango writes them for you:

```sh
julia --project manage.jl makemigrations
```

```
Migrations for 'accounts':
  accounts/migrations/0001_initial.jl
    - Create model Member (table member)
    - Create model Member_groups (table member_groups)
    - Create model Member_user_permissions (table member_user_permissions)
```

Open `accounts/migrations/0001_initial.jl`. It's plain Julia: a `CreateModel` with one
`Column` for each field (yours at the end, after the ones `AbstractUser` provides), plus two
join tables that link members to permission groups. You'll rarely edit a migration by
hand, but you should read each one before you apply it. Commit migrations to git with
the code that needs them.

Now apply them:

```sh
julia --project manage.jl migrate
```

```
Operations to perform:
  Apply all migrations: accounts, admin, auth, contenttypes, sessions
Running migrations:
  Applying contenttypes.0001_initial... OK
  Applying auth.0001_initial... OK
  Applying accounts.0001_initial... OK
  Applying admin.0001_initial... OK
  Applying sessions.0001_initial... OK
```

That's the whole database: your `accounts` app plus Juango's own apps (sessions, the admin's
log, permission groups). It's an SQLite file, `db.sqlite3`, in the project directory. It's
in `.gitignore`, because your data doesn't belong in the repository.

Two more commands are worth knowing now:

```sh
julia --project manage.jl showmigrations      # which migrations have been applied: [X] or [ ]
julia --project manage.jl sqlmigrate accounts 0001_initial   # the SQL a migration runs
```

From here on the routine is always the same: **change a model, `makemigrations`, read the file,
`migrate`.**

## The admin

Juango comes with an **admin site**: pages for finding, adding, editing and deleting any
model's data, with search, filters and a log of who changed what. You build public pages
for members, and the admin is for you and your moderators.

Create an account for yourself:

```sh
julia --project manage.jl createsuperuser
```

It asks for a username, an email address and a password. A **superuser** may do anything,
including log in to the admin. Start the server, go to <http://127.0.0.1:8000/admin/>, and log
in. Under *Accounts* you'll find *Members*, with your account in the list.

Juango registered `Member` with the admin itself, because it's the user model, using the admin
setup Juango's own `User` has, which handles password hashing properly. To show the new fields
in the list, replace `accounts/admin.jl` with:

```julia
# The user model gets the admin pages Juango's own User has (password hashing, search and
# filters); these options add our fields to the list.
Admin.register_user_model!(Member;
    list_display = [:username, :display_name, :email, :is_staff, :date_joined])
```

One more line is needed for now. Juango's own `User` is still registered with the admin when
`urls.jl` builds the admin's URLs, because `settings.jl`, where `AUTH_USER_MODEL` is set, loads
after it. The admin's front page would then try to count rows in a `User` table that doesn't
exist. Until that's fixed in Juango ([#242](https://github.com/mcvmcv/Juango/issues/242)), add
this to the end of `settings.jl`:

```julia
# Workaround for Juango #242: Admin.urls() (in urls.jl) runs before AUTH_USER_MODEL is set
# and registers Juango's own User with the admin. Member replaces it.
Admin.is_registered(Juango.User) && Admin.unregister!(Juango.User)
```

Click your username, give yourself a display name and a bio, and save. Then add another member
or two with *Add member*. You'll need them in a moment.

> **If you know Django:** `Admin.register!(Model; list_display = ..., search_fields = ...,
> list_filter = ...)` is `admin.site.register` with a `ModelAdmin`, with the options as
> keywords. `register_user_model!` is the equivalent of registering your model with
> `UserAdmin`.

## Profile pages

Every member gets a public page at `/@username/`. Three pieces make a page: a URL, a view,
and a template. This time all three live in the app.

`accounts/urls.jl`:

```julia
const urlpatterns = [
    path("@<str:username>/", profile; name = "profile"),     # {% url 'accounts:profile' username %}
]
```

`<str:username>` **captures** part of the URL. `str` is the converter: it matches any text
up to the next `/`. Other converters include `int`, `slug` and `uuid`. The captured value is
passed to the view as a keyword argument.

`accounts/views.jl`:

```julia
function profile(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    render(req, "accounts/profile.html", Dict("member" => member))
end
```

`get_object_or_404` looks up one row: here, the active member with this username. If there's
none, it stops the view, and the visitor gets a "404 Not Found" page instead of an error. The
keyword arguments are **lookups**, which you'll use all the time. `username` on its own is
Julia's shorthand for `username = username`.

`accounts/templates/accounts/profile.html`:

```html
{% extends "base.html" %}

{% block title %}{{ member.name }} (@{{ member.username }}) · Juangout{% endblock %}

{% block content %}
  <section class="profile">
    <h1>{{ member.name }}</h1>
    <p class="handle">@{{ member.username }} · joined {{ member.date_joined|date:"F Y" }}</p>
    {% if member.bio %}<p class="bio">{{ member.bio|linebreaksbr }}</p>{% endif %}
  </section>
{% endblock %}
```

The `|` applies a **filter** to a value. `date:"F Y"` formats a date as "November 2026", and
`linebreaksbr` turns the line breaks in a bio into `<br>`s, after escaping the text, so it's
still safe.

Finally, include the app's URLs in the project's `urls.jl`:

```julia
const urlpatterns = [
    path("", home; name = "home"),
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("", include_urls(Accounts.APP)),            # /@username/
]
```

`include_urls` mounts all of an app's patterns under a prefix. Here the prefix is `""`, so the
profile is at `/@ann/` rather than `/accounts/@ann/`. Including an app's URLs also puts them in
a **namespace** named after the app, which is why the name is `accounts:profile`.

Add a little CSS to `static/style.css`:

```css
.profile h1 { margin: 0; font-size: 1.75rem; letter-spacing: -0.02em; }
.profile .handle { color: var(--muted); margin: 0 0 .75rem; }
.profile .bio { margin: 0 0 1rem; }
```

Visit `/@` followed by your username. The admin now has a "View on site" link on each member's
page too, thanks to `get_absolute_url`.

## Testing with the database

Tests for an app belong in the app. Replace `accounts/tests.jl` with:

```julia
using Test
using Juango.Testing

@testset "accounts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee", bio = "Hello!")
        bob = create_user("bob"; password = "correct-horse-battery")

        @test get_user_model() === Member
        @test ann.name == "Ann Lee"
        @test bob.name == "bob"                    # falls back to the username
        @test get_absolute_url(ann) == "/@ann/"

        c = Client()
        r = get(c, "/@ann/")
        @test r.status == 200
        @test r.context["member"] == ann
        @test assert_contains(r, "Ann Lee")
        @test assert_contains(r, "Hello!")

        @test get(c, "/@nobody/").status == 404

        # inactive members have no profile page
        bob.is_active = false
        save!(bob)
        @test get(c, "/@bob/").status == 404
    end
end

@testset "admin" begin
    rollback_after() do
        boss = create_superuser("boss"; password = "correct-horse-battery", email = "boss@example.com")
        c = Client()
        force_login!(c, boss)
        @test get(c, "/admin/").status == 200
        r = get(c, "/admin/accounts/member/")
        @test r.status == 200
        @test assert_contains(r, "boss")
    end
end
```

New things here:

- **`rollback_after`** runs the block inside a database transaction and rolls it back at the
  end, so every test starts with an empty database and leaves it that way.
- **`create_user`** and **`create_superuser`** create members of whatever `AUTH_USER_MODEL` is,
  with their password hashed. Extra keywords set the other fields.
- **`save!`** writes a changed instance back to the database.
- **`force_login!`** logs the test client in as a member, without a login form.

At the moment `manage.jl test` only collects files from the project's `tests/` directory, not
from apps. (This is a known gap, [Juango #239](https://github.com/mcvmcv/Juango/issues/239).)
Until it's fixed, add a one-line `tests/test_accounts.jl` that runs the app's tests:

```julia
# manage.jl test only looks in tests/ for now (Juango #239), so run the app's tests from here.
include(joinpath(@__DIR__, "..", "accounts", "tests.jl"))
```

```sh
julia --project manage.jl test
```

## Summary

- An **app** is a module with its own models, views, URLs, templates and migrations. Install
  it in `project.jl` and `INSTALLED_APPS`, and mount its URLs with `include_urls`.
- **Models** are `@model` structs. Start every project with a **custom user model**
  (`<: AbstractUser`, `AUTH_USER_MODEL`) before the first `migrate`.
- **`makemigrations`** writes migrations from your models, and **`migrate`** applies them.
- The **admin** at `/admin/` manages your data. `createsuperuser` makes an account that can use it.
- `get_object_or_404` turns "no such row" into a 404, and `rollback_after` keeps test data
  from leaking between tests.

The code at this point is tagged `ch02`.

In chapter 3 members finally get something to do: you'll add posts and the timeline.
