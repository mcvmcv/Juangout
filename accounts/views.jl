function profile(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    render(req, "accounts/profile.html", Dict("member" => member))
end

# The sign-up page: a form on GET, and on a valid POST a new member, logged in.
function signup(req)
    is_authenticated(req.user) && return redirect("posts:timeline")
    form = UserCreationForm(req.method == "POST" ? req.POST : nothing; fields = [:username, :email])
    if req.method == "POST" && is_valid(form)
        member = save!(form)
        login!(req, member)
        message!(req, :success, "Welcome to Juangout, $(member.username)! Tell people a bit about yourself.")
        return redirect("accounts:profile_edit")
    end
    render(req, "accounts/signup.html", Dict("form" => form))
end

# Editing your own profile. UpdateView shows a form for one object and saves it; the
# get_object hook makes that object the logged-in member, whatever the URL.
const profile_edit = UpdateView(Member;
    fields = [:display_name, :bio, :email],
    template = "accounts/profile_edit.html",
    login_required = true,
    get_object = v -> v.request.user,
    success_message = "Your profile was saved.")
