const urlpatterns = [
    path("about/", TemplateView("about.html"); name = "about"),
    path("admin/", Admin.urls()),
    path("accounts/", Juango.auth_urls()),            # login/, logout/, password_change/, ...
    path("i18n/", i18n_urls()),                       # setlang/: the language switcher
    path("", include_urls(Accounts.APP)),            # /@username/
    path("", include_urls(Posts.APP)),               # the timeline at /, posts at /posts/<id>/
    path("", include_urls(Notifications.APP)),       # /notifications/
    path("", include_urls(Moderation.APP)),          # /moderation/, /posts/<id>/report/
]
