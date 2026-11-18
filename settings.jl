# Settings, with what changes between deployments read from the environment or a .env file
# (kept out of version control): DEBUG=false, SECRET_KEY=..., DATABASE_URL=postgresql://...
using Juango.Environ
read_env(joinpath(BASE_DIR, ".env"))

configure!(
    DEBUG = env("DEBUG", Bool; default = true),
    SECRET_KEY = env("SECRET_KEY"; default = "TDD7oiWM28hi1EgFjGvJ2RemZXSOFDPDgSxRbntMUYjVFhzunc"),
    ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost", "127.0.0.1"]),
    # DATABASE_URL=postgresql://user:password@localhost:5432/Juangout (or mysql://, sqlite:////path)
    DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
    # Your apps (`julia --project manage.jl startapp blog`) go here too, e.g. Blog.APP
    INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages"],
    MIGRATIONS_DIR = joinpath(BASE_DIR, "migrations"),
    ROOT_URLCONF = urlpatterns,
    TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
    STATIC_DIRS = [joinpath(BASE_DIR, "static")],
    MEDIA_ROOT = joinpath(BASE_DIR, "media"),     # uploaded files (FileField/ImageField)
    USE_TZ = true,                                # aware datetimes, stored in UTC
    TIME_ZONE = "UTC",
    SITE_NAME = "Juangout",
)
