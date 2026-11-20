using Test
using Juango.Testing

@testset "posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        first_post = create(Post; author = ann, body = "Hello, Juangout!")
        first_post.created = timezone_now() - Minute(5); save!(first_post)    # so the order is certain
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
        @test assert_contains(r, "Older posts")

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

@testset "the following feed" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        for (i, m) in enumerate((ann, bob, cat))           # an hour apart, ann's the oldest
            p = create(Post; author = m, body = "by $(m.username)")
            p.created = timezone_now() - Hour(4 - i); save!(p)
        end
        add!(ann.following, bob)

        bodies(r) = Set(p.body for p in r.context["post_list"])
        c = Client()
        @test bodies(get(c, "/")) == Set(["by ann", "by bob", "by cat"])        # visitors see everyone
        force_login!(c, ann)
        @test bodies(get(c, "/")) == Set(["by ann", "by bob"])                  # people ann follows, and ann
        @test bodies(get(c, "/everyone/")) == Set(["by ann", "by bob", "by cat"])
        # newest first, even though like counts make it a GROUP BY query
        @test [p.body for p in get(c, "/everyone/").context["post_list"]] == ["by cat", "by bob", "by ann"]
    end
end

@testset "likes" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        p = create(Post; author = bob, body = "Like me")

        # annotate: one query, with the count and whether this member likes each post
        add!(p.likers, bob)
        row = only(for_display(objects(Post), ann))
        @test row.like_count == 1
        @test row.liked == false
        @test only(for_display(objects(Post), bob)).liked == true
        @test only(for_display(objects(Post), AnonymousUser())).like_count == 1

        # the heart button toggles, and goes back to the page it was on
        c = Client()
        force_login!(c, ann)
        r = post(c, "/posts/$(p.id)/like/", Dict("next" => "/everyone/?page=1"))
        @test assert_redirects(r, "/everyone/?page=1")
        @test ann in p.likers
        @test count(Like) == 2
        r = get(c, "/posts/$(p.id)/")
        @test r.context["post"].like_count == 2
        @test r.context["post"].liked
        @test assert_contains(r, "aria-pressed=\"true\"")

        post(c, "/posts/$(p.id)/like/")
        @test !(ann in p.likers)

        # never redirect off the site
        r = post(c, "/posts/$(p.id)/like/", Dict("next" => "https://evil.example/"))
        @test assert_redirects(r, "/posts/$(p.id)/")
        @test post(Client(), "/posts/$(p.id)/like/").status == 302       # to the login page
        @test get(c, "/posts/$(p.id)/like/").status == 405
    end
end

@testset "replies" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        question = create(Post; author = ann, body = "Tabs or spaces?")
        c = Client()
        force_login!(c, bob)

        r = post(c, "/posts/$(question.id)/reply/", Dict("body" => "Spaces, obviously"); follow = true)
        @test assert_contains(r, "Replied.")
        @test r.context["post"] == question                    # back on the question's page
        answer = only(question.replies)
        @test answer.author == bob
        @test answer.reply_to == question

        # the question's page shows the reply and counts it
        @test [p.body for p in r.context["replies"]] == ["Spaces, obviously"]
        @test r.context["post"].reply_count == 1
        # the reply's page shows what it replies to
        r = get(c, get_absolute_url(answer))
        @test r.context["parent"] == question
        @test assert_contains(r, "replying to")

        # timelines show only conversations' first posts; profiles show replies too
        @test [p.body for p in get(c, "/everyone/").context["post_list"]] == ["Tabs or spaces?"]
        @test assert_contains(get(c, "/@bob/"), "Spaces, obviously")

        @test post(c, "/posts/999999/reply/", Dict("body" => "?")).status == 404
        # deleting a post deletes its replies
        delete!(question)
        @test count(objects(Post)) == 0
    end
end

