@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    # the post this one answers, if it's a reply (deleting a post deletes its replies)
    reply_to = ForeignKey(:self; null = true, blank = true, on_delete = :CASCADE, related_name = :replies)
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
    for_display(posts, user)

The posts, ready for the `posts/_post.html` template: with `like_count`, `reply_count` and
`liked` (whether `user` likes the post), each post's author (and the author of the post it
replies to) fetched in the same query, newest first.
"""
function for_display(posts, user)
    posts = annotate(posts;
        # two counts over two different relations: distinct, or each would multiply the other
        like_count = Count(:likers; distinct = true),
        reply_count = Count(:replies; distinct = true),
        liked = is_authenticated(user) ? Exists(filter(Like; post = OuterRef(:id), member = user)) : Value(false))
    posts = select_related(posts, :author, :reply_to__author)
    # Count makes this a GROUP BY query, which leaves out Meta.ordering, so order explicitly
    order_by(posts, "-created")
end
