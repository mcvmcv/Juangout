# A template tag library: `{% load posts_extras %}` in a template, then `{{ text|hashtags }}`.
const posts_extras = TagLibrary("posts_extras")

# Turn #words into links to their tag pages. The text is escaped first (unless it's already
# safe HTML, as linebreaksbr's output is), so only our own <a> tags are HTML.
function linkify_hashtags(value, _)
    html = value isa SafeString ? string(value) : escape_html(string(value))
    mark_safe(replace(html, HASHTAG => function (m)
        name = lowercase(m[2:end])
        "<a class=\"hashtag\" href=\"$(reverse_url("posts:tag"; name))\">$m</a>"
    end))
end
filter!(linkify_hashtags, posts_extras, "hashtags")
