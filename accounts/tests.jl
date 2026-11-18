using Test
using Juango.Testing

@testset "accounts" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "Ann Lee", bio = "Hello!")
        bob = create_user("bob"; password = "correct-horse-battery")

        @test get_user_model() === Member
        @test ann.name == "Ann Lee"
        @test bob.name == "bob"                    # falls back to the username
        @test get_absolute_url(ann) == "/@ann/"

        c = Client()
        r = get(c, "/@ann/")
        @test r.status == 200
        @test r.context["member"] == ann
        @test assert_contains(r, "Ann Lee")
        @test assert_contains(r, "Hello!")

        @test get(c, "/@nobody/").status == 404

        # inactive members have no profile page
        bob.is_active = false
        save!(bob)
        @test get(c, "/@bob/").status == 404
    end
end

@testset "admin" begin
    rollback_after() do
        boss = create_superuser("boss"; password = "correct-horse-battery", email = "boss@example.com")
        c = Client()
        force_login!(c, boss)
        @test get(c, "/admin/").status == 200
        r = get(c, "/admin/accounts/member/")
        @test r.status == 200
        @test assert_contains(r, "boss")
    end
end
