const urlpatterns = [
    path("", timeline; name = "timeline"),
    path("everyone/", everyone; name = "everyone"),
    path("posts/new/", login_required(post_create); name = "create"),
    path("posts/<int:id>/", post_detail; name = "detail"),
    path("posts/<int:id>/reply/", login_required(post_create); name = "reply"),
    path("posts/<int:id>/delete/", post_delete; name = "delete"),
    path("posts/<int:id>/like/", require_POST(login_required(like)); name = "like"),
]
