# Juangout's members. A custom user model: everything Juango's User has (username, password,
# email, is_staff, ...) plus our own fields. AUTH_USER_MODEL in settings.jl points at it.
@model struct Member <: AbstractUser
    display_name = CharField(max_length = 50, blank = true,
                             help_text = "The name shown on your posts. Leave blank to use your username.")
    bio = TextField(max_length = 300, blank = true)
end

Base.show(io::IO, m::Member) = print(io, "@", m.username)

# `member.name` in Julia, `{{ member.name }}` in templates
Juango.tattr(m::Member, ::Val{:name}) = isempty(m.display_name) ? m.username : m.display_name

Juango.get_absolute_url(m::Member) = reverse_url("accounts:profile"; username = m.username)
