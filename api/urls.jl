const urlpatterns = [
    path("api/v1/", api_urls(juangout_api)),        # the endpoints, plus openapi.json and docs/
    path("@<str:username>/feed/", member_rss; name = "feed"),
    path("@<str:username>/feed/atom/", member_atom; name = "feed_atom"),
    path("accounts/tokens/", login_required(tokens); name = "tokens"),
    path("accounts/tokens/<int:id>/revoke/", require_POST(login_required(revoke)); name = "revoke"),
]
