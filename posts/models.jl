@model struct Post
    author = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :posts)
    body = TextField(max_length = 280)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, p::Post) = print(io, length(p.body) > 50 ? first(p.body, 49) * "…" : p.body)

Juango.get_absolute_url(p::Post) = reverse_url("posts:detail"; id = p.id)
