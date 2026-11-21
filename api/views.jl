# Managing your API tokens: a list, a form to make one, and revoking.
function tokens(req)
    secret = nothing
    form = ModelForm(ApiToken; data = req.method == "POST" ? req.POST : nothing, fields = [:name])
    if req.method == "POST" && is_valid(form)
        token, secret = new_token!(req.user, form.cleaned_data[:name])
        form = ModelForm(ApiToken; fields = [:name])
    end
    # the secret is shown once, on this response, and never again
    render(req, "api/tokens.html", Dict("tokens" => req.user.api_tokens, "form" => form, "secret" => secret))
end

function revoke(req; id)
    delete!(get_object_or_404(ApiToken; id, member = req.user))
    message!(req, :success, "The token was revoked. Programs using it can't any more.")
    redirect("api:tokens")
end
