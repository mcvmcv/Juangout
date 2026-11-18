# Chapter 4: Signing up and posting

So far only you, through the admin, can put anything on Juangout. In this chapter visitors
sign up, log in and out, edit their profiles, and write and delete their own posts.

Juango ideas in this chapter: **authentication** (`auth_urls`, `login!`, `req.user`),
**forms** and **ModelForms**, the **GET/POST pattern**, **CSRF protection**, **messages**,
`login_required`, `UpdateView` and `DeleteView`, **view hooks**, and **overriding Juango's
built-in templates**.

## Logging in and out

Juango comes with views for logging in and out and for changing and resetting passwords.
Mount them in the project's `urls.jl`:

```julia
const urlpatterns = [
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("accounts/", Juango.auth_urls()),            # login/, logout/, password_change/, ...
    path("", include_urls(Accounts.APP)),            # /@username/
    path("", include_urls(Posts.APP)),               # the timeline at /, posts at /posts/<id>/
]
```

That adds `/accounts/login/` (named `login`), `/accounts/logout/` (`logout`),
`/accounts/password_change/`, and the password-reset pages, which need email (chapter 9).
`auth_urls` isn't exported, so it's written `Juango.auth_urls`.

The login view renders the template `registration/login.html`. Juango has a plain one of its
own, but it doesn't look like Juangout. You can replace any of Juango's templates by putting
one with the same name in your `templates/` directory, because Juango searches the
project's templates first. Create `templates/registration/login.html`:

```html
{% extends "base.html" %}

{% block title %}Log in · Juangout{% endblock %}

{% block content %}
  <h1>Log in</h1>
  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <input type="hidden" name="next" value="{{ next }}">
    <button type="submit">Log in</button>
  </form>
  <p class="aside">New here? <a href="{% url 'accounts:signup' %}">Sign up</a>.</p>
{% endblock %}
```

Three new things are in this small template:

- **`{{ form.as_div }}`** renders a form's fields, each with its label, help text and any
  errors, in a `<div>`. The login view puts a `form` in the context.
- **`{% csrf_token %}`** adds a hidden field with a secret token. Every form that POSTs must
  have one. See the CSRF section below.
- **`next`**: when a page that needs a logged-in member sends a visitor to log in, it adds
  `?next=/the/page/` to the URL, so they can be sent back there afterwards.

Now update the navigation in `templates/base.html` so it depends on who's looking:

```html
    <nav>
      <a href="{% url 'posts:timeline' %}">Home</a>
      <a href="{% url 'about' %}">About</a>
      {% if user.is_authenticated %}
        <a href="{{ user.get_absolute_url }}">@{{ user.username }}</a>
        <a href="{% url 'accounts:profile_edit' %}">Edit profile</a>
        <form method="post" action="{% url 'logout' %}" class="inline">
          {% csrf_token %}<button type="submit" class="link">Log out</button>
        </form>
      {% else %}
        <a href="{% url 'login' %}">Log in</a>
        <a href="{% url 'accounts:signup' %}">Sign up</a>
      {% endif %}
    </nav>
```

Every template can use **`user`**: the logged-in `Member`, or an "anonymous user" whose
`is_authenticated` is false. In Julia code it's `req.user`.

Logging out is a small form with a button, not a link. A link is a GET request, and anything
can follow a link: a browser prefetching pages, or an `<img>` tag on someone else's site. GET
requests should never change anything, so Juango's logout view refuses them.

> **If you know Django:** `auth_urls()` is `include("django.contrib.auth.urls")`, with the
> same URL names and template names. Since Django 5 logout must be a POST there too.

## Signing up

Juango has no sign-up view, because every site wants a different one. It does have the
form: **`UserCreationForm`** asks for a username and a password twice, checks that the two
match and that the password is strong enough, and saves the new member with the password
hashed.

Add a view to `accounts/views.jl`:

```julia
# The sign-up page: a form on GET, and on a valid POST a new member, logged in.
function signup(req)
    is_authenticated(req.user) && return redirect("posts:timeline")
    form = UserCreationForm(req.method == "POST" ? req.POST : nothing; fields = [:username, :email])
    if req.method == "POST" && is_valid(form)
        member = save!(form)
        login!(req, member)
        message!(req, :success, "Welcome to Juangout, $(member.username)! Tell people a bit about yourself.")
        return redirect("accounts:profile_edit")
    end
    render(req, "accounts/signup.html", Dict("form" => form))
end
```

This is the pattern behind almost every form on the web, so it's worth reading slowly:

1. **GET** (someone opens the page): `req.method` is `"GET"`, so the form is created with
   `nothing`. It's an *unbound* form, with no data and no errors. The view renders it.
2. **POST** (they submit it): the form is *bound* to `req.POST`, the submitted data, and
   **`is_valid`** checks it. Each field converts and validates its value, and the cleaned
   values go into `form.cleaned_data`.
3. **Valid:** `save!(form)` creates the member, `login!` logs them in, and the view
   **redirects**. Redirecting after a successful POST means that reloading the next page
   doesn't submit the form again.
4. **Invalid:** the view falls through to `render` with the same form, which now carries the
   submitted values and an error message by each field that failed.

`fields = [:username, :email]` asks for the email address as well as the username.
`redirect("accounts:profile_edit")` takes a URL name, like `{% url %}`.

**Messages** are one-off notices that survive a redirect. `message!(req, :success, "...")`
stores one, and the `{% for message in messages %}` loop that's been in `base.html` since
chapter 1 shows it on the next page, then forgets it.

The URL goes in `accounts/urls.jl`:

```julia
    path("accounts/signup/", signup; name = "signup"),
```

and the template, `accounts/templates/accounts/signup.html`, looks much like the login page:

```html
{% extends "base.html" %}

{% block title %}Sign up · Juangout{% endblock %}

{% block content %}
  <h1>Join Juangout</h1>
  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <button type="submit">Sign up</button>
  </form>
  <p class="aside">Already a member? <a href="{% url 'login' %}">Log in</a>.</p>
{% endblock %}
```

Try it. Submit the form with two different passwords, or with a username that's taken, and
see the errors.

## CSRF

Imagine that while you're logged in to Juangout, you visit an evil site. It contains a hidden
form that POSTs "I love spam" to `https://juangout.example/posts/new/` and submits itself.
Your browser sends your Juangout cookies with that request, so as far as Juangout can tell,
you wrote the post. This is **cross-site request forgery**.

The defence is the token that `{% csrf_token %}` puts in each form. The evil site can't read
it, because browsers don't let one site read another's pages. Juango refuses every POST that
doesn't carry a valid token, with a 403 Forbidden. It's on by default: all you have to do is
put `{% csrf_token %}` in every `<form method="post">`.

## Editing your profile

Editing one existing object is another common job, and **`UpdateView`** does it. In
`accounts/views.jl`:

```julia
# Editing your own profile. UpdateView shows a form for one object and saves it; the
# get_object hook makes that object the logged-in member, whatever the URL.
const profile_edit = UpdateView(Member;
    fields = [:display_name, :bio, :email],
    template = "accounts/profile_edit.html",
    login_required = true,
    get_object = v -> v.request.user,
    success_message = "Your profile was saved.")
```

`UpdateView` builds a form for the model's `fields`, filled in with the object's current
values, and saves it on a valid POST. It then redirects to the object's
`get_absolute_url`, which is the profile page. It runs the same GET/POST pattern as `signup`,
just pre-packaged.

Normally an `UpdateView` finds its object from the URL, like `DetailView`. Here there's no id
in the URL, because you can only ever edit your own profile. So the **`get_object` hook**
replaces that step. Generic views are made of steps like this one (`get_queryset`,
`get_object`, `get_context_data`, `form_valid`, `get_success_url`, ...), and you can replace
any of them with a function that takes the view call `v`. `v.request` is the request.