@testset "counting likes and replies together" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "Popular")
        add!(p.likers, ann, bob)
        for i in 1:3
            create(Post; author = bob, body = "reply $i", reply_to = p)
        end
        # Without distinct = true, joining both likes and replies would give 2 × 3 = 6 of each
        row = first(for_display(filter(Post; id = p.id), ann))
        @test row.like_count == 2
        @test row.reply_count == 3
    end
end

@testset "queries per page" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        add!(ann.following, bob)
        c = Client()
        force_login!(c, ann)

        # NPLUSONE = :raise turns Juango's N+1 warning into an error
        override_settings(DEBUG = true, NPLUSONE = :raise) do
            make_posts(n) = for i in 1:n
                p = create(Post; author = isodd(i) ? ann : bob, body = "post $i")
                create(Post; author = bob, body = "reply to $i", reply_to = p)
            end
            make_posts(3)
            _, few = count_queries(() -> get(c, "/"))
            make_posts(15)
            _, many = count_queries(() -> get(c, "/"))
            @test few == many                 # the same number of queries, however many posts

            q = first(filter(Post; reply_to__isnull = true))
            for url in ("/", "/everyone/", "/@bob/", get_absolute_url(q), get_absolute_url(first(q.replies)))
                @test get(c, url).status == 200
            end
        end
    end
end

# a real 1×1 PNG, small enough to write out by hand
const TINY_PNG = hex2bytes("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082")

@testset "pictures in posts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)

        # a picture without a description is refused by the model's clean rule
        r = post(c, "/posts/new/", Dict("body" => "Look!", "image" => UploadedFile("dot.png", TINY_PNG)))
        @test r.status == 200
        @test r.context["form"].errors[:image_alt] == ["Please describe the picture."]

        r = post(c, "/posts/new/", Dict("body" => "Look!", "image" => UploadedFile("dot.png", TINY_PNG),
                                        "image_alt" => "A single orange pixel"))
        @test assert_redirects(r, "/")
        p = only(objects(Post))
        @test !isempty(p.image)
        @test startswith(p.image.url, "/media/posts/")
        @test (p.image_width, p.image_height) == (1, 1)         # read from the file
        r = get(c, get_absolute_url(p))
        @test assert_contains(r, "alt=\"A single orange pixel\"")
        @test assert_contains(r, "width=\"1\" height=\"1\"")

        # something that isn't an image is refused
        r = post(c, "/posts/new/", Dict("body" => "Sneaky", "image" => UploadedFile("evil.png", "<script>alert(1)</script>"),
                                        "image_alt" => "Not really a picture"))
        @test haskey(r.context["form"].errors, :image)

        # and so is a picture that's too big (here a valid PNG header followed by 5 MB of padding)
        big = vcat(TINY_PNG, zeros(UInt8, 5_000_001))
        r = post(c, "/posts/new/", Dict("body" => "Huge", "image" => UploadedFile("big.png", big), "image_alt" => "Big"))
        @test haskey(r.context["form"].errors, :image)
        @test count(objects(Post)) == 1

        # posts without pictures still work, and have no <img> for one
        r = post(c, "/posts/new/", Dict("body" => "Just words"); follow = true)
        @test assert_not_contains(r, "post-image\"><img"; html = false)
    end
end

