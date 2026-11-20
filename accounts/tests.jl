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

@testset "following" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")

        # the relation, in Julia
        add!(ann.following, bob)
        @test bob in ann.following
        @test ann in bob.followers
        @test !(ann in bob.following)                 # one-way: symmetrical = false
        @test count(Follow) == 1
        add!(ann.following, bob)                      # adding again changes nothing
        @test count(Follow) == 1
        remove!(ann.following, bob)
        @test count(ann.following) == 0

        # the database refuses a member following themselves. A failed write spoils the
        # transaction it's in, so give it a transaction of its own (a savepoint) with atomic.
        @test_throws IntegrityError atomic() do
            create(Follow; follower = ann, followed = ann)
        end

        # through the buttons
        c = Client()
        @test assert_redirects(post(c, "/@bob/follow/"), "/accounts/login/?next=%2F%40bob%2Ffollow%2F")
        force_login!(c, ann)
        @test get(c, "/@bob/follow/").status == 405   # POST only
        r = post(c, "/@bob/follow/"; follow = true)
        @test assert_contains(r, "You&#x27;re following bob.")
        @test r.context["i_follow"]
        @test r.context["follower_count"] == 1
        @test bob in ann.following

        r = post(c, "/@ann/follow/"; follow = true)
        @test assert_contains(r, "You can&#x27;t follow yourself.")

        r = get(Client(), "/@ann/following/")
        @test [m.username for m in r.context["member_list"]] == ["bob"]
        r = get(Client(), "/@bob/followers/")
        @test [m.username for m in r.context["member_list"]] == ["ann"]
        @test get(Client(), "/@nobody/followers/").status == 404

        force_login!(c, bob)
        @test get(c, "/@ann/").context["follows_me"]

        force_login!(c, ann)
        post(c, "/@bob/unfollow/")
        @test count(ann.following) == 0
    end
end

@testset "avatars" begin
    rollback_after() do
        png = hex2bytes("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082")
        ann = create_user("ann"; password = "correct-horse-battery", display_name = "ann lee")
        @test ann.initial == "A"
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/@ann/"), "avatar-initial")       # no avatar yet: the initial

        r = post(c, "/accounts/profile/", Dict("display_name" => "Ann Lee", "bio" => "", "email" => "",
                                               "avatar" => UploadedFile("me.png", png)))
        @test assert_redirects(r, "/@ann/")
        refresh!(ann)
        @test startswith(ann.avatar.url, "/media/avatars/")
        @test assert_contains(get(c, "/@ann/"), ann.avatar.url)
    end
end

@testset "htmx: following" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        bob = create_user("bob"; password = "correct-horse-battery")
        c = Client()
        force_login!(c, ann)
        r = post(c, "/@bob/follow/"; htmx = true)
        @test r.status == 200
        @test assert_not_contains(r, "<html")
        @test assert_contains(r, "id=\"follow-box\"")
        @test assert_contains(r, "Unfollow")
        @test assert_contains(r, "<strong>1</strong> follower")
        @test assert_contains(r, "You&#x27;re following bob.")   # the message, out of band
        r = post(c, "/@bob/unfollow/"; htmx = true)
        @test assert_contains(r, "<strong>0</strong> followers")
    end
end

@testset "time zones and humanize" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        p = create(Post; author = ann, body = "New year!")
        p.created = make_aware(DateTime(2026, 1, 1, 12, 0)); save!(p)          # noon, UTC (TIME_ZONE)

        # visitors see UTC; a member in Auckland (UTC+13 in January) sees their own time
        @test assert_contains(get(Client(), "/posts/$(p.id)/"), "1 Jan 2026, 12:00")
        ann.time_zone = "Pacific/Auckland"; save!(ann)
        c = Client()
        force_login!(c, ann)
        @test assert_contains(get(c, "/posts/$(p.id)/"), "2 Jan 2026, 01:00")

        # naturaltime: "5 minutes ago" rather than a date
        recent = create(Post; author = ann, body = "Just now-ish")
        recent.created = timezone_now() - Minute(5); save!(recent)
        @test assert_contains(get(c, "/posts/$(recent.id)/"), "5 minutes ago")
    end
end

@testset "translations" begin
    rollback_after() do
        ann = create_user("ann"; password = "correct-horse-battery")
        # the browser's preferred language
        r = get(Client(), "/"; headers = Dict("Accept-Language" => "de"))
        @test assert_contains(r, "Willkommen bei Juangout")
        @test assert_contains(r, "<html lang=\"de\">"; html = false)
        @test assert_contains(get(Client(), "/"), "Welcome to Juangout")

        # the switcher remembers a choice, and goes back where it came from
        c = Client()
        force_login!(c, ann)
        r = post(c, "/i18n/setlang/", Dict("language" => "de", "next" => "/everyone/"))
        @test assert_redirects(r, "/everyone/")
        r = get(c, "/everyone/")
        @test assert_contains(r, "Mitteilungen")
        @test assert_contains(r, ">Alle</a>")
    end
end
