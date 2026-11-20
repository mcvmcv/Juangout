# Settings, with what changes between deployments read from the environment or a .env file
# (kept out of version control): DEBUG=false, SECRET_KEY=..., DATABASE_URL=postgresql://...
using Juango.Environ
read_env(joinpath(BASE_DIR, ".env"))

debug = env("DEBUG", Bool; default = true)

configure!(
    DEBUG = debug,
    # in development, a panel on every page with its SQL queries, templates and timings
    MIDDLEWARE = debug ? [DebugToolbarMiddleware, Juango.default_settings()[:MIDDLEWARE]...] :
                         Juango.default_settings()[:MIDDLEWARE],
    INTERNAL_IPS = ["127.0.0.1", "::1"],
    SECRET_KEY = env("SECRET_KEY"; default = "TDD7oiWM28hi1EgFjGvJ2RemZXSOFDPDgSxRbntMUYjVFhzunc"),
    ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost", "127.0.0.1"]),
    # DATABASE_URL=postgresql://user:password@localhost:5432/Juangout (or mysql://, sqlite:////path)
    DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
    INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages",
                      Accounts.APP, Posts.APP, Notifications.APP, Moderation.APP],
    # values every template gets: Juango's own (user, messages, ...) and the unread count
    CONTEXT_PROCESSORS = [Juango.default_settings()[:CONTEXT_PROCESSORS]..., unread_notifications],
    # email: printed to the terminal in development, sent through a mail server in production
    EMAIL_BACKEND = debug ? :console : :smtp,
    DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL"; default = "Juangout <noreply@juangout.example>"),
    SITE_URL = env("SITE_URL"; default = "http://127.0.0.1:8000"),     # for links in emails
    # each view runs in a database transaction: its changes are saved together, or not at all
    ATOMIC_REQUESTS = true,
    AUTH_USER_MODEL = "accounts.Member",
    MIGRATIONS_DIR = joinpath(BASE_DIR, "migrations"),
    ROOT_URLCONF = urlpatterns,
    TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
    STATIC_DIRS = [joinpath(BASE_DIR, "static")],
    MEDIA_ROOT = joinpath(BASE_DIR, "media"),     # uploaded files (FileField/ImageField)
    USE_TZ = true,                                # aware datetimes, stored in UTC
    TIME_ZONE = "UTC",
    SITE_NAME = "Juangout",
)

# Workaround for Juango #242: Admin.urls() (in urls.jl) runs before AUTH_USER_MODEL is set
# and registers Juango's own User with the admin. Member replaces it.
Admin.is_registered(Juango.User) && Admin.unregister!(Juango.User)
