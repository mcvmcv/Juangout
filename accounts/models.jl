# Juangout's members. A custom user model: everything Juango's User has (username, password,
# email, is_staff, ...) plus our own fields. AUTH_USER_MODEL in settings.jl points at it.
# Time zones members can choose from (any IANA name would work; a short list makes a tidy menu)
const TIME_ZONES = [tz => replace(tz, "_" => " ") for tz in [
    "UTC", "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Athens", "Africa/Lagos",
    "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Shanghai", "Asia/Tokyo",
    "Australia/Perth", "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "America/New_York",
    "America/Chicago", "America/Denver", "America/Los_Angeles", "Pacific/Honolulu"]]

@model struct Member <: AbstractUser
    display_name = CharField(max_length = 50, blank = true,
                             help_text = "The name shown on your posts. Leave blank to use your username.")
    bio = TextField(max_length = 300, blank = true)
    avatar = ImageField(upload_to = "avatars/", blank = true,
                        validators = [MaxFileSizeValidator(2_000_000)], help_text = "A square picture works best. At most 2 MB.")
    email_notifications = BooleanField(default = true, verbose_name = "Email me about new followers and replies")
    time_zone = CharField(max_length = 50, blank = true, choices = TIME_ZONES,
                          help_text = "Times are shown in this zone. Leave blank for UTC.")
    # who this member follows: a one-way relation from members to members, stored as Follow rows
    following = ManyToManyField(:self; symmetrical = false, through = :Follow,
                                through_fields = (:follower, :followed), related_name = :followers, blank = true)
end

Base.show(io::IO, m::Member) = print(io, "@", m.username)

# `member.name` in Julia, `{{ member.name }}` in templates
Juango.tattr(m::Member, ::Val{:name}) = isempty(m.display_name) ? m.username : m.display_name

Juango.get_absolute_url(m::Member) = reverse_url("accounts:profile"; username = m.username)

# For members without an avatar: the first letter of their name, for a placeholder circle
Juango.tattr(m::Member, ::Val{:initial}) = uppercase(first(m.name, 1))

# One member following another. An explicit "through" model, so it can record when.
@model struct Follow
    follower = ForeignKey(Member; on_delete = :CASCADE, related_name = :outgoing_follows)
    followed = ForeignKey(Member; on_delete = :CASCADE, related_name = :incoming_follows)
    created = DateTimeField(auto_now_add = true)
    Meta(constraints = [
        UniqueConstraint(fields = [:follower, :followed], name = "follow_once"),
        CheckConstraint(condition = !Q(follower = F(:followed)), name = "no_following_yourself"),
    ])
end
