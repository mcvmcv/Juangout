using Test
using Juango.Testing

@testset "posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        first_post = create(Post; author = ann, body = "Hello, Juangout!")
        create(Post; author = bob, body = "Bob was here")

        # the ORM
        @test count(objects(Post)) == 2
        @test count(ann.posts) == 1                          # the reverse relation
        @test first_post.author == ann
        @test only(filter(Post; author__username = "bob")).body == "Bob was here"
        @test first(objects(Post)).body == "Bob was here"     # Meta ordering: newest first

        # the timeline
        c = Client()
        r = get(c, "/")
        @test r.status == 200
        @test assert_template_used(r, "posts/timeline.html")
        @test assert_contains(r, "Hello, Juangout!")
        @test assert_contains(r, "Ann Lee")
        @test assert_contains(r, get_absolute_url(first_post))  # links to the post

        # a post's page
        r = get(c, get_absolute_url(first_post))
        @test r.status == 200
        @test r.context["post"] == first_post
        @test get(c, "/posts/999999/").status == 404

        # profiles list the member's posts
        r = get(c, get_absolute_url(ann))
        @test assert_contains(r, "Hello, Juangout!")
        @test assert_not_contains(r, "Bob was here")
    end
end

@testset "timeline pagination" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        for i in 1:25
            create(Post; author = ann, body = "Post number $i")
        end
        c = Client()
        r = get(c, "/")
        @test length(r.context["post_list"]) == 20
        @test r.context["is_paginated"]
        @test assert_contains(r, "Older →")

        r = get(c, "/?page=2")
        @test length(r.context["post_list"]) == 5
        @test assert_not_contains(r, "Welcome to Juangout")    # the welcome is only on page 1
        @test get(c, "/?page=3").status == 404
    end
end

@testset "post validation" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        @test isempty(full_clean(Post(; author = ann, body = "short and sweet")))
        errs = full_clean(Post(; author = ann, body = "x"^281))
        @test haskey(errs, :body)
    end
end

@testset "writing posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()

        # visitors are sent to log in
        r = post(c, "/posts/new/", Dict("body" => "Sneaky"))
        @test assert_redirects(r, "/accounts/login/?next=%2Fposts%2Fnew%2F")
        @test count(objects(Post)) == 0

        force_login!(c, ann)
        @test assert_contains(get(c, "/"), "What&#x27;s on your mind?")    # the compose box

        r = post(c, "/posts/new/", Dict("body" => "My first real post"); follow = true)
        @test r.status == 200
        @test assert_contains(r, "Posted.")
        p = only(objects(Post))
        @test p.author == ann
        @test p.body == "My first real post"

        # empty and too-long posts are refused, with the form shown again
        for body in ("", "x"^281)
            r = post(c, "/posts/new/", Dict("body" => body))
            @test r.status == 200
            @test haskey(r.context["form"].errors, :body)
        end
        @test count(objects(Post)) == 1
    end
end

@testset "deleting posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        mine = create(Post; author = ann, body = "Delete me")
        theirs = create(Post; author = bob, body = "Not yours")
        c = Client()
        force_login!(c, ann)

        @test assert_contains(get(c, "/"), "/posts/$(mine.id)/delete/")
        @test assert_not_contains(get(c, "/"), "/posts/$(theirs.id)/delete/")

        @test get(c, "/posts/$(theirs.id)/delete/").status == 404
        @test post(c, "/posts/$(theirs.id)/delete/").status == 404
        @test count(filter(Post; id = theirs.id)) == 1

        @test get(c, "/posts/$(mine.id)/delete/").status == 200        # the confirmation page
        r = post(c, "/posts/$(mine.id)/delete/")
        @test assert_redirects(r, "/")
        @test count(filter(Post; id = mine.id)) == 0
    end
end