**`login_required = true`** sends visitors who aren't logged in to the login page, with a
`next` that brings them back.

`accounts/urls.jl` now reads:

```julia
const urlpatterns = [
    path("@<str:username>/", profile; name = "profile"),     # {% url 'accounts:profile' username %}
    path("accounts/signup/", signup; name = "signup"),
    path("accounts/profile/", profile_edit; name = "profile_edit"),
]
```

and the template, `accounts/templates/accounts/profile_edit.html`, is:

```html
{% extends "base.html" %}

{% block title %}Edit your profile · Juangout{% endblock %}

{% block content %}
  <h1>Edit your profile</h1>
  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <button type="submit">Save</button>
  </form>
  <p class="aside"><a href="{{ user.get_absolute_url }}">View your profile</a> ·
     <a href="{% url 'password_change' %}">Change your password</a></p>
{% endblock %}
```

Notice that you didn't write any validation. The form fields come from the model fields, so
the 300-character limit on `bio` and the email format check come along with them.

### Juango's password pages

The "Change your password" link goes to one of Juango's built-in pages. It works, but it
has its own plain styling. Override its two templates as you did for login.
`templates/registration/password_change_form.html`:

```html
{% extends "base.html" %}

{% block title %}Change your password · Juangout{% endblock %}

{% block content %}
  <h1>Change your password</h1>
  <form method="post" class="form">
    {% csrf_token %}
    {{ form.as_div }}
    <button type="submit">Change my password</button>
  </form>
{% endblock %}
```

and `templates/registration/password_change_done.html`:

```html
{% extends "base.html" %}

{% block title %}Password changed · Juangout{% endblock %}

{% block content %}
  <h1>Password changed</h1>
  <p>Your new password is set. <a href="{% url 'posts:timeline' %}">Back to the timeline</a>.</p>
{% endblock %}
```

## Writing posts

Now for the main event. Posts get a **ModelForm** of their own, used in two places, so
give it a function in `posts/views.jl`:

```julia
# The form for writing a post: a ModelForm builds its fields from the model's.
post_form(data = nothing; instance = nothing) =
    ModelForm(Post; data, instance, fields = [:body], labels = Dict(:body => "What's on your mind?"))
```

`ModelForm(Post; fields = [:body])` makes a form with one field, built from `Post.body`. A
`TextField` becomes a `<textarea>`, and it's required with a 280-character limit, because the
model says so. `labels` replaces the default label, "Body".

The view that saves a post uses the same GET/POST pattern as `signup`:

```julia
# Writing a post, the long way: GET shows the form, a valid POST saves it and redirects,
# an invalid POST shows the form again with its errors.
function post_create(req)
    form = post_form(req.method == "POST" ? req.POST : nothing; instance = Post(; author = req.user))
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, "Posted.")
        return redirect("posts:timeline")
    end
    render(req, "posts/compose.html", Dict("form" => form))
end
```

The form only has a `body` field, but a post also needs an author, and it must be the
person writing it, not something they could type into a form. So the view starts the form
off with an unsaved `Post` whose author is already set, `instance = Post(; author =
req.user)`. `save!(form)` fills in the body and saves that instance.

The URL wraps the view in **`login_required`**, the function version of `login_required =
true`:

```julia
    path("posts/new/", login_required(post_create); name = "create"),
```

The form appears at the top of the timeline. Pass it to the template with a
`get_context_data` hook, which adds values to what the `ListView` passes:

```julia
const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx))
```

The form's HTML goes in `posts/templates/posts/_compose_form.html`, because two templates use
it. The `action` sends it to `post_create`, whichever page it's on:

```html
<form method="post" action="{% url 'posts:create' %}" class="form compose">
  {% csrf_token %}
  {{ form.as_div }}
  <button type="submit">Post</button>
</form>
```

On the timeline it replaces the welcome for members who are logged in. In
`posts/templates/posts/timeline.html`:

