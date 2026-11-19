function profile(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    me = req.user
    render(req, "accounts/profile.html", Dict(
        "member" => member,
        "posts" => with_like_info(member.posts, me)[1:20],
        "follower_count" => count(member.followers),
        "following_count" => count(member.following),
        "is_me" => is_authenticated(me) && me.id == member.id,
        "i_follow" => is_authenticated(me) && member in me.following,
        "follows_me" => is_authenticated(me) && me in member.following,
    ))
end

# Follow and unfollow: POSTs from the button on a profile.
function follow(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    if member.id == req.user.id
        message!(req, :error, "You can't follow yourself.")
    else
        add!(req.user.following, member)
        message!(req, :success, "You're following $(member.name).")
    end
    redirect(member)
end

function unfollow(req; username)
    member = get_object_or_404(Member; username, is_active = true)
    remove!(req.user.following, member)
    message!(req, :success, "You've unfollowed $(member.name).")
    redirect(member)
end

# Who follows a member, and whom they follow: one ListView, two querysets.
function member_list(relation, heading)
    ListView(Member; template = "accounts/member_list.html", paginate_by = 50,
        get_queryset = v -> order_by(relation(get_object_or_404(Member; username = v.kwargs[:username])), "username"),
        get_context_data = (v, ctx) -> begin
            ctx["member"] = get(Member; username = v.kwargs[:username])
            ctx["heading"] = heading
            ctx
        end)
end
const followers = member_list(m -> m.followers, "Followers")
const following = member_list(m -> m.following, "Following")

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
