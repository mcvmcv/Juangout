# Signal receivers: Juango calls these when members follow, like or reply, wherever in the code
# that happens. The posts and accounts apps don't need to know notifications exist.

const EMAILED = (Verb.FOLLOW, Verb.REPLY)       # likes are too frequent to email about

function notify!(recipient, actor, verb; post = nothing)
    recipient.id == actor.id && return nothing  # liking or replying to your own post
    n = create(Notification; recipient, actor, verb, post)
    # email once the transaction commits: the task runs elsewhere, and must see the notification
    verb in EMAILED && on_commit(() -> enqueue(email_notification, n.id))
    n
end

# Follows and likes are made with add!, which sends m2m_changed, with the through model as
# the sender. `instance` is the object add! was called on and `pk_set` the ids it added to the
# other side; `reverse` says which side add! was called from (post.likers or member.liked_posts).
function on_follow(sender; action, instance, pk_set, reverse, kw...)
    action === :post_add || return
    for id in pk_set
        other = get(get_user_model(); id)
        follower, followed = reverse ? (other, instance) : (instance, other)
        notify!(followed, follower, Verb.FOLLOW)
    end
end

function on_like(sender; action, instance, pk_set, reverse, kw...)
    action === :post_add || return
    for id in pk_set
        post, member = reverse ? (get(Post; id), instance) : (instance, get(get_user_model(); id))
        notify!(post.author, member, Verb.LIKE; post)
    end
end

# A reply is an ordinary Post being saved, so post_save
function on_reply(sender; instance, created, kw...)
    (created && instance.reply_to_id !== nothing) || return
    notify!(instance.reply_to.author, instance.author, Verb.REPLY; post = instance)
end

function connect_signals()
    connect!(m2m_changed, on_follow; sender = through(Member, :following), dispatch_uid = "notify_on_follow")
    connect!(m2m_changed, on_like; sender = through(Post, :likers), dispatch_uid = "notify_on_like")
    connect!(post_save, on_reply; sender = Post, dispatch_uid = "notify_on_reply")
end