```html
  {% if page_obj.number == 1 %}
    {% if user.is_authenticated %}
      {% include "posts/_compose_form.html" %}
    {% else %}
      <section class="hero">
        <h1>Welcome to Juangout</h1>
        <p>Say what's on your mind. Briefly. <a href="{% url 'accounts:signup' %}">Sign up</a> or <a href="{% url 'login' %}">log in</a>.</p>
      </section>
    {% endif %}
  {% endif %}
```

`post_create` renders `posts/compose.html` itself on a GET, or when the post is invalid:

```html
{% extends "base.html" %}

{% block title %}New post · Juangout{% endblock %}

{% block content %}
  <h1>New post</h1>
  {% include "posts/_compose_form.html" %}
{% endblock %}
```

## Deleting posts

**`DeleteView`** asks "are you sure?" on GET, and deletes on POST. Members may delete only
their own posts. In `posts/views.jl`:

```julia
# Members may delete only their own posts: the queryset leaves everyone else's out, so
# another member's post is a 404, the same as one that doesn't exist.
const post_delete = DeleteView(Post;
    template = "posts/confirm_delete.html",
    login_required = true,
    get_queryset = v -> filter(Post; author = v.request.user),
    get_success_url = v -> reverse_url("posts:timeline"),
    success_message = "Your post was deleted.")
```

The `get_queryset` hook is the access control. The view looks up the post's id only among
your own posts, so someone else's post is "not found". That's simpler and safer than fetching
the post and then checking its author, because there's no check to forget. After deleting,
`get_success_url` sends you to the timeline, since the post's own page no longer exists.

The URL goes in `posts/urls.jl`:

```julia
const urlpatterns = [
    path("", timeline; name = "timeline"),
    path("posts/new/", login_required(post_create); name = "create"),
    path("posts/<int:id>/", post_detail; name = "detail"),
    path("posts/<int:id>/delete/", post_delete; name = "delete"),
]
```

The confirmation page is `posts/templates/posts/confirm_delete.html`:

```html
{% extends "base.html" %}

{% block title %}Delete post · Juangout{% endblock %}

{% block content %}
  <h1>Delete this post?</h1>
  {% include "posts/_post.html" %}
  <form method="post" class="form">
    {% csrf_token %}
    <button type="submit" class="danger">Delete it</button>
    <a href="{{ post.get_absolute_url }}">Keep it</a>
  </form>
{% endblock %}
```

And `_post.html` shows a delete link on your own posts. Add this to its `<header>`:

```html
    {% if post.author_id == user.id %}· <a class="delete" href="{% url 'posts:delete' post.id %}">delete</a>{% endif %}
```

`post.author_id` is the foreign key's column: the author's id, available without fetching
the author.

## Styling forms

Add the form styles to `static/style.css`:

```css
/* forms */
.form { margin: 1rem 0 1.5rem; }
.form > div { margin-bottom: .9rem; }
.form label { display: block; font-weight: 600; margin-bottom: .25rem; }
.form input[type=text], .form input[type=email], .form input[type=password], .form textarea {
  width: 100%; padding: .55rem .7rem; font: inherit; color: inherit;
  background: var(--card); border: 1px solid var(--line); border-radius: 8px;
}
.form textarea { min-height: 6rem; resize: vertical; }
.form input:focus, .form textarea:focus { outline: 2px solid var(--accent); outline-offset: 1px; border-color: transparent; }
.form .helptext, .form [id$=_helptext] { display: block; color: var(--muted); font-size: .85rem; margin-top: .2rem; }
.errorlist { color: #b42318; margin: .25rem 0; padding: 0; list-style: none; font-size: .9rem; }
.compose textarea { min-height: 4.5rem; }

button {
  font: inherit; font-weight: 600; padding: .5rem 1.1rem; border: 0; border-radius: 999px;
  background: var(--accent); color: #fff; cursor: pointer;
}
button:hover { filter: brightness(1.08); }
button.danger { background: #b42318; }
button.link { background: none; color: var(--muted); padding: 0; font-weight: 400; border-radius: 0; }
button.link:hover { color: var(--accent); filter: none; }
form.inline { display: inline; margin-left: 1rem; }
.aside { color: var(--muted); }
.post .delete { color: var(--muted); }
```

