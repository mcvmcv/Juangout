# The live timeline: everyone's latest posts, updating while you watch. A live view is a page
# that stays connected to the server over a WebSocket: browser events go to handle_event,
# messages published to its topics go to handle_info, and after each one Juango renders the
# {% liveview %} part of the template again and sends the browser what changed.

Base.@kwdef mutable struct LiveTimeline <: LiveView      # its fields are the template's variables
    posts::Vector{Any} = []
    form::Any = nothing                                   # a LiveForm, made in mount
    chars_left::Int = 280
    me::Any = nothing                                     # the member watching
end

refresh_posts!(v::LiveTimeline) = (v.posts = collect(for_display(top_level(objects(Post)), v.me)[1:30]))

# (`files = nothing`: LiveForm makes its first, empty form with one argument, Juango #256)
new_post_form(me) = LiveForm((data, files = nothing) -> post_form(data; files, instance = Post(; author = me)))

# For the first page load, and each time the WebSocket connects
function Juango.mount(v::LiveTimeline, req, params)
    v.me = req.user
    v.form = new_post_form(req.user)
    subscribe("posts")                  # deliver publish("posts", ...) to handle_info
    refresh_posts!(v)
end

function Juango.handle_event(v::LiveTimeline, name, params)
    if name == "validate"               # typing in the compose box (j-change)
        live_change!(v.form, params)
        v.chars_left = 280 - length(get(params, "body", ""))
    elseif name == "post" && is_authenticated(v.me)       # submitting it (j-submit)
        if live_submit!(v.form, params)
            save!(v.form.form)          # the post_saved signal publishes it, to every open page
            v.form = new_post_form(v.me)
            v.chars_left = 280
        end
    elseif name == "like" && is_authenticated(v.me)       # a heart (j-click)
        post = get(Post; id = parse(Int, params["id"]))
        v.me in post.likers ? remove!(post.likers, v.me) : add!(post.likers, v.me)
    end
end

# Something changed somewhere: a new post, or a like. Fetch the latest again.
Juango.handle_info(v::LiveTimeline, msg) = refresh_posts!(v)

# Tell open live pages about new posts and likes, once they're saved.
announce(sender; kw...) = on_commit(() -> publish("posts", "changed"))
function connect_live_signals()
    connect!(post_save, announce; sender = Post, dispatch_uid = "live_on_post")
    connect!(m2m_changed, announce; sender = through(Post, :likers), dispatch_uid = "live_on_like")
end
