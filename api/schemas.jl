# The shapes of the API's requests and replies: plain Julia structs. Juango decodes JSON bodies
# into them, checking types, and documents them in the OpenAPI description.
struct MemberOut
    username::String
    name::String
    bio::String
    followers::Int
    following::Int
    url::String
end

struct PostOut
    id::Int
    author::String
    body::String
    created::String          # ISO 8601, in UTC
    reply_to::Union{Int,Nothing}
    like_count::Int
    reply_count::Int
    liked::Bool
    url::String
end

struct PostIn
    body::String
    reply_to::Union{Int,Nothing}
end

struct PostPage
    count::Int
    items::Vector{PostOut}
end

absolute(req, obj) = Juango.build_absolute_uri(req, get_absolute_url(obj))

post_out(req, p) = PostOut(p.id, p.author.username, p.body, string(p.created), p.reply_to_id,
                           p.like_count, p.reply_count, p.liked, absolute(req, p))

member_out(req, m) = MemberOut(m.username, m.name, m.bio, count(m.followers), count(m.following), absolute(req, m))