Juangout is now a working, if small, social network. Sign up a second member in a private
browser window, and post from both.

## Tests

Forms are where most bugs hide, so this chapter adds a lot of tests. The test client posts
form data with `post(c, url, Dict(...))`, and `r.context["form"]` is the form the view
rendered, so you can check its `errors` directly. In `accounts/tests.jl`:

```julia
@testset "signing up" begin
    rollback_after() do
        c = Client()
        @test get(c, "/accounts/signup/").status == 200

        # passwords that don't match: the form comes back with an error, and nobody is created
        r = post(c, "/accounts/signup/", Dict("username" => "cat", "email" => "cat@example.com",
                                              "password1" => "purring-loudly-42", "password2" => "something-else"))
        @test r.status == 200
        @test !is_valid(r.context["form"])
        @test haskey(r.context["form"].errors, :password2)
        @test count(filter(Member; username = "cat")) == 0

        # a good sign-up creates the member, logs them in and sends them to edit their profile
        r = post(c, "/accounts/signup/", Dict("username" => "cat", "email" => "cat@example.com",
                                              "password1" => "purring-loudly-42", "password2" => "purring-loudly-42"))
        @test assert_redirects(r, "/accounts/profile/")
        cat = get(Member; username = "cat")
        @test cat.email == "cat@example.com"
        @test check_password(cat, "purring-loudly-42")            # stored hashed
        @test cat.password != "purring-loudly-42"
        r = get(c, "/accounts/profile/")
        @test r.status == 200                                     # logged in
        @test assert_contains(r, "Welcome to Juangout, cat!")     # the message

        # the username must be unique
        r = post(Client(), "/accounts/signup/", Dict("username" => "cat", "password1" => "purring-loudly-42",
                                                     "password2" => "purring-loudly-42"))
        @test haskey(r.context["form"].errors, :username)
    end
end

@testset "logging in and out" begin
    rollback_after() do
        create_user("ann"; password = "correct-horse-battery")
        c = Client()
        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "wrong"))
        @test r.status == 200
        @test !isempty(r.context["form"].errors)

        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "correct-horse-battery"))
        @test assert_redirects(r, "/")
        @test assert_contains(get(c, "/"), "Log out")

        # logging out is a POST (a link could be followed by anything, even a prefetcher)
        @test get(c, "/accounts/logout/").status == 405
        r = post(c, "/accounts/logout/")
        @test assert_redirects(r, "/")
        @test assert_contains(get(c, "/"), "Log in")
    end
end

@testset "editing your profile" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        @test assert_redirects(get(c, "/accounts/profile/"), "/accounts/login/?next=%2Faccounts%2Fprofile%2F")
        force_login!(c, ann)
        r = post(c, "/accounts/profile/", Dict("display_name" => "Ann Lee", "bio" => "Hi there", "email" => "ann@example.com"))
        @test assert_redirects(r, "/@ann/")
        refresh!(ann)
        @test ann.display_name == "Ann Lee"
        @test ann.bio == "Hi there"

        r = post(c, "/accounts/profile/", Dict("display_name" => "", "bio" => "x"^301, "email" => "ann@example.com"))
        @test haskey(r.context["form"].errors, :bio)
    end
end

@testset "CSRF protection" begin
    rollback_after() do
        create_user("ann"; password = "correct-horse-battery")
        c = Client(enforce_csrf = true)
        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "correct-horse-battery"))
        @test r.status == 403
    end
end

@testset "changing your password" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = get(c, "/accounts/password_change/")
        @test assert_template_used(r, "registration/password_change_form.html")
        @test assert_contains(r, "Edit profile")                    # our template, inside base.html
        r = post(c, "/accounts/password_change/", Dict("old_password" => "correct-horse-battery",
                     "new_password1" => "staple-battery-horse", "new_password2" => "staple-battery-horse"); follow = true)
        @test assert_contains(r, "Your new password is set")
        @test check_password(refresh!(ann), "staple-battery-horse")
    end
end
```

