# Building Juangout: a Juango tutorial

In this tutorial you build **Juangout**, a small social network, with
[Juango](https://github.com/mcvmcv/Juango), a "batteries included" web framework for Julia.
Members sign up, write short posts, follow each other, like and reply. Later chapters add
pictures, live updates, notifications, search, moderation, an API, and a deployment.

Each chapter adds one feature to the app and, along the way, introduces the parts of
Juango that the feature needs.

## Who this is for

You should be comfortable with Julia: functions, structs, keyword arguments, modules, and the
package manager. You don't need to know any web framework. Some HTML and CSS helps.

Juango is modelled closely on Django, Python's best-known web framework, and most names and
ideas are the same. If you've used Django, look out for boxes like this one:

> **If you know Django:** these notes say where Juango matches what you know and where
> it differs. Everyone else can skip them.

## What you need

- Julia 1.12 or later ([juliaup](https://github.com/JuliaLang/juliaup) is the easiest way to get it)
- git
- a terminal and a text editor
- optional but recommended: [Revise.jl](https://github.com/timholy/Revise.jl) in your global
  environment, so the development server picks up code changes without restarting:

  ```sh
  julia -e 'using Pkg; Pkg.add("Revise")'
  ```

## Following along

The finished code for every chapter is in this repository, tagged `ch01`, `ch02` and so on.
If you get stuck, or want to start from a later chapter, check out the matching tag:

```sh
git clone https://github.com/mcvmcv/Juangout
cd Juangout
git checkout ch03            # the code as it is at the end of chapter 3
julia --project -e 'using Pkg; Pkg.instantiate()'
```

Commands you type in a shell look like this:

```sh
julia --project manage.jl runserver
```

and code you type at the Julia prompt looks like this:

```julia
julia> 1 + 1
2
```

## Chapters

1. [A project and a page](01-a-project-and-a-page.md): projects, URLs, views, templates, static files and your first test
2. [Members](02-members.md): apps, a custom user model, migrations and the admin
3. [Posts and the timeline](03-posts-and-the-timeline.md): models, the ORM, list views and pagination
4. [Signing up and posting](04-signing-up-and-posting.md): authentication, forms, CSRF and messages
5. [Follows and likes](05-follows-and-likes.md): many-to-many relations, annotations and aggregation
6. [Replies and threads](06-replies-and-threads.md): self-referencing relations and query performance
7. [Pictures](07-pictures.md): file uploads
8. [htmx](08-htmx.md): interactive pages without writing JavaScript
9. [Notifications](09-notifications.md): signals, email and background tasks
10. [Live updates](10-live-updates.md): a timeline that updates itself
11. [Search](11-search.md): filtering and full-text search
12. Moderation: permissions and groups
13. Polish: caching, humanize, time zones and translations
14. API and feeds: a JSON API and RSS/Atom feeds
15. Deployment
