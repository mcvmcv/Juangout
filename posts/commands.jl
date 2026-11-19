# `julia --project manage.jl seed`: some members and posts to look at while developing.
const DEMO_MEMBERS = [
    ("ann", "Ann Lee", "Gardener, cyclist, occasional poet."),
    ("bob", "", ""),
    ("chen", "Chen Wei", "I write Julia for a living and for fun."),
    ("dee", "Dee", "Mostly here for the cat pictures."),
]

const DEMO_POSTS = [
    "First post! Is this thing on?",
    "The tomatoes are finally turning red.",
    "Hot take: tabs in YAML should be a criminal offence.",
    "Rode 60 km today and only got lost twice.",
    "Just discovered that Julia's REPL has a shell mode. Press ; and you're in.",
    "Does anyone else read the last page of a book first?",
    "Rain again. The garden is happy, I am not.",
    "Multiple dispatch is the best idea in programming languages and I will not be taking questions.",
    "Made bread. It's flat, but it's bread.",
    "The cat has claimed my keyboard. Send help.",
    "Today I learned that octopuses have three hearts.",
    "Coffee number four. Productivity unchanged.",
]

function seed(args)
    members = map(DEMO_MEMBERS) do (username, display_name, bio)
        m = first(filter(get_user_model(); username), 1)
        isempty(m) ? create_user(username; password = "juangout-demo", display_name, bio) : only(m)
    end
    for (i, body) in enumerate(DEMO_POSTS)
        p = create(Post; author = members[mod1(i, length(members))], body)
        p.created = timezone_now() - Minute(17 * (length(DEMO_POSTS) - i) + rand(0:9))
        save!(p)
    end
    # everyone follows a couple of people, and likes some posts
    for (i, m) in enumerate(members)
        add!(m.following, members[mod1(i + 1, length(members))], members[mod1(i + 2, length(members))])
        for p in objects(Post)[1:6]
            rand() < 0.5 && add!(p.likers, m)
        end
    end
    println("Created $(length(DEMO_POSTS)) posts by $(length(members)) members (password: juangout-demo).")
end
