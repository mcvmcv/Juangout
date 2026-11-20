# A hashtag. Posts get their tags from the #words in their body (see save! below).
@model struct Tag
    name = CharField(max_length = 50, unique = true)      # lowercase, without the #
    Meta(ordering = ["name"])
end

Base.show(io::IO, t::Tag) = print(io, "#", t.name)
Juango.get_absolute_url(t::Tag) = reverse_url("posts:tag"; name = t.name)

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
    # the post this one answers, if it's a reply (deleting a post deletes its replies)
    reply_to = ForeignKey(:self; null = true, blank = true, on_delete = :CASCADE, related_name = :replies)
    # the members who like this post, stored as Like rows
    likers = ManyToManyField(USER_MODEL; through = :Like, related_name = :liked_posts, blank = true)
    tags = ManyToManyField(Tag; related_name = :posts, blank = true)
    hidden = BooleanField(default = false, help_text = "Hidden by a moderator: shown to moderators only.")
    Meta(ordering = ["-created"],
         # a permission of our own, beside the add/change/delete/view ones every model gets
         permissions = [("hide_post", "Can hide posts")])
end

Base.show(io::IO, p::Post) = print(io, length(p.body) > 50 ? first(p.body, 49) * "…" : p.body)

Juango.get_absolute_url(p::Post) = reverse_url("posts:detail"; id = p.id)

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

@model struct Like
    member = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :likes)
    post = ForeignKey(Post; on_delete = :CASCADE, related_name = :likes)
    created = DateTimeField(auto_now_add = true)
    Meta(constraints = [UniqueConstraint(fields = [:member, :post], name = "like_once")])
end

"""
    for_display(posts, user)

The posts, ready for the `posts/_post.html` template: with `like_count`, `reply_count` and
`liked` (whether `user` likes the post), each post's author (and the author of the post it
replies to) fetched in the same query, newest first. Hidden posts only for moderators.
"""
function for_display(posts, user)
    # hidden posts are left out, except for moderators
    has_perm(user, "posts.hide_post") || (posts = filter(posts; hidden = false))
    posts = annotate(posts;
        # two counts over two different relations: distinct, or each would multiply the other
        like_count = Count(:likers; distinct = true),
        reply_count = Count(:replies; distinct = true),
        liked = is_authenticated(user) ? Exists(filter(Like; post = OuterRef(:id), member = user)) : Value(false))
    posts = select_related(posts, :author, :reply_to__author)
    # Count makes this a GROUP BY query, which leaves out Meta.ordering, so order explicitly
    order_by(posts, "-created")
end