@testset "htmx: likes, posting and infinite scroll" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "Hello")
        c = Client()
        force_login!(c, ann)

        # the page loads htmx and has somewhere for messages to go
        r = get(c, "/")
        @test assert_contains(r, "htmx.min.js")
        @test assert_contains(r, "id=\"messages\"")

        # liking with htmx returns just the button, with the new count
        r = post(c, "/posts/$(p.id)/like/"; htmx = true)
        @test r.status == 200
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "aria-pressed=\"true\"")
        @test assert_contains(r, "♥ 1")
        @test ann in p.likers

        # posting with htmx returns a fresh form and the new post, swapped in out of band
        r = post(c, "/posts/new/", Dict("body" => "Posted without a reload"); htmx = true)
        @test r.status == 200
        @test assert_contains(r, "hx-swap-oob=\"afterbegin:#post-list\"")
        @test assert_contains(r, "Posted without a reload")
        @test assert_contains(r, "Posted.")                  # the message, out of band too
        @test count(objects(Post)) == 2

        # replying adds the reply to the end of the thread
        r = post(c, "/posts/$(p.id)/reply/", Dict("body" => "A reply"); htmx = true)
        @test assert_contains(r, "hx-swap-oob=\"beforeend:#replies\"")

        # an invalid post comes back as the form with its errors, status 422
        r = post(c, "/posts/new/", Dict("body" => ""); htmx = true)
        @test r.status == 422
        @test haskey(r.context["form"].errors, :body)
        @test assert_not_contains(r, "<html"; status = 422)

        # infinite scroll: htmx asks for the next page and gets just its posts
        for i in 1:25
            create(Post; author = ann, body = "filler $i")
        end
        r = get(c, "/")
        @test assert_contains(r, "hx-get=\"?page=2\"")
        r = get(c, "/?page=2"; htmx = true)
        @test assert_not_contains(r, "<html")
        @test assert_not_contains(r, "id=\"post-list\"")     # the posts only, not their container
        @test length(r.context["post_list"]) == 7
        @test assert_not_contains(r, "hx-get=\"?page=3\"")   # the last page
    end
end

@testset "the live timeline" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        create(Post; author = bob, body = "Already here")

        # the page itself is ordinary HTML, with the live part marked for live.js
        c = Client()
        force_login!(c, ann)
        r = get(c, "/live/")
        @test r.status == 200
        @test assert_contains(r, "data-j-live=\"/live/\"")
        @test assert_contains(r, "live.js")
        @test assert_contains(r, "Already here")

        # live_test mounts the view without a browser; events and messages return the new HTML
        lt = live_test(LiveTimeline, "posts/live.html"; user = ann, path = "/live/")
        @test occursin("Already here", lt.html)

        # typing: validated as you go, with a running count
        html = live_event!(lt, "validate", Dict("body" => "x"^290, "_target" => "body"))
        @test occursin("-10 characters left", html)
        @test haskey(lt.view.form.form.errors, :body)

        # posting over the socket saves the post (and the form starts again)
        capture_on_commit_callbacks(; execute = true) do
            live_event!(lt, "post", Dict("body" => "Hello, live!"))
        end
        @test count(filter(Post; author = ann, body = "Hello, live!")) == 1
        @test lt.view.chars_left == 280

        # someone else posts: the published message reaches the view, which shows it
        capture_on_commit_callbacks(; execute = true) do
            create(Post; author = bob, body = "Breaking news")
        end
        html = live_flush!(lt)
        @test occursin("Breaking news", html)
        @test occursin("Hello, live!", html)

        # likes are live events too
        p = get(Post; body = "Breaking news")
        capture_on_commit_callbacks(; execute = true) do
            live_event!(lt, "like", Dict("id" => string(p.id)))
        end
        @test ann in p.likers
        @test occursin("j-click=\"like\"", live_flush!(lt))
    end
end

