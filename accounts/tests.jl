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

@testset "signing up" begin
    rollback_after() do
        c = Client()
        @test get(c, "/accounts/signup/").status == 200

        # passwords that don't match: the form comes back with an error, and nobody is created
        r = post(c, "/accounts/signup/", Dict("username" => "cat", "email" => "cat@example.com",
                                              "password1" => "purring-loudly-42", "password2" => "something-else"))
        @test r.status == 200
        @test !is_valid(r.context["form"])
        @test haskey(r.context["form"].errors, :password2)
        @test count(filter(Member; username = "cat")) == 0

        # a good sign-up creates the member, logs them in and sends them to edit their profile
        r = post(c, "/accounts/signup/", Dict("username" => "cat", "email" => "cat@example.com",
                                              "password1" => "purring-loudly-42", "password2" => "purring-loudly-42"))
        @test assert_redirects(r, "/accounts/profile/")
        cat = get(Member; username = "cat")
        @test cat.email == "cat@example.com"
        @test check_password(cat, "purring-loudly-42")            # stored hashed
        @test cat.password != "purring-loudly-42"
        r = get(c, "/accounts/profile/")
        @test r.status == 200                                     # logged in
        @test assert_contains(r, "Welcome to Juangout, cat!")     # the message

        # the username must be unique
        r = post(Client(), "/accounts/signup/", Dict("username" => "cat", "password1" => "purring-loudly-42",
                                                     "password2" => "purring-loudly-42"))
        @test haskey(r.context["form"].errors, :username)
    end
end

@testset "logging in and out" begin
    rollback_after() do
        create_user("ann"; password = "correct-horse-battery")
        c = Client()
        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "wrong"))
        @test r.status == 200
        @test !isempty(r.context["form"].errors)

        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "correct-horse-battery"))
        @test assert_redirects(r, "/")
        @test assert_contains(get(c, "/"), "Log out")

        # logging out is a POST (a link could be followed by anything, even a prefetcher)
        @test get(c, "/accounts/logout/").status == 405
        r = post(c, "/accounts/logout/")
        @test assert_redirects(r, "/")
        @test assert_contains(get(c, "/"), "Log in")
    end
end

@testset "editing your profile" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        @test assert_redirects(get(c, "/accounts/profile/"), "/accounts/login/?next=%2Faccounts%2Fprofile%2F")
        force_login!(c, ann)
        r = post(c, "/accounts/profile/", Dict("display_name" => "Ann Lee", "bio" => "Hi there", "email" => "ann@example.com"))
        @test assert_redirects(r, "/@ann/")
        refresh!(ann)
        @test ann.display_name == "Ann Lee"
        @test ann.bio == "Hi there"

        r = post(c, "/accounts/profile/", Dict("display_name" => "", "bio" => "x"^301, "email" => "ann@example.com"))
        @test haskey(r.context["form"].errors, :bio)
    end
end

@testset "CSRF protection" begin
    rollback_after() do
        create_user("ann"; password = "correct-horse-battery")
        c = Client(enforce_csrf = true)
        r = post(c, "/accounts/login/", Dict("username" => "ann", "password" => "correct-horse-battery"))
        @test r.status == 403
    end
end

@testset "changing your password" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = get(c, "/accounts/password_change/")
        @test assert_template_used(r, "registration/password_change_form.html")
        @test assert_contains(r, "Edit profile")                    # our template, inside base.html
        r = post(c, "/accounts/password_change/", Dict("old_password" => "correct-horse-battery",
                     "new_password1" => "staple-battery-horse", "new_password2" => "staple-battery-horse"); follow = true)
        @test assert_contains(r, "Your new password is set")
        @test check_password(refresh!(ann), "staple-battery-horse")
    end
end
