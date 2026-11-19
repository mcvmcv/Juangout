@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    # the members who like this post, stored as Like rows
    likers = ManyToManyField(USER_MODEL; through = :Like, related_name = :liked_posts, blank = true)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, p::Post) = print(io, length(p.body) > 50 ? first(p.body, 49) * "…" : p.body)

Juango.get_absolute_url(p::Post) = reverse_url("posts:detail"; id = p.id)

@model struct Like
    member = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :likes)
    post = ForeignKey(Post; on_delete = :CASCADE, related_name = :likes)
    created = DateTimeField(auto_now_add = true)
    Meta(constraints = [UniqueConstraint(fields = [:member, :post], name = "like_once")])
end

"""
    with_like_info(posts, user)

The posts with two extra columns for templates: `like_count`, and `liked` (whether `user`
likes the post).
"""
function with_like_info(posts, user)
    # Count makes this a GROUP BY query, which leaves out Meta.ordering, so order explicitly
    posts = order_by(annotate(posts; like_count = Count(:likers)), "-created")
    is_authenticated(user) || return annotate(posts; liked = Value(false))
    annotate(posts; liked = Exists(filter(Like; post = OuterRef(:id), member = user)))
end