Some details:

- **`assert_redirects(r, url)`** checks that the response is a redirect to exactly that URL.
  Note how `login_required` encodes the `next` parameter.
- **`refresh!(ann)`** reloads an instance from the database. `ann` is a Julia value, and the
  view changed the row, not your copy.
- **`follow = true`** makes the client follow redirects, so `r` is the final page. That's
  handy for checking messages.
- The test client normally skips CSRF checks, since tests don't fill in tokens. `Client(enforce_csrf
  = true)` turns them on, which proves the protection is there.

And in `posts/tests.jl`:

```julia
@testset "writing posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()

        # visitors are sent to log in
        r = post(c, "/posts/new/", Dict("body" => "Sneaky"))
        @test assert_redirects(r, "/accounts/login/?next=%2Fposts%2Fnew%2F")
        @test count(objects(Post)) == 0

        force_login!(c, ann)
        @test assert_contains(get(c, "/"), "What&#x27;s on your mind?")    # the compose box

        r = post(c, "/posts/new/", Dict("body" => "My first real post"); follow = true)
        @test r.status == 200
        @test assert_contains(r, "Posted.")
        p = only(objects(Post))
        @test p.author == ann
        @test p.body == "My first real post"

        # empty and too-long posts are refused, with the form shown again
        for body in ("", "x"^281)
            r = post(c, "/posts/new/", Dict("body" => body))
            @test r.status == 200
            @test haskey(r.context["form"].errors, :body)
        end
        @test count(objects(Post)) == 1
    end
end

@testset "deleting posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        mine = create(Post; author = ann, body = "Delete me")
        theirs = create(Post; author = bob, body = "Not yours")
        c = Client()
        force_login!(c, ann)

        @test assert_contains(get(c, "/"), "/posts/$(mine.id)/delete/")
        @test assert_not_contains(get(c, "/"), "/posts/$(theirs.id)/delete/")

        @test get(c, "/posts/$(theirs.id)/delete/").status == 404
        @test post(c, "/posts/$(theirs.id)/delete/").status == 404
        @test count(filter(Post; id = theirs.id)) == 1

        @test get(c, "/posts/$(mine.id)/delete/").status == 200        # the confirmation page
        r = post(c, "/posts/$(mine.id)/delete/")
        @test assert_redirects(r, "/")
        @test count(filter(Post; id = mine.id)) == 0
    end
end
```

The apostrophe in "What's on your mind?" is `&#x27;` in the page, because templates escape
everything they insert. That's what keeps a member from posting `<script>` tags.

> **If you know Django:** `assert_redirects` doesn't fetch the target page unless you pass
> `client = c`, so there's no `fetch_redirect_response`. `r.context["form"].errors` is a `Dict`
> from field name (a `Symbol`) to messages. Prefer testing `errors` and `cleaned_data` over the
> rendered HTML.

## Summary

- **`Juango.auth_urls()`** provides login, logout and password pages. Replace their templates
  by creating `templates/registration/*.html`.
- **`req.user`** (`user` in templates) is the logged-in member. `login_required` (or
  `login_required = true` on a generic view) keeps visitors out.
- **Forms** validate submitted data. `is_valid(form)` checks it, and `form.cleaned_data` and
  `form.errors` hold the results. **ModelForms** build their fields from a model.
- The **GET/POST pattern**: show the form, validate the submission, save and **redirect**, or
  show it again with errors.
- **`{% csrf_token %}`** in every POST form. **`message!`** for notices that survive a redirect.
- `UpdateView` and `DeleteView` handle editing and deleting. **Hooks** such as `get_object` and
  `get_queryset` customise them. Restricting the queryset is a simple, safe form of access
  control.

The code at this point is tagged `ch04`.

In chapter 5 members start following each other and liking posts, and the timeline becomes
personal.
