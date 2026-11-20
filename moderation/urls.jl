const urlpatterns = [
    path("posts/<int:id>/report/", login_required(report); name = "report"),
    path("moderation/", permission_required("posts.hide_post")(queue); name = "queue"),
    path("moderation/<int:id>/", require_POST(permission_required("posts.hide_post")(decide)); name = "decide"),
]
