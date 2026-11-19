# The form for writing a post: a ModelForm builds its fields from the model's.
post_form(data = nothing; files = nothing, instance = nothing, label = "What's on your mind?") =
    ModelForm(Post; data, files, instance, fields = [:body, :image, :image_alt], labels = Dict(:body => label))

# What a member's home timeline shows: posts by the people they follow, and their own.
# Visitors who aren't logged in see everyone's.
function feed(user)
    is_authenticated(user) || return objects(Post)
    filter(Post, Q(author__in = user.following) | Q(author = user))
end

# Timelines show conversations' first posts; replies are on each post's page.
top_level(posts) = filter(posts; reply_to__isnull = true)

# Generic views: configured, not written. ListView fetches a page of rows and renders a
# template with them; DetailView fetches one row by the id in the URL.
# The whole page normally; for htmx's "load the next page" requests, just the posts.
timeline_template(v) = is_htmx(v.request; boosted = false) ? ["posts/timeline.html#page"] : ["posts/timeline.html"]

const timeline = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> for_display(top_level(feed(v.request.user)), v.request.user),
    get_template_names = timeline_template,
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "feed"; ctx))

const everyone = ListView(Post; template = "posts/timeline.html", paginate_by = 20,
    get_queryset = v -> for_display(top_level(objects(Post)), v.request.user),
    get_template_names = timeline_template,
    get_context_data = (v, ctx) -> (ctx["form"] = post_form(); ctx["tab"] = "everyone"; ctx))

# A post's page: the post it replies to (if any), the post, a reply form, and the replies,
# oldest first so they read as a conversation.
const post_detail = DetailView(Post; template = "posts/detail.html",
    get_queryset = v -> for_display(objects(Post), v.request.user),
    get_context_data = function (v, ctx)
        post, user = v.object, v.request.user
        ctx["parent"] = post.reply_to_id === nothing ? nothing :
                        first(for_display(filter(Post; id = post.reply_to_id), user))
        ctx["replies"] = order_by(for_display(post.replies, user), "created")
        ctx["form"] = post_form(; label = "Your reply")
        ctx
    end)

# Writing a post or a reply: GET shows the form, a valid POST saves it and redirects,
# an invalid POST shows the form again with its errors.
function post_create(req; id = nothing)
    parent = id === nothing ? nothing : get_object_or_404(Post; id)
    posting = req.method == "POST"
    form = post_form(posting ? req.POST : nothing; files = posting ? req.FILES : nothing,
                     instance = Post(; author = req.user, reply_to = parent),
                     label = parent === nothing ? "What's on your mind?" : "Your reply")
    if posting && is_valid(form)
        post = save!(form)
        message!(req, :success, parent === nothing ? "Posted." : "Replied.")
        if is_htmx(req)
            # an empty form in place of the one submitted, and the new post added to the page
            return render(req, "posts/_compose_done.html", Dict("form" => post_form(), "reply_to" => parent,
                          "post" => first(for_display(filter(Post; id = post.id), req.user))))
        end
        return parent === nothing ? redirect("posts:timeline") : redirect(parent)
    end
    if is_htmx(req)       # the form again, with its errors, in place (422: "not accepted")
        return render(req, "posts/_compose_form.html", Dict("form" => form, "reply_to" => parent);
                      status = form_status(form))
    end
    render(req, "posts/compose.html", Dict("form" => form, "parent" => parent))
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
    if is_htmx(req)       # just the button, with its new count, for htmx to swap in
        post = first(for_display(filter(Post; id), req.user))
        return render(req, "posts/_post.html#like_button", Dict("post" => post))
    end
    redirect_back(req, get_absolute_url(post))
end

# The page named by the form's `next` field, if it's on this site (never redirect to a URL
# a visitor could have planted), else `fallback`.
function redirect_back(req, fallback)
    next = get(req.POST, "next", "")
    url_has_allowed_host_and_scheme(next, [Juango.get_host(req)]) ? redirect(next) : redirect(fallback)
end
