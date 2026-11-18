const urlpatterns = [
    path("", timeline; name = "timeline"),
    path("posts/new/", login_required(post_create); name = "create"),
    path("posts/<int:id>/", post_detail; name = "detail"),
    path("posts/<int:id>/delete/", post_delete; name = "delete"),
]
