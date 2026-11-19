# Chapter 7: Pictures

Juangout is all text so far. In this chapter members get **avatars**, and posts can carry a
**picture**, with a description for people who can't see it. You'll handle file uploads,
validate them, and write a validation rule that spans two fields.

Juango ideas in this chapter: **`ImageField`**, `MEDIA_ROOT` and `MEDIA_URL`, **multipart
forms** and `req.FILES`, file **validators**, `width_field`/`height_field`, a model's own
**`Juango.clean`**, and **uploads in tests**.

## Where uploaded files go

Uploaded files aren't static files. Static files are part of your code, while uploads are
data that members add while the site runs. Juango keeps them apart with two settings:

- **`MEDIA_ROOT`**, the directory uploads are saved in. `startproject` set it to
  `joinpath(BASE_DIR, "media")`.
- **`MEDIA_URL`**, the URL they're served from, `/media/` by default.

With `DEBUG` on, the development server serves `MEDIA_URL` for you. In production your web
server does it (chapter 15). Uploads are data, not code, so keep them out of git. Add a line to
`.gitignore`:

```
media/
```

## Avatars

Add an `ImageField` to `Member` in `accounts/models.jl`, after `bio`:

```julia
    avatar = ImageField(upload_to = "avatars/", blank = true,
                        validators = [MaxFileSizeValidator(2_000_000)], help_text = "A square picture works best. At most 2 MB.")
```

- **`ImageField`** stores an uploaded image. The database column holds only the file's *name*
  (`avatars/ann.png`). The file itself goes into `MEDIA_ROOT/avatars/`. Juango checks that the
  upload really is a PNG, GIF, JPEG or WebP by reading its contents, not by trusting the file
  name. It cleans up the file name, and never overwrites an existing file.
- **`validators`** are checks a field runs on its value. **`MaxFileSizeValidator`** refuses files
  over 2 MB, so nobody fills your disk with 100 MB "avatars".

In Julia and in templates, `member.avatar` is a file object: `member.avatar.url` is its URL, and
it's empty when there's no file, so `{% if member.avatar %}` works.

Members without an avatar get a placeholder: a circle with their initial. Add a computed
attribute after `get_absolute_url`:

```julia
# For members without an avatar: the first letter of their name, for a placeholder circle
Juango.tattr(m::Member, ::Val{:initial}) = uppercase(first(m.name, 1))
```

Avatars appear next to every post and on profiles, so give them a template of their own,
`accounts/templates/accounts/_avatar.html`:

```html
{# A member's avatar, or a circle with their initial. `member` and `size` (pixels) are given. #}
{% if member.avatar %}
  <img class="avatar" src="{{ member.avatar.url }}" alt="" width="{{ size }}" height="{{ size }}" loading="lazy">
{% else %}
  <span class="avatar avatar-initial" style="width: {{ size }}px; height: {{ size }}px; font-size: calc({{ size }}px * .45)" aria-hidden="true">{{ member.initial }}</span>
{% endif %}
```

`alt=""` marks the avatar as decorative: the member's name is right next to it, so a screen
reader saying "Ann Lee, image, Ann Lee" would only add noise. `loading="lazy"` lets the
browser wait to fetch images until they're about to scroll into view.

Use it in `_post.html`, as the first thing in the `<header>`:

```html
    <a class="avatar-link" href="{{ post.author.get_absolute_url }}">{% include "accounts/_avatar.html" with member=post.author size=36 %}</a>
```

and at the top of the profile's `<section class="profile">`:

```html
    {% include "accounts/_avatar.html" with size=96 %}
```

(The profile template already has a `member`, so only `size` needs passing.)

### Uploading: multipart forms

Add `:avatar` to the profile form's fields:

```julia
const profile_edit = UpdateView(Member;
    fields = [:display_name, :bio, :avatar, :email],
    ...
```

A browser only sends files when the form says so. Change the `<form>` tag in
`profile_edit.html`:

```html
  <form method="post" class="form" enctype="multipart/form-data">
```

Without `enctype="multipart/form-data"` the browser sends just the file's *name*, and the
upload silently doesn't happen. It's the most common file-upload bug there is. With it,
uploaded files arrive in **`req.FILES`**, separately from `req.POST`. Generic views like
`UpdateView` pass both to their form, so nothing else needs to change. Optional file fields
render with the current file and a "Clear" checkbox.

## Pictures in posts

Posts get an image too, plus two things that make images behave well. In `posts/models.jl`:

```julia
@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    # an optional picture, with its size recorded so pages can leave room for it while it loads
    image = ImageField(upload_to = "posts/%Y/%m/", blank = true, validators = [MaxFileSizeValidator(5_000_000)],
                       width_field = :image_width, height_field = :image_height)
    image_width = IntegerField(null = true, editable = false)
    image_height = IntegerField(null = true, editable = false)
    image_alt = CharField(max_length = 300, blank = true, verbose_name = "Image description",
                          help_text = "Describe the picture for people who can't see it.")
    created = DateTimeField(auto_now_add = true)
    ...
```

