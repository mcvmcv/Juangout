# The Moderators group, with the permissions moderating needs. A post_migrate receiver: it runs
# after every `migrate` (once auth has created the permissions), so the group always exists and
# is up to date. get_or_create and add! make running it again harmless.
const MODERATOR_PERMISSIONS = ["hide_post", "view_report", "change_report"]

function setup_moderators(sender; kw...)
    group, _ = get_or_create(Group; name = "Moderators")
    add!(group.permissions, collect(filter(Permission; codename__in = MODERATOR_PERMISSIONS))...)
end
