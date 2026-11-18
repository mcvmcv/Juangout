const urlpatterns = [
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("", include_urls(Accounts.APP)),            # /@username/
    path("", include_urls(Posts.APP)),               # the timeline at /, posts at /posts/<id>/
]
