# The moderation app: members report posts, moderators hide them.
module Moderation

using Juango
using Dates
using ..Posts: Post, for_display

export Report, Reason

const APP = App("moderation"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                ready = () -> connect!(post_migrate, setup_moderators; sender = "moderation",
                                       dispatch_uid = "moderation_setup"))

include("models.jl")
include("setup.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")

end
