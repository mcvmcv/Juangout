# Settings. What differs between a laptop and a server comes from environment variables, or a
# .env file kept out of git (see .env.example): DEBUG, SECRET_KEY, ALLOWED_HOSTS, DATABASE_URL,
# EMAIL_URL, CACHE_URL, SITE_URL. With none of them set, you get a development setup.
using Juango.Environ
read_env(joinpath(BASE_DIR, ".env"))

debug = env("DEBUG", Bool; default = true)
on_postgres = startswith(env("DATABASE_URL"; default = ""), "postgres")
site_url = env("SITE_URL"; default = "http://127.0.0.1:8000")

configure!(;                                                 # (the ; lets env_email(...)... below add keywords)
    DEBUG = debug,
    # signs sessions, password-reset links and CSRF tokens: required, and secret, in production
    SECRET_KEY = debug ? env("SECRET_KEY"; default = "insecure-development-key-never-use-in-production") :
                         env("SECRET_KEY"),
    ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost", "127.0.0.1"]),

    # services, each from a URL: DATABASE_URL=postgresql://user:password@host:5432/juangout,
    # CACHE_URL=redis://host:6379/0, EMAIL_URL=smtp+tls://user:password@mail.example.com:587
    DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
    CACHES = Dict("default" => env_cache(; default = "locmem://")),
    env_email(; default = "consolemail://")...,          # printed to the terminal unless EMAIL_URL says otherwise
    DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    SERVER_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    ADMINS = [("Admin", a) for a in env("ADMIN_EMAILS", Vector{String}; default = String[])],   # mailed about errors
    SITE_URL = site_url,                                  # for links in emails

    # background tasks run at once in development; in production a worker process runs them
    # (julia --project manage.jl db_worker), so a slow mail server never holds up a page
    TASKS = Dict("default" => Dict("backend" => debug ? :immediate : :database)),
    # in production, live views hear about new posts from every server process, through PostgreSQL
    # (it sends messages when transactions commit; one process, in development, needs no help)
    LIVE_PUBSUB = on_postgres && !debug ? :postgres : nothing,

    INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages",
                      "juango.tasks", Accounts.APP, Posts.APP, Notifications.APP, Moderation.APP, Api.APP],
    # Every request passes through these in order (and the response back out in reverse).
    # The debug toolbar first, in development; LocaleMiddleware after sessions, which it reads;
    # members' time zones after authentication, which tells us who the member is.
    MIDDLEWARE = [(debug ? [DebugToolbarMiddleware] : [])..., Juango.SecurityMiddleware, Juango.SessionMiddleware,
                  LocaleMiddleware, Juango.CommonMiddleware, Juango.CsrfViewMiddleware, Juango.AuthenticationMiddleware,
                  MemberTimezoneMiddleware, HtmxMiddleware],
    INTERNAL_IPS = ["127.0.0.1", "::1"],                  # who sees the debug toolbar
    # values every template gets: Juango's own (user, messages, ...) and the unread count
    CONTEXT_PROCESSORS = [Juango.default_settings()[:CONTEXT_PROCESSORS]..., unread_notifications],
    # each view runs in a database transaction: its changes are saved together, or not at all
    ATOMIC_REQUESTS = true,
    AUTH_USER_MODEL = "accounts.Member",
    MIGRATIONS_DIR = joinpath(BASE_DIR, "migrations"),
    ROOT_URLCONF = urlpatterns,

    # templates, static files and uploads
    TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
    STATIC_DIRS = [joinpath(BASE_DIR, "static")],
    STATIC_ROOT = joinpath(BASE_DIR, "staticfiles"),     # collectstatic copies everything here, for the web server
    STATICFILES_STORAGE = debug ? :static : :manifest,   # in production, a hash in each name, so browsers can cache them for ever
    MEDIA_ROOT = joinpath(BASE_DIR, "media"),            # uploaded files (FileField/ImageField)

    # time zones and languages
    USE_TZ = true,                                       # aware datetimes, stored in UTC
    TIME_ZONE = "UTC",
    LANGUAGE_CODE = "en",
    LANGUAGES = [("en", "English"), ("de", "Deutsch")],
    LOCALE_PATHS = [joinpath(BASE_DIR, "locale")],
    SITE_NAME = "Juangout",

    # HTTPS, in production: behind a proxy (nginx) that handles TLS and says so in a header
    SECURE_PROXY_SSL_HEADER = debug ? nothing : ("X-Forwarded-Proto", "https"),
    SECURE_SSL_REDIRECT = !debug,                        # http:// -> https://
    SECURE_HSTS_SECONDS = debug ? 0 : env("HSTS_SECONDS", Int; default = 3600),   # raise to a year once it all works
    SESSION_COOKIE_SECURE = !debug,                      # cookies only over HTTPS
    CSRF_COOKIE_SECURE = !debug,
    CSRF_TRUSTED_ORIGINS = [site_url],
)

# Workaround for Juango #242: Admin.urls() (in urls.jl) runs before AUTH_USER_MODEL is set
# and registers Juango's own User with the admin. Member replaces it.
Admin.is_registered(Juango.User) && Admin.unregister!(Juango.User)
