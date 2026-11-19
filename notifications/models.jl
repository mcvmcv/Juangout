# The kinds of notification: a value stored in the database, and a label for people
@choices Verb begin
    FOLLOW = "follow", "followed you"
    LIKE = "like", "liked your post"
    REPLY = "reply", "replied to your post"
end

@model struct Notification
    recipient = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :notifications)
    actor = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :notifications_caused)
    verb = CharField(max_length = 10, choices = Verb)
    post = ForeignKey(Post; null = true, blank = true, on_delete = :CASCADE, related_name = :notifications)
    read = BooleanField(default = false)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"],
         # every page asks "how many unread notifications has this member?"; an index answers fast
         indexes = [Index(:recipient, :read; name = "notification_unread")])
end

Base.show(io::IO, n::Notification) = print(io, n.actor, " ", n.get_verb_display)
