# Chapter 1: A project and a page

In this chapter you create the Juangout project, start the development server, and replace
the starter page with a home page and an about page of your own. By the end you'll know how
a request finds its way to your code and back, and you'll have written your first test.

Juango ideas in this chapter: **projects**, **`manage.jl`**, **URL patterns**, **views**,
**templates** and template inheritance, **static files**, and the **test client**.

## Installing Juango

Juango isn't in Julia's General registry yet, so install it from GitHub. Make a temporary
environment for this one job, so nothing gets added to your global environment:

```julia
julia> using Pkg
julia> Pkg.activate(temp = true)
julia> Pkg.add(url = "https://github.com/mcvmcv/Juango")
julia> using Juango
```

The first `using Juango` takes a few minutes, because Julia precompiles the package. After
that it loads in seconds.

## Creating the project

A Juango **project** is a directory that holds everything for one website: its settings, its
code, its templates, and the Julia environment it runs in. `startproject` makes one:

```julia
julia> cd(expanduser("~/code"))          # wherever you keep your projects
julia> Juango.startproject("Juangout"; develop = false)
Created project 'Juangout' in /home/you/code/Juangout
```

(`develop = false` tells `startproject` not to link the project to a local copy of Juango.
You'll add Juango properly in a moment. The default suits people who work on Juango itself.)

Now leave Julia, go into the new directory, and add Juango to the project's own environment:

```sh
cd Juangout
julia --project -e 'using Pkg; Pkg.add(url = "https://github.com/mcvmcv/Juango", rev = "main")'
```

`--project` means "use the environment in this directory": its `Project.toml` lists the
project's dependencies, and its `Manifest.toml` records their exact versions. Use
`--project` every time you run Julia for Juangout.

> **Commit your `Manifest.toml`.** `startproject` currently lists it in `.gitignore`; take that
> line out. A package leaves its Manifest out of git so that users can resolve their own
> versions, but a website is an application, and you want every machine it runs on to use
> exactly the same versions.

## A tour of the project

```
Juangout/
├── Project.toml     the environment: Juango and Dates
├── manage.jl        run commands: julia --project manage.jl <command>
├── project.jl       loads the project's code, in order
├── settings.jl      configuration
├── urls.jl          which URL goes to which view
├── views.jl         the functions that answer requests
├── models.jl        database tables (a sample Note model)
├── admin.jl         registers models with the admin site
├── templates/       HTML templates
│   ├── base.html
│   └── home.html
└── static/          CSS, images, JavaScript
    └── style.css
```

**`manage.jl`** is how you work with the project from the shell. Try:

```sh
julia --project manage.jl help
```

It lists dozens of commands. You'll use a handful all the time: `runserver`, `test`,
`makemigrations`, `migrate` and `shell`.

**`project.jl`** loads everything. `manage.jl` includes it, and so will your tests:

```julia
using Juango
using Dates

const BASE_DIR = @__DIR__

Juango.project_include(joinpath(BASE_DIR, "models.jl"))
Juango.project_include(joinpath(BASE_DIR, "admin.jl"))
Juango.project_include(joinpath(BASE_DIR, "views.jl"))
Juango.project_include(joinpath(BASE_DIR, "urls.jl"))
Juango.project_include(joinpath(BASE_DIR, "settings.jl"))
Juango.on_reload!(() -> Base.include(@__MODULE__, joinpath(BASE_DIR, "settings.jl")))
```

It's ordinary Julia. `project_include` is `include`, except that Revise also watches the file,
so a running server reloads it when you save it.

**`settings.jl`** calls `configure!` with the project's settings: the database to use, where
templates live, which URL patterns to use (`ROOT_URLCONF = urlpatterns`) and so on. Settings
that change from one machine to another, such as `DEBUG` and `SECRET_KEY`, are read from the
environment, with defaults for development. Chapter 15 comes back to that.

> **If you know Django:** this is `settings.py`, `urls.py` and `views.py` as you know them, with
> `project.jl` doing the importing that Python does implicitly. Settings use Django's names.

## Running the development server

```sh
julia --project manage.jl runserver
```

Open <http://127.0.0.1:8000/>. You should see "The install worked successfully!
Congratulations!" The server keeps running until you press Ctrl-C. If Revise is installed,
leave it running while you edit: changes show up when you reload the page.

The starter page offers a link to the admin. **Don't follow it yet.** The admin needs database
tables that don't exist until you run `migrate`. Juangout will store its members in a custom
user model that you create in chapter 2, and Juango (like Django) strongly recommends setting
that up *before* the first `migrate`. So you won't touch the database in this chapter.

## How a request is answered

When your browser asks for `http://127.0.0.1:8000/about/`, Juango:

1. takes the path, `about/`, and tries each pattern in `urlpatterns` (in `urls.jl`) in turn;
2. calls the **view** of the first pattern that matches, with the request;
3. sends whatever the view returns back to the browser as the response.

A view is just a Julia function that takes a request and returns a response. Most views
return `render(req, template, context)`: it fills in an HTML **template** with values from the
`context` dictionary.

Let's make Juangout's own pages.

## Clearing out the sample

The project came with a sample `Note` model. Juangout's models will live in **apps** (chapter
2), so delete `models.jl` and `admin.jl`, and take their two lines out of `project.jl`:

```julia
# Loads the whole project (settings, views, urls).
using Juango
using Dates

const BASE_DIR = @__DIR__

Juango.project_include(joinpath(BASE_DIR, "views.jl"))
Juango.project_include(joinpath(BASE_DIR, "urls.jl"))
Juango.project_include(joinpath(BASE_DIR, "settings.jl"))
Juango.on_reload!(() -> Base.include(@__MODULE__, joinpath(BASE_DIR, "settings.jl")))
```

## The home page

Replace `views.jl` with:

```julia
# A view takes a request and returns a response.
function home(req)
    render(req, "home.html", Dict("tagline" => "Say what's on your mind. Briefly."))
end
```

and `urls.jl` with:

```julia
const urlpatterns = [
    path("", home; name = "home"),
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
]
```

Each `path` maps a URL to a view. Paths have no leading slash, and `""` is the site's root.
The `name` lets you refer to a URL without spelling it out: `reverse_url("about")` gives
`"/about/"` in Julia code, and `{% url 'about' %}` does the same in a template. Use names
everywhere and you can change a URL later by editing one line.

The about page doesn't need a function of its own. **`TemplateView`** is a ready-made view
that just renders a template. It's the first of Juango's *generic views*, which you'll meet
properly in chapter 3. The admin keeps its place for chapter 2.

> **If you know Django:** `path`, converters such as `<int:id>`, `name=` and `include_urls`
> work as in Django. Views receive URL captures as keyword arguments: `post_detail(req; id)`.

## Templates

