const urlpatterns = [
    path("", home; name = "home"),
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("", include_urls(Accounts.APP)),            # /@username/
]
