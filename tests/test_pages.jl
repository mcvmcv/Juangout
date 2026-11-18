using Test
using Juango.Testing

@testset "pages" begin
    c = Client()

    r = get(c, "/")
    @test r.status == 200
    @test assert_template_used(r, "posts/timeline.html")
    @test assert_contains(r, "Welcome to Juangout")

    r = get(c, reverse_url("about"))
    @test r.status == 200
    @test assert_contains(r, "Django-style web framework")

    @test get(c, "/no-such-page/").status == 404
end