@testset "hashtags" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        @test Posts.hashtags("Loving #Julia and #juliaLang, not C# or &#x27;") == ["julia", "julialang"]

        # saving a post gives it its tags, and editing it keeps them up to date
        p = create(Post; author = ann, body = "Learning #Julia today #til")
        @test Set(t.name for t in p.tags) == Set(["julia", "til"])
        p.body = "Learning #Julia, still"
        save!(p)
        @test [t.name for t in p.tags] == ["julia"]
        @test count(Tag) == 2                           # the #til tag remains, with no posts

        # the filter links hashtags, and leaves everything else escaped
        r = get(Client(), get_absolute_url(p))
        @test assert_contains(r, "<a class=\"hashtag\" href=\"/tags/julia/\">#Julia</a>"; html = false)
        create(Post; author = ann, body = "It's <b>bold</b> #fun")
        r = get(Client(), "/tags/fun/")
        @test assert_contains(r, "It&#x27;s &lt;b&gt;bold&lt;/b&gt;"; html = false)   # escaped, apostrophe not a tag
        @test assert_not_contains(r, "/tags/x27/")

        # a tag's page lists its posts; an unknown tag is a 404
        r = get(Client(), "/tags/julia/")
        @test [q.body for q in r.context["post_list"]] == ["Learning #Julia, still"]
        @test get(Client(), "/tags/nosuchtag/").status == 404
    end
end

@testset "search" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        create(Post; author = ann, body = "Tomatoes are ripe #garden")
        create(Post; author = bob, body = "My garden is a jungle")
        create(Post; author = bob, body = "Nothing to see here")
        found(r) = Set(p.body for p in r.context["page_obj"])
        c = Client()

        @test get(c, "/search/").status == 200
        @test isempty(get(c, "/search/").context["members"])

        r = get(c, "/search/?q=garden")                 # in the text, or as a tag
        @test found(r) == Set(["Tomatoes are ripe #garden", "My garden is a jungle"])
        @test found(get(c, "/search/?q=%23garden")) == Set(["Tomatoes are ripe #garden"])  # just the tag
        @test found(get(c, "/search/?q=garden&author=bob")) == Set(["My garden is a jungle"])
        @test found(get(c, "/search/?author=ANN")) == Set(["Tomatoes are ripe #garden"])     # iexact

        # members by username or display name
        @test [m.username for m in get(c, "/search/?q=lee").context["members"]] == ["ann"]

        # a picture filter, and a date range
        p = first(filter(Post; author = bob, body = "Nothing to see here"))
        update!(filter(Post; id = p.id); image = "posts/x.png")
        @test found(get(c, "/search/?pictures=true")) == Set(["Nothing to see here"])
        @test length(found(get(c, "/search/?created_after=2000-01-01"))) == 3
        @test isempty(found(get(c, "/search/?created_before=2000-01-01")))

        # htmx gets just the results; the next-page link keeps the filters
        r = get(c, "/search/?q=garden"; htmx = true)
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "2 posts")
        for i in 1:25
            create(Post; author = bob, body = "garden note $i")
        end
        r = get(c, "/search/?q=garden&author=bob")
        link = match(r"href=\"([^\"]*page=2[^\"]*)\"", text(r))
        @test link !== nothing
        @test occursin("q=garden", link[1]) && occursin("author=bob", link[1])
    end
end

@testset "trending, cached" begin
    rollback_after() do
        cache_clear()                                     # start without anything cached
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        cat = create_user("cat"; password = "correct-horse-battery")
        quiet = create(Post; author = ann, body = "Quiet #julia")
        popular = create(Post; author = ann, body = "Popular #julia #garden")
        add!(popular.likers, bob, cat)
        add!(quiet.likers, bob)

        @test Posts.trending_post_ids() == [popular.id, quiet.id]
        @test first(Posts.trending_tags()) == (name = "julia", uses = 2)

        # cached: a new like doesn't change the answer until the cache entry expires...
        add!(quiet.likers, ann, cat)
        @test Posts.trending_post_ids() == [popular.id, quiet.id]
        # ...or is deleted
        cache_delete("trending:posts")
        @test Posts.trending_post_ids() == [quiet.id, popular.id]

        r = get(Client(), "/trending/")
        @test [p.body for p in r.context["posts"]] == ["Quiet #julia", "Popular #julia #garden"]
        @test assert_contains(r, "#garden")
        # likes older than a day don't count
        update!(objects(Like); created = timezone_now() - Day(2))
        cache_clear()
        @test isempty(Posts.trending_post_ids())
    end
end
