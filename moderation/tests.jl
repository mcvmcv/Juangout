using Test
using Juango.Testing

@testset "moderation" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        mod = create_user("mo"; password = "correct-horse-battery")
        spam = create(Post; author = bob, body = "BUY CHEAP WATCHES")

        # migrate made the Moderators group (the post_migrate receiver); joining it grants the permission
        moderators = get(Group; name = "Moderators")
        @test Set(p.codename for p in moderators.permissions) == Set(["hide_post", "view_report", "change_report"])
        @test !has_perm(mod, "posts.hide_post")
        add!(mod.groups, moderators)
        mod = get(Member; id = mod.id)                 # permissions are cached on the user: fetch it again
        @test has_perm(mod, "posts.hide_post")

        # members report posts, once each
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/everyone/"), "/posts/$(spam.id)/report/")
        r = post(c, "/posts/$(spam.id)/report/", Dict("reason" => "spam", "note" => "Obvious spam"); follow = true)
        @test assert_contains(r, "A moderator will take a look.")
        r = post(c, "/posts/$(spam.id)/report/", Dict("reason" => "abuse"); follow = true)
        @test assert_contains(r, "already reported")
        force_login!(c, cat)
        post(c, "/posts/$(spam.id)/report/", Dict("reason" => "abuse"))
        @test count(spam.reports) == 2

        # only moderators can see the queue
        @test get(c, "/moderation/").status == 403
        @test assert_not_contains(get(c, "/"), ">Moderation</a>")      # no link in the header
        @test assert_redirects(get(Client(), "/moderation/"), "/accounts/login/?next=%2Fmoderation%2F")
        force_login!(c, mod)
        r = get(c, "/moderation/")
        @test r.status == 200
        p = only(r.context["page_obj"])
        @test p.report_count == 2
        @test length(p.open_reports) == 2
        @test assert_contains(r, "Obvious spam")

        # hiding: gone from timelines and its page for members, but still there for moderators
        post(c, "/moderation/$(spam.id)/", Dict("decision" => "hide"))
        @test get(Post; id = spam.id).hidden
        @test count(filter(Report; post = spam, resolved = false)) == 0
        @test get(Report; post = spam, reporter = ann).resolved_by == mod
        @test isempty(get(c, "/moderation/").context["page_obj"])
        force_login!(c, ann)
        @test assert_not_contains(get(c, "/everyone/"), "BUY CHEAP WATCHES")
        @test get(c, "/posts/$(spam.id)/").status == 404
        force_login!(c, mod)
        @test assert_contains(get(c, "/posts/$(spam.id)/"), "hidden")

        # dismissing leaves the post alone
        fine = create(Post; author = bob, body = "A perfectly fine post")
        create(Report; post = fine, reporter = ann, reason = Reason.OTHER)
        post(c, "/moderation/$(fine.id)/", Dict("decision" => "dismiss"))
        @test !get(Post; id = fine.id).hidden
        @test all(r.resolved for r in fine.reports)

        # deciding is POST only, and moderators only
        @test get(c, "/moderation/$(fine.id)/").status == 405
        force_login!(c, ann)
        @test post(c, "/moderation/$(fine.id)/", Dict("decision" => "hide")).status == 403
    end
end

@testset "moderation in the admin" begin
    rollback_after() do
        boss = create_superuser("boss"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        spam = create(Post; author = bob, body = "spam spam spam")
        r1 = create(Report; post = spam, reporter = boss, reason = Reason.SPAM)
        c = Client()
        force_login!(c, boss)
        @test get(c, "/admin/moderation/report/").status == 200
        # run the "hide the reported posts" action on the selected report
        r = post(c, "/admin/moderation/report/", Dict("action" => "hide_reported_posts", "_selected_action" => string(r1.id),
                                                      "post" => "yes"); follow = true)
        @test r.status == 200
        @test get(Post; id = spam.id).hidden
        @test get(Report; id = r1.id).resolved
    end
end
