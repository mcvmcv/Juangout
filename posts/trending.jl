# Trending: computed from every post and like, so worth caching. The cache keeps the results
# for a few minutes and everyone shares them; a slightly stale trending list is fine.

"The ids of the top-level posts liked most in the last `hours` hours, most liked first."
function trending_post_ids(; hours = 24, n = 20)
    get_or_set("trending:posts", function ()
        since = timezone_now() - Hour(hours)
        qs = filter(Post; hidden = false, reply_to__isnull = true)
        qs = annotate(qs; recent_likes = Count(:likes; filter = Q(likes__created__gte = since)))
        qs = order_by(filter(qs; recent_likes__gt = 0), "-recent_likes", "-created")
        collect(values_list(qs[1:n], :id; flat = true))
    end; timeout = 300)
end

"The tags used most in the last week, as (name, uses) pairs."
function trending_tags(; days = 7, n = 12)
    get_or_set("trending:tags", function ()
        since = timezone_now() - Day(days)
        qs = annotate(objects(Tag); uses = Count(:posts; filter = Q(posts__created__gte = since, posts__hidden = false)))
        [(name = t.name, uses = t.uses) for t in order_by(filter(qs; uses__gt = 0), "-uses", "name")[1:n]]
    end; timeout = 600)
end

# The page: the cached ids, then the posts for this member (their own likes), in trending order.
function trending(req)
    ids = trending_post_ids()
    posts = sort(collect(for_display(filter(Post; id__in = ids), req.user)); by = p -> findfirst(==(p.id), ids))
    render(req, "posts/trending.html", Dict("posts" => posts, "tags" => trending_tags(), "tab" => "trending"))
end
