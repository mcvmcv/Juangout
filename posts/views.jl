# Generic views: configured, not written. ListView fetches a page of rows and renders a
# template with them; DetailView fetches one row by the id in the URL.
const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20)

const post_detail = DetailView(Post; template = "posts/detail.html")
