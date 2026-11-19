const urlpatterns = [
    path("@<str:username>/", profile; name = "profile"),     # {% url 'accounts:profile' username %}
    path("@<str:username>/followers/", followers; name = "followers"),
    path("@<str:username>/following/", following; name = "following"),
    path("@<str:username>/follow/", require_POST(login_required(follow)); name = "follow"),
    path("@<str:username>/unfollow/", require_POST(login_required(unfollow)); name = "unfollow"),
    path("accounts/signup/", signup; name = "signup"),
    path("accounts/profile/", profile_edit; name = "profile_edit"),
]
