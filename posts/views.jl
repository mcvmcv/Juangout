# The form for writing a post: a ModelForm builds its fields from the model's.
post_form(data = nothing; instance = nothing) =
    ModelForm(Post; data, instance, fields = [:body], labels = Dict(:body => "What's on your mind?"))

# What a member's home timeline shows: posts by the people they follow, and their own.
# Visitors who aren't logged in see everyone's.
function feed(user)
    is_authenticated(user) || return objects(Post)
    filter(Post, Q(author__in = user.following) | Q(author = user))
end

# Generic views: configured, not written. ListView fetches a page of rows and renders a
# template with them; DetailView fetches one row by the id in the URL.
const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> with_like_info(feed(v.request.user), v.request.user),
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "feed"; ctx))

const everyone = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> with_like_info(objects(Post), v.request.user),
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "everyone"; ctx))

const post_detail = DetailView(Post; template = "posts/detail.html",
    get_queryset = v -> with_like_info(objects(Post), v.request.user))

# Writing a post, the long way: GET shows the form, a valid POST saves it and redirects,
# an invalid POST shows the form again with its errors.
function post_create(req)
    form = post_form(req.method == "POST" ? req.POST : nothing; instance = Post(; author = req.user))
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, "Posted.")
        return redirect("posts:timeline")
    end
    render(req, "posts/compose.html", Dict("form" => form))
end

# Members may delete only their own posts: the queryset leaves everyone else's out, so
# another member's post is a 404, the same as one that doesn't exist.
const post_delete = DeleteView(Post;
    template = "posts/confirm_delete.html",
    login_required = true,
    get_queryset = v -> filter(Post; author = v.request.user),
    get_success_url = v -> reverse_url("posts:timeline"),
    success_message = "Your post was deleted.")

# Like or unlike (a POST from the heart button), then go back to the page it was on.
function like(req; id)
    post = get_object_or_404(Post; id)
    if post in req.user.liked_posts
        remove!(post.likers, req.user)
    else
        add!(post.likers, req.user)
    end
    redirect_back(req, get_absolute_url(post))
end

# The page named by the form's `next` field, if it's on this site (never redirect to a URL
# a visitor could have planted), else `fallback`.
function redirect_back(req, fallback)
    next = get(req.POST, "next", "")
    url_has_allowed_host_and_scheme(next, [Juango.get_host(req)]) ? redirect(next) : redirect(fallback)
end