Juango's template language is Django's. `{{ tagline }}` inserts a value from the context
(HTML-escaped, so it's safe to show text that members typed). `{% ... %}` tags do
everything else: loops, conditions, links, and **inheritance**.

Every page on the site shares a header and a footer, so put them in one base template.
Replace `templates/base.html` with:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{% block title %}Juangout{% endblock %}</title>
  <link rel="stylesheet" href="{% static 'style.css' %}">
</head>
<body>
  <header class="site-header">
    <a class="logo" href="{% url 'home' %}">Juangout</a>
    <nav>
      <a href="{% url 'home' %}">Home</a>
      <a href="{% url 'about' %}">About</a>
    </nav>
  </header>
  <main>
    {% for message in messages %}<p class="msg {{ message.tags }}">{{ message }}</p>{% endfor %}
    {% block content %}{% endblock %}
  </main>
  <footer class="site-footer">Made with Juango</footer>
</body>
</html>
```

Each `{% block %}` is a hole that a child template can fill. Leave the `messages` loop as it
is: you'll use it in chapter 4. `templates/home.html` **extends** the base and fills in the
`content` block:

```html
{% extends "base.html" %}

{% block content %}
  <section class="hero">
    <h1>Welcome to Juangout</h1>
    <p>{{ tagline }}</p>
  </section>
  <p class="empty">Nothing to read yet. Posts arrive in chapter 3.</p>
{% endblock %}
```

Create `templates/about.html`. It fills the `title` block as well:

```html
{% extends "base.html" %}

{% block title %}About · Juangout{% endblock %}

{% block content %}
  <h1>About</h1>
  <p>Juangout is a small social network built with
     <a href="https://github.com/mcvmcv/Juango">Juango</a>, a Django-style web framework for Julia.
     It's also the app a tutorial builds, one chapter at a time.</p>
{% endblock %}
```

Reload the page in your browser (restart `runserver` if you don't have Revise). Click between
Home and About.

## Static files

CSS, images and JavaScript are **static files**: the server sends them as they are. They live
in `static/` (`STATIC_DIRS` in the settings), and templates link to them with
`{% static 'style.css' %}`, which gives the file's URL. In development, `runserver` serves
them. Chapter 15 covers serving them in production.

Replace `static/style.css` with something a bit more Juangout-like:

```css
:root {
  --ink: #1f2328;
  --muted: #656d76;
  --paper: #fbfaf7;
  --card: #ffffff;
  --line: #e4e1da;
  --accent: #c2410c;
  --accent-soft: #fff1e8;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
  color: var(--ink);
  background: var(--paper);
}

a { color: var(--accent); }

.site-header, main, .site-footer { max-width: 40rem; margin: 0 auto; padding: 0 1rem; }

.site-header {
  display: flex; align-items: baseline; justify-content: space-between;
  padding-top: 1.25rem; padding-bottom: 1rem; border-bottom: 1px solid var(--line);
}
.logo { font-weight: 800; font-size: 1.35rem; letter-spacing: -0.02em; text-decoration: none; color: var(--ink); }
.site-header nav a { margin-left: 1rem; color: var(--muted); text-decoration: none; }
.site-header nav a:hover { color: var(--accent); }

main { padding-top: 1.5rem; padding-bottom: 3rem; }

.hero h1 { font-size: 2rem; letter-spacing: -0.02em; margin: 0 0 .25rem; }
.hero p { color: var(--muted); margin-top: 0; font-size: 1.1rem; }

.empty { color: var(--muted); font-style: italic; }

.msg { padding: .6rem 1rem; border-radius: 6px; background: #eef2ff; }
.msg.success { background: #e7f6ec; }
.msg.error { background: #fdecec; }

.site-footer { color: var(--muted); font-size: .85rem; padding-bottom: 2rem; }
```

## Your first test

Clicking around shows that the pages work today. A test shows they still work after next
week's changes. Juango comes with a **test client** that makes requests to your app
without starting a server.

`manage.jl test` runs every file in `tests/` whose name starts with `test`. Create
`tests/test_pages.jl`:

```julia
using Test
using Juango.Testing

@testset "pages" begin
    c = Client()

    r = get(c, "/")
    @test r.status == 200
    @test assert_template_used(r, "home.html")
    @test assert_contains(r, "Welcome to Juangout")

    r = get(c, reverse_url("about"))
    @test r.status == 200
    @test assert_contains(r, "Django-style web framework")

    @test get(c, "/no-such-page/").status == 404
end
```

`get(c, url)` returns the response. As well as the `status` and the HTML, it records which
templates were used and the context they got (`r.context`). The `assert_*` helpers return
`true`, or throw an error that explains what went wrong, so `@test assert_...` gives readable
failures.

Run it:

```sh
julia --project manage.jl test
```

```
Operations to perform:
  Apply all migrations: admin, auth, contenttypes, sessions
Running migrations:
  Applying contenttypes.0001_initial... OK
  ...
Running tests/test_pages.jl
Test Summary: | Pass  Total
pages         |    6      6
```

The migrations at the top are the test runner preparing a **test database**: a throwaway
in-memory SQLite database, so your tests never touch your real data. You'll start
relying on it in chapter 2.

> **If you know Django:** `Client` is `django.test.Client`, `assert_contains` is
> `assertContains`, and `manage.jl test` makes and destroys a test database as `manage.py test`
> does. Tests use Julia's standard `Test` library: `@testset` and `@test`.

## Summary

- `Juango.startproject` makes a project. `manage.jl` runs its commands, and `project.jl`
  loads its code.
- `urlpatterns` maps URLs to views. A view is a function from a request to a response, and
  `render` fills in a template.
- Templates extend a base template and fill its blocks. `{% url %}` and `{% static %}` build
  links.
- `manage.jl test` runs the tests in `tests/` against a throwaway database, and `Client`
  makes requests to the app without a server.

The code at this point is tagged `ch01`.

In [chapter 2](02-members.md) you'll make Juangout's first app, `accounts`, with a custom user
model for its members, and finally create the database.
