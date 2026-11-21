# Feeds: a member's posts as RSS 2.0 or Atom, for feed readers. A Feed is a view; these options
# say where its items come from and what each part of an item is.
const member_feed = Feed(
    get_object = (req; username) -> get_object_or_404(get_user_model(); username, is_active = true),
    title = m -> "$(m.name) on Juangout",
    link = m -> get_absolute_url(m),
    description = m -> "The latest posts by @$(m.username)",
    items = m -> filter(Post; author = m, hidden = false, reply_to__isnull = true)[1:20],
    item_title = p -> length(p.body) > 60 ? first(p.body, 59) * "…" : p.body,
    item_description = :body,
    item_pubdate = :created,
    item_author_name = p -> p.author.name)

# Feeds are the same for everyone, so whole responses can be cached: five minutes is fresh
# enough for a feed reader, and saves the queries when many readers poll.
const member_rss = cache_page(member_feed; timeout = 300)
const member_atom = cache_page(Feed(member_feed; feed_type = :atom); timeout = 300)
