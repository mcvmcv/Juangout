const urlpatterns = [
    path("", timeline; name = "timeline"),
    path("everyone/", everyone; name = "everyone"),
    live("live/", LiveTimeline, "posts/live.html"; name = "live"),
    path("search/", search; name = "search"),
    path("trending/", trending; name = "trending"),
    path("tags/<str:name>/", tag_posts; name = "tag"),
    path("posts/new/", login_required(post_create); name = "create"),
    path("posts/<int:id>/", post_detail; name = "detail"),
    path("posts/<int:id>/reply/", login_required(post_create); name = "reply"),
    path("posts/<int:id>/delete/", post_delete; name = "delete"),
    path("posts/<int:id>/like/", require_POST(login_required(like)); name = "like"),
]
