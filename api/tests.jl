using Test
using Juango.Testing
using JSON

@testset "API tokens" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = post(c, "/accounts/tokens/", Dict("name" => "my script"))
        secret = r.context["secret"]
        @test length(secret) == 40
        @test assert_contains(r, secret)                       # shown once...
        @test !occursin(secret, text(get(c, "/accounts/tokens/")))   # ...and never again
        token = only(ann.api_tokens)
        @test token.key_hash == Api.hash_key(secret) != secret   # only the hash is stored
        @test Api.member_for_key(secret) == ann
        @test Api.member_for_key("not-a-key") === nothing

        post(c, "/accounts/tokens/$(token.id)/revoke/")
        @test Api.member_for_key(secret) === nothing
    end
end

@testset "the JSON API" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        bob = create_user("bob"; password = "correct-horse-battery")
        add!(ann.following, bob)
        hello = create(Post; author = bob, body = "Hello from Bob")
        _, key = Api.new_token!(ann, "tests")
        auth = Dict("Authorization" => "Bearer $key")
        c = Client()
        body(r) = JSON.parse(text(r))

        # no token, or a wrong one: 401
        @test get(c, "/api/v1/timeline").status == 401
        @test get(c, "/api/v1/timeline"; headers = Dict("Authorization" => "Bearer nope")).status == 401

        r = get(c, "/api/v1/timeline"; headers = auth)
        @test r.status == 200
        page = body(r)
        @test page["count"] == 1
        @test only(page["items"])["body"] == "Hello from Bob"
        @test only(page["items"])["author"] == "bob"
        @test startswith(only(page["items"])["url"], "http")      # absolute

        @test body(get(c, "/api/v1/members/ann"; headers = auth))["name"] == "Ann Lee"
        @test body(get(c, "/api/v1/members/bob"; headers = auth))["followers"] == 1
        @test get(c, "/api/v1/members/nobody"; headers = auth).status == 404

        # writing: 201 with the new post; a reply; bad input is a 422 saying what's wrong
        r = post(c, "/api/v1/posts"; json = Dict("body" => "Posted by a robot", "reply_to" => nothing), headers = auth)
        @test r.status == 201
        @test body(r)["author"] == "ann"
        r = post(c, "/api/v1/posts"; json = Dict("body" => "A reply", "reply_to" => hello.id), headers = auth)
        @test body(r)["reply_to"] == hello.id
        r = post(c, "/api/v1/posts"; json = Dict("body" => "x"^281, "reply_to" => nothing), headers = auth)
        @test r.status == 422
        @test body(r)["detail"][1]["loc"] == ["body", "body"]
        r = post(c, "/api/v1/posts"; json = Dict("reply_to" => nothing), headers = auth)
        @test r.status == 422                                     # body missing
        @test body(get(c, "/api/v1/members/ann/posts"; headers = auth))["count"] == 2

        # likes
        @test request(c, "PUT", "/api/v1/posts/$(hello.id)/like"; headers = auth).status == 204
        @test body(get(c, "/api/v1/posts/$(hello.id)"; headers = auth))["liked"] == true
        @test request(c, "DELETE", "/api/v1/posts/$(hello.id)/like"; headers = auth).status == 204
        @test !(ann in hello.likers)

        # pagination with limit and offset
        for i in 1:30
            create(Post; author = bob, body = "bob $i")
        end
        page = body(get(c, "/api/v1/timeline?limit=10&offset=5"; headers = auth))
        @test length(page["items"]) == 10
        @test page["count"] == 32

        # the OpenAPI description documents it all
        spec = body(get(c, "/api/v1/openapi.json"))
        @test haskey(spec["paths"], "/api/v1/timeline")
        @test haskey(spec["paths"], "/api/v1/posts/{id}/like")
    end
end

@testset "feeds and the sitemap" begin
    rollback_after() do
        cache_clear()
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee")
        create(Post; author = ann, body = "First <post> & more")
        create(Post; author = ann, body = "Hidden", hidden = true)
        c = Client()
        r = get(c, "/@ann/feed/")
        @test r.status == 200
        @test occursin("rss", getheader(r, "Content-Type"))
        @test occursin("<title>Ann Lee on Juangout</title>", text(r))
        @test occursin("First &lt;post&gt; &amp; more", text(r))
        @test !occursin("Hidden", text(r))
        @test occursin("atom", getheader(get(c, "/@ann/feed/atom/"), "Content-Type"))
        @test get(c, "/@nobody/feed/").status == 404

        # cached: a new post doesn't show until the cache expires (here, until it's cleared)
        create(Post; author = ann, body = "Brand new")
        @test !occursin("Brand new", text(get(c, "/@ann/feed/")))
        cache_clear()
        @test occursin("Brand new", text(get(c, "/@ann/feed/")))

        # profiles point feed readers at the feed
        @test assert_contains(get(c, "/@ann/"), "application/rss+xml"; html = false)

        r = get(c, "/sitemap.xml")
        @test r.status == 200
        @test occursin("sitemap-members.xml", text(r))
        @test occursin("/@ann/", text(get(c, "/sitemap-members.xml")))
    end
end
