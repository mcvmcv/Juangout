# Juangout

A small social network built with [Juango](https://github.com/mcvmcv/Juango), a Django-style web
framework for Julia, and **the tutorial that builds it**, one chapter at a time.

Members sign up, write short posts (with pictures and #hashtags), follow each other, like and reply;
they get notifications and email, a live timeline, search, a trending page, moderation, a JSON API, RSS
feeds, and German as well as English.

## The tutorial

**[Start here: tutorial/README.md](tutorial/README.md)**. It's written for people who know Julia but
not Django, with notes along the way for those who do. Each chapter's finished code is tagged
(`ch01` … `ch15`), so you can check out any step.

1. A project and a page · 2. Members · 3. Posts and the timeline · 4. Signing up and posting ·
5. Follows and likes · 6. Replies and threads · 7. Pictures · 8. htmx · 9. Notifications ·
10. Live updates · 11. Search · 12. Moderation · 13. Polish · 14. API and feeds · 15. Deployment

## Running it

You need Julia 1.12 or later.

```sh
git clone https://github.com/mcvmcv/Juangout
cd Juangout
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project manage.jl migrate
julia --project manage.jl seed            # demo members and posts (password: juangout-demo)
julia --project manage.jl runserver       # http://127.0.0.1:8000/
```

The first run precompiles Juango, which takes a few minutes. Tests:

```sh
julia --project manage.jl test
DATABASE_URL=postgresql://user@127.0.0.1:5432/juangout julia --project manage.jl test    # on PostgreSQL
```

For production settings, see `.env.example`, `deploy/` and [chapter 15](tutorial/15-deployment.md).

## Layout

```
project.jl  settings.jl  urls.jl  manage.jl      the project
accounts/        members, profiles, follows, time zones
posts/           posts, likes, replies, tags, timelines, live view, search, trending
notifications/   notifications, email tasks
moderation/      reports, the moderation queue
api/             the JSON API, API tokens, feeds
templates/  static/  locale/                     project-wide templates, CSS, translations
tests/           runs each app's tests.jl
tutorial/        the tutorial
tools/           headless-browser checks of the htmx and live-view behaviour
```

## Juango issues

Building Juangout is also a test of Juango. Problems found along the way are reported on Juango's
tracker with the label
[`found-by-juangout`](https://github.com/mcvmcv/Juango/issues?q=label%3Afound-by-juangout), and the places
where Juangout works around one are tracked here with the label
[`workaround`](https://github.com/mcvmcv/Juangout/issues?q=label%3Aworkaround).