- **`upload_to = "posts/%Y/%m/"`** sorts uploads into a directory per month
  (`posts/2026/11/`), so no single directory grows to millions of files.
- **`width_field`** and **`height_field`** name two fields that Juango fills in with the image's
  size whenever one is saved. Putting `width` and `height` on the `<img>` tag lets the browser
  reserve the right space before the image arrives, so the page doesn't jump around as it
  loads. `editable = false` keeps them out of forms.
- **`image_alt`** is the image's description for screen readers, and for anyone whose image
  doesn't load. `verbose_name` is the field's label in forms and the admin.

Make the migrations:

```sh
julia --project manage.jl makemigrations --name post_images
```

```
  Note: existing rows get "" for the new NOT NULL column post.image.
  Note: existing rows get "" for the new NOT NULL column post.image_alt.
  Warning (migrations.W001), operation 1: Adding NOT NULL column post.image without a database default: inserts by the code still running fail.
    ...
Migrations for 'posts':
  posts/migrations/0004_post_images.jl
    - Add field image to post
    ...
```

(`--name` gives the migration a readable name. Without it you'd get one with a timestamp.)

The **notes** say what existing posts get in the new columns: an empty string, meaning "no
image". The **warnings** come from Juango's migration safety checks, and they're about
deploying without downtime. On a live site, the old version of your code keeps running for a
moment after the migration adds a column it doesn't know about, and its inserts would fail.
Juangout isn't deployed yet, so you can ignore them for now. Chapter 15 comes back to this.
Run `migrate`, and the `accounts` migration too if you haven't.

### The form and the view

The post form gets the two new editable fields, and a `files` argument:

```julia
post_form(data = nothing; files = nothing, instance = nothing, label = "What's on your mind?") =
    ModelForm(Post; data, files, instance, fields = [:body, :image, :image_alt], labels = Dict(:body => label))
```

`post_create` passes `req.FILES` along when the form is submitted:

```julia
function post_create(req; id = nothing)
    parent = id === nothing ? nothing : get_object_or_404(Post; id)
    posting = req.method == "POST"
    form = post_form(posting ? req.POST : nothing; files = posting ? req.FILES : nothing,
                     instance = Post(; author = req.user, reply_to = parent),
                     label = parent === nothing ? "What's on your mind?" : "Your reply")
    if posting && is_valid(form)
        ...
```

And `_compose_form.html`'s `<form>` tag gets `enctype="multipart/form-data"` too.

The picture goes after the body in `_post.html`:

```html
  {% if post.image %}
    <a href="{{ post.image.url }}" class="post-image">
      <img src="{{ post.image.url }}" alt="{{ post.image_alt }}"
           width="{{ post.image_width }}" height="{{ post.image_height }}" loading="lazy">
    </a>
  {% endif %}
```

## A rule across two fields: `Juango.clean`

A picture without a description leaves some members out, so Juangout should insist on one.
That rule involves *two* fields. `image_alt` is only required when `image` is set, so no
single field's validators can express it.

Rules like this belong to the model, in a method of **`Juango.clean`**. Add it to
`posts/models.jl`:

```julia
# Whether the post has a picture. The field holds a stored file, an upload that's being
# saved, or (on a new post) nothing: Juango #250, after which `!isempty(p.image)` will do.
function has_image(p::Post)
    p.image isa UploadedFile && return true
    p.image !== nothing && !isempty(p.image)
end

# A rule across fields: a picture needs a description. full_clean, ModelForms and the admin
# all run it.
function Juango.clean(p::Post)
    if has_image(p) && isempty(strip(p.image_alt))
        throw(ValidationError(Dict(:image_alt => ["Please describe the picture."])))
    end
end
```

`clean` throws a **`ValidationError`** naming the field the message belongs to, and the form shows
it next to that field. Because it's on the model, *every* way of editing a post enforces the
rule: your compose form, the admin, and `full_clean` in your own code.

`has_image` is only needed because of a rough edge in the current version of Juango. Until it's
fixed ([#250](https://github.com/mcvmcv/Juango/issues/250)), the image field can hold three
different kinds of value, depending on whether the post is new, being saved, or stored.

> **If you know Django:** `Juango.clean(obj)` is `Model.clean()`, and `ValidationError(Dict(...))`
> is `ValidationError({...})`. `ImageField`, `upload_to`, `width_field`/`height_field` and
> `request.FILES` are the same. Juango reads image sizes itself, so there's no Pillow to install.

## Styling

```css
/* pictures */
.avatar { border-radius: 50%; object-fit: cover; vertical-align: middle; background: var(--line); }
.avatar-initial {
  display: inline-flex; align-items: center; justify-content: center;
  background: var(--accent-soft); color: var(--accent); font-weight: 700;
}
.post header { position: relative; padding-left: 46px; min-height: 36px; }
.post .avatar-link { position: absolute; left: 0; top: 0; }
.post .body, .post footer, .post .post-image { margin-left: 46px; }
.post-image { display: block; margin-top: .6rem; }
.post-image img { max-width: 100%; height: auto; border-radius: 8px; border: 1px solid var(--line); }
.profile .avatar { margin-bottom: .5rem; }
.form input[type=file] { font: inherit; }
```

`max-width: 100%; height: auto` lets big pictures shrink to fit, while the `width` and `height`
attributes still give the browser the right proportions to reserve.

## Tests

The test client uploads a file when the data includes an **`UploadedFile`**: a name and some
bytes. `manage.jl test` saves uploads in a temporary `MEDIA_ROOT`, so tests never litter your
real one. Tests need a real image, and a 1×1 PNG is small enough to write out in hex. In
`posts/tests.jl`:

```julia
# a real 1×1 PNG, small enough to write out by hand
const TINY_PNG = hex2bytes("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082")

@testset "pictures in posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)

        # a picture without a description is refused by the model's clean rule
        r = post(c, "/posts/new/", Dict("body" => "Look!", "image" => UploadedFile("dot.png", TINY_PNG)))
        @test r.status == 200
        @test r.context["form"].errors[:image_alt] == ["Please describe the picture."]

        r = post(c, "/posts/new/", Dict("body" => "Look!", "image" => UploadedFile("dot.png", TINY_PNG),
                                        "image_alt" => "A single orange pixel"))
        @test assert_redirects(r, "/")
        p = only(objects(Post))
        @test !isempty(p.image)
        @test startswith(p.image.url, "/media/posts/")
        @test (p.image_width, p.image_height) == (1, 1)         # read from the file
        r = get(c, get_absolute_url(p))
        @test assert_contains(r, "alt=\"A single orange pixel\"")
        @test assert_contains(r, "width=\"1\" height=\"1\"")

        # something that isn't an image is refused
        r = post(c, "/posts/new/", Dict("body" => "Sneaky", "image" => UploadedFile("evil.png", "<script>alert(1)</script>"),
                                        "image_alt" => "Not really a picture"))
        @test haskey(r.context["form"].errors, :image)

        # and so is a picture that's too big (here a valid PNG header followed by 5 MB of padding)
        big = vcat(TINY_PNG, zeros(UInt8, 5_000_001))
        r = post(c, "/posts/new/", Dict("body" => "Huge", "image" => UploadedFile("big.png", big), "image_alt" => "Big"))
        @test haskey(r.context["form"].errors, :image)
        @test count(objects(Post)) == 1

        # posts without pictures still work, and have no <img> for one
        r = post(c, "/posts/new/", Dict("body" => "Just words"); follow = true)
        @test assert_not_contains(r, "post-image\"><img"; html = false)
    end
end
```

The `evil.png` test matters. A file *named* `.png` that's really HTML or JavaScript is a
classic attack, and Juango refuses it because it checks the contents. And in
`accounts/tests.jl`:

```julia
@testset "avatars" begin
    rollback_after() do
        png = hex2bytes("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082")
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "ann lee")
        @test ann.initial == "A"
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/@ann/"), "avatar-initial")       # no avatar yet: the initial

        r = post(c, "/accounts/profile/", Dict("display_name" => "Ann Lee", "bio" => "", "email" => "",
                                               "avatar" => UploadedFile("me.png", png)))
        @test assert_redirects(r, "/@ann/")
        refresh!(ann)
        @test startswith(ann.avatar.url, "/media/avatars/")
        @test assert_contains(get(c, "/@ann/"), ann.avatar.url)
    end
end
```

## Summary

- Uploads go to **`MEDIA_ROOT`** and are served from **`MEDIA_URL`**. Keep them out of git.
- **`ImageField`** checks that uploads are real images. `upload_to` picks the directory, and
  `width_field`/`height_field` record the size.
- **Validators** such as `MaxFileSizeValidator` add checks to a field.
- Forms that upload need **`enctype="multipart/form-data"`**. Files arrive in **`req.FILES`**.
- **`Juango.clean(obj)`** holds rules across fields. It throws a `ValidationError`, and every
  ModelForm (and the admin) enforces it.
- The test client uploads **`UploadedFile`**s into a throwaway `MEDIA_ROOT`.

The code at this point is tagged `ch07`.

Every like, follow and post so far reloads the whole page. In chapter 8 you'll use htmx to
update just the part that changed.
