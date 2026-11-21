# The JSON API. Each endpoint is a function whose arguments after `req` say what it takes: a
# name in the path ({id}) is a path parameter, a struct is the JSON body, anything else comes
# from the query string. Juango checks them all, and answers 422 with the details if they're wrong.

const juangout_api = API(title = "Juangout API", version = "1",
                         description = "Read and write Juangout as a member. Send `Authorization: Bearer <token>`.",
                         auth = bearer_auth(member_for_key))       # every endpoint needs a token

me(req) = req.meta[:api_auth]                     # the member the token belongs to

page_of(req, posts, limit, offset) =
    PostPage(count(posts), [post_out(req, p) for p in posts[offset+1:offset+clamp(limit, 1, 100)]])

function timeline(req, limit::Union{Int,Nothing} = nothing, offset::Union{Int,Nothing} = nothing)
    page_of(req, for_display(top_level(feed(me(req))), me(req)), something(limit, 20), something(offset, 0))
end
get(timeline, juangout_api, "/timeline"; response = PostPage, summary = "Your timeline: people you follow, and you")

function member_posts(req, username::String, limit::Union{Int,Nothing} = nothing, offset::Union{Int,Nothing} = nothing)
    m = get_object_or_404(get_user_model(); username, is_active = true)
    page_of(req, for_display(m.posts, me(req)), something(limit, 20), something(offset, 0))
end
get(member_posts, juangout_api, "/members/{username}/posts"; response = PostPage, summary = "A member's posts")

get(juangout_api, "/members/{username}"; response = MemberOut, summary = "A member's profile") do req, username::String
    member_out(req, get_object_or_404(get_user_model(); username, is_active = true))
end

get(juangout_api, "/posts/{id}"; response = PostOut, summary = "One post") do req, id::Int
    post_out(req, get_object_or_404(for_display(objects(Post), me(req)); id))
end

Juango.post(juangout_api, "/posts"; status = 201, response = PostOut, summary = "Write a post, or a reply") do req, body::PostIn
    parent = body.reply_to === nothing ? nothing : get_object_or_404(Post; id = body.reply_to, hidden = false)
    p = Post(; author = me(req), body = body.body, reply_to = parent)
    errors = full_clean(p)                         # the model's own rules: length, and so on
    isempty(errors) || return JsonResponse(Dict("detail" => [Dict("loc" => ["body", String(k)], "msg" => join(v, " "))
                                                             for (k, v) in errors]); status = 422)
    save!(p)
    post_out(req, first(for_display(filter(Post; id = p.id), me(req))))
end

route!(juangout_api, "PUT", "/posts/{id}/like"; status = 204, summary = "Like a post") do req, id::Int
    add!(get_object_or_404(Post; id, hidden = false).likers, me(req))
    HttpResponse(""; status = 204)
end

route!(juangout_api, "DELETE", "/posts/{id}/like"; status = 204, summary = "Stop liking a post") do req, id::Int
    remove!(get_object_or_404(Post; id).likers, me(req))
    HttpResponse(""; status = 204)
end
