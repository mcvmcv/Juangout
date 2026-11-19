using Test
using Juango.Testing

@testset "notifications" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", email = "ann@example.com")
        bob = create_user("bob"; password = "correct-horse-battery", email = "bob@example.com")
        p = create(Post; author = ann, body = "Hello")

        # the signals turn follows, likes and replies into notifications
        add!(bob.following, ann)
        add!(p.likers, bob)
        create(Post; author = bob, body = "Hi Ann!", reply_to = p)
        @test [n.verb for n in ann.notifications] == ["reply", "like", "follow"]     # newest first
        @test all(n.actor == bob for n in ann.notifications)
        @test first(ann.notifications).get_verb_display == "replied to your post"

        # ...from either side of the relation
        add!(ann.followers, create_user("cat"; password = "correct-horse-battery"))
        @test count(filter(Notification; recipient = ann, verb = Verb.FOLLOW)) == 2

        # nothing for your own likes and replies
        add!(p.likers, ann)
        create(Post; author = ann, body = "Replying to myself", reply_to = p)
        @test count(ann.notifications) == 4
        @test count(bob.notifications) == 0

        # the header shows the unread count; the page shows them and marks them read
        c = Client()
        force_login!(c, ann)
        r = get(c, "/")
        @test r.context["unread_count"] == 4
        @test assert_contains(r, "4 unread")
        r = get(c, "/notifications/")
        @test length(r.context["notifications"]) == 4
        @test count(r.context["notifications"]) do n; !n.read; end == 4     # shown as unread this time
        @test assert_contains(r, "replied to your post")
        @test count(filter(Notification; recipient = ann, read = false)) == 0
        @test get(c, "/").context["unread_count"] == 0

        @test assert_redirects(get(Client(), "/notifications/"), "/accounts/login/?next=%2Fnotifications%2F")
    end
end

@testset "notification emails" begin
    # Collect mail in `outbox`. (Juango's test runner only does this itself when the backend is
    # :smtp, Juango #254, and in development ours prints mail to the console.)
    override_settings(EMAIL_BACKEND = :locmem) do
        rollback_after() do
            ann = create_user("ann"; password = "correct-horse-battery", email = "ann@example.com")
            bob = create_user("bob"; password = "correct-horse-battery", email = "bob@example.com")
            p = create(Post; author = ann, body = "Hello")
            empty!(outbox)

            # The email is sent when the transaction commits, which a test's rollback_after never
            # does. capture_on_commit_callbacks runs the callbacks registered inside it.
            capture_on_commit_callbacks(; execute = true) do
                create(Post; author = bob, body = "Hi Ann!", reply_to = p)
            end
            @test length(outbox) == 1
            mail = only(outbox)
            @test mail.to == ["ann@example.com"]
            @test mail.subject == "bob replied to your post on Juangout"
            @test occursin("Hi Ann!", mail.body)
            @test occursin("/posts/", mail.body)

            # likes aren't emailed
            capture_on_commit_callbacks(; execute = true) do
                add!(p.likers, bob)
            end
            @test length(outbox) == 1

            # and members can turn emails off
            ann.email_notifications = false
            save!(ann)
            capture_on_commit_callbacks(; execute = true) do
                add!(bob.following, ann)
            end
            @test length(outbox) == 1
            @test count(ann.notifications) == 3         # the notifications are still made
        end
    end
end
